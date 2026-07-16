import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/conversation-delete.feature — deletion is an instant local
/// tombstone plus a durable remote-delete intent that a deleted card can never survive
/// (relaunch, status refresh) and that completes when the desktop is next reachable.
/// Drives the SAME real seams the unit CaptureDeleteTests exercise (CaptureManager
/// deleteConversation / retryPendingDeletes, the on-disk tombstone, the injected remote
/// delete) — hermetic (DoorTarget at a dead port; the remote delete is injected).
final class ConversationDeleteFeatureTests: XCTestCase {
    func testConversationDeleteFeature() async throws {
        try await BrineFeatureRunner.run("conversation-delete",
                                         registry: StepRegistry(ConversationDeleteSteps.make(world: ConversationDeleteWorld())))
    }
}

private final class DeleteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var shouldFail = false
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    func record(_ id: String) throws {
        lock.lock(); _calls.append(id); let fail = shouldFail; lock.unlock()
        if fail { throw DoorError.http(503) }
    }
}

@MainActor
private final class ConversationDeleteWorld: @unchecked Sendable {
    let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    var dir: URL!
    var id = "omi-20260707-120000-delete01"
    var recorder = DeleteRecorder()
    var mgr: CaptureManager!
    /// A recorder used when the connection "returns" (a fresh, succeeding attempt).
    var reconnectRecorder = DeleteRecorder()

    func freshDir() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-delete-feature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func seedConversation() throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        try Data().write(to: cdir.appendingPathComponent(".needs-finalize"))
        ConversationMetaStore.save(ConversationMeta(startedAt: 100, endedAt: 160), captureId: id, baseDir: dir)
        ConversationCardStore.merge(captureId: id, baseDir: dir, title: "Delete me", summary: "Temporary", stage: "ready")
        TranscriptCacheStore.save(CachedTranscript(transcript: "words", title: "Delete me",
                                                   summary: "Temporary", fetchedAt: 1), captureId: id, baseDir: dir)
    }

    func makeManager(_ rec: DeleteRecorder) async -> CaptureManager {
        let m = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                               deleteCapture: { try rec.record($0) }, fetchContent: { _ in nil })
        #if os(iOS)
        m.micPermissionOverrideForTests = true
        #endif
        await m.hydration?.value
        return m
    }

    var localAudioPath: String { dir.appendingPathComponent(id, isDirectory: true).appendingPathComponent(CaptureWAL.segName(0)).path }
    var tombstoneDir: String { dir.appendingPathComponent(id, isDirectory: true).path }
}

private enum ConversationDeleteSteps {
    static func make(world w: ConversationDeleteWorld) -> [StepDefinition] {
        // A completed conversation, seeded + hydrated into a live manager.
        func seedAndOpen(offline: Bool) async throws {
            try await MainActor.run {
                try w.freshDir()
                w.recorder = DeleteRecorder()
                w.recorder.shouldFail = offline
                try w.seedConversation()
            }
            let m = await w.makeManager(w.recorder)
            await MainActor.run {
                w.mgr = m
                XCTAssertTrue(m.captures.contains { $0.captureId == w.id }, "seeded conversation is present before delete")
            }
        }
        func delete() async throws {
            await MainActor.run { w.mgr.deleteConversation(w.id) }
            await w.mgr.retryPendingDeletes()
        }
        return [
            defineStep("a completed conversation in my list") { ctx, _, _ in try await seedAndOpen(offline: false); return ctx },
            defineStep("I delete it and confirm") { ctx, _, _ in try await delete(); return ctx },
            defineCheck("its card disappears from the list immediately") { _, _, _ in
                let gone = await MainActor.run { !w.mgr.captures.contains { $0.captureId == w.id }
                    && !w.mgr.visibleCaptures.contains { $0.captureId == w.id } }
                guard gone else { throw BrineStepError("the deleted card is still in the list") }
            },

            defineStep("I deleted a conversation earlier") { ctx, _, _ in
                try await seedAndOpen(offline: false); try await delete(); return ctx
            },
            defineStep("I relaunch the app") { ctx, _, _ in
                let m = await w.makeManager(DeleteRecorder())
                await MainActor.run { w.mgr = m }
                return ctx
            },
            defineCheck("that conversation does not appear in my list") { _, _, _ in
                let gone = await MainActor.run { !w.mgr.captures.contains { $0.captureId == w.id }
                    && !w.mgr.visibleCaptures.contains { $0.captureId == w.id } }
                guard gone else { throw BrineStepError("a deleted conversation reappeared after relaunch") }
            },

            defineStep("a conversation that was saved to my computer and my library") { ctx, _, _ in
                try await seedAndOpen(offline: false); return ctx
            },
            defineCheck("its audio and transcript are removed from the computer") { _, _, _ in
                let (removed, calls, id) = await MainActor.run {
                    (!FileManager.default.fileExists(atPath: w.localAudioPath)
                        && !TranscriptCacheStore.hasCachedTranscript(captureId: w.id, baseDir: w.dir),
                     w.recorder.calls, w.id)
                }
                guard removed else { throw BrineStepError("local audio/transcript survived the delete") }
                guard calls == [id] else { throw BrineStepError("the computer-side remote delete did not fire (calls: \(calls))") }
            },
            defineCheck("its content is removed from the library") { _, _, _ in
                // The same door delete removes the conversation from the Lore library; its
                // ACK tore down the whole local tombstone.
                let (calls, tombstoneGone, id) = await MainActor.run {
                    (w.recorder.calls, !FileManager.default.fileExists(atPath: w.tombstoneDir), w.id)
                }
                guard calls == [id] else { throw BrineStepError("library removal (remote delete) did not fire") }
                guard tombstoneGone else { throw BrineStepError("the ACKed delete did not clear the tombstone") }
            },

            defineStep("my phone cannot reach the computer right now") { ctx, _, _ in
                try await seedAndOpen(offline: true); return ctx
            },
            defineStep("I delete a conversation and confirm") { ctx, _, _ in try await delete(); return ctx },
            defineCheck("its card disappears immediately") { _, _, _ in
                let (gone, needsDelete) = await MainActor.run {
                    (!w.mgr.captures.contains { $0.captureId == w.id },
                     FileManager.default.fileExists(atPath: w.dir.appendingPathComponent(w.id, isDirectory: true)
                        .appendingPathComponent(".needs-delete").path))
                }
                guard gone else { throw BrineStepError("offline delete did not hide the card immediately") }
                guard needsDelete else { throw BrineStepError("offline delete left no pending remote-delete intent") }
            },
            defineCheck("the computer-side removal completes when the connection returns") { _, _, _ in
                let reconnect = DeleteRecorder()
                await MainActor.run { w.reconnectRecorder = reconnect }
                let m = await w.makeManager(reconnect)
                await m.retryPendingDeletes()
                let (tombstoneGone, id) = await MainActor.run { (!FileManager.default.fileExists(atPath: w.tombstoneDir), w.id) }
                guard reconnect.calls == [id] else {
                    throw BrineStepError("the remote delete did not complete on reconnect (calls: \(reconnect.calls))")
                }
                guard tombstoneGone else { throw BrineStepError("the completed remote delete did not clear the tombstone") }
            },

            defineStep("I just deleted a conversation") { ctx, _, _ in
                try await seedAndOpen(offline: false); try await delete(); return ctx
            },
            defineStep("the app refreshes conversation statuses") { ctx, _, _ in
                // A status refresh re-reads disk through the same load path; the
                // pending-delete filter must keep the tombstoned id out.
                let m = await w.makeManager(DeleteRecorder())
                await MainActor.run { w.mgr = m }
                return ctx
            },
            defineCheck("the deleted conversation stays gone") { _, _, _ in
                let gone = await MainActor.run { !w.mgr.captures.contains { $0.captureId == w.id }
                    && !w.mgr.visibleCaptures.contains { $0.captureId == w.id } }
                guard gone else { throw BrineStepError("a status refresh resurrected the deleted conversation") }
            },
        ]
    }
}
