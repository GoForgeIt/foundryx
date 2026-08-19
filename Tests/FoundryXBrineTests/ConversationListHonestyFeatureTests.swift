import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/conversation-list-honesty.feature — the list tells the
/// truth (stale empties pruned at launch, ended cards never say "Recording", only the
/// live conversation shows the indicator, completed conversations stop polling) and the
/// sync banner counts only real work. Drives the REAL seams: CaptureManager
/// visibleCaptures / processingConversationCount / pendingSegments / drainActive /
/// ensureRecentTranscriptCached, and the pure ConversationProgress.resolve +
/// CaptureCardPresentation.statusWord folds the cards render through. Hermetic.
final class ConversationListHonestyFeatureTests: XCTestCase {
    func testConversationListHonestyFeature() async throws {
        try await BrineFeatureRunner.run("conversation-list-honesty",
                                         registry: StepRegistry(ConversationListHonestySteps.make(world: ConversationListHonestyWorld())))
    }
}

private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
}

@MainActor
private final class ConversationListHonestyWorld: @unchecked Sendable {
    let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    var dir: URL!
    var mgr: CaptureManager!

    var emptyId = "omi-20260706-090000-empty001"
    var endedProgress: ConversationProgress?
    var endedStatusWord: String?
    var activeProgress: ConversationProgress?
    var olderProgress: ConversationProgress?
    var cachedId = "omi-20260706-100000-cached01"
    var fetchRecorder = FetchRecorder()
    var realPendingCount = 0
    var pendingObserved: Int?
    var drainObserved: Bool?
    var readyId = "omi-20260706-110000-ready001"
    var processingObserved: Int?
    var readyVisible: Bool?

    func freshDir() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-honesty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A capture with `n` segments; `acked` marks them synced (else they are pending upload).
    func seedCapture(_ id: String, segments n: Int, acked: Bool, startedAt: UInt64 = 1_720_000_000) throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        for i in 0..<n {
            let seg = cdir.appendingPathComponent(CaptureWAL.segName(UInt64(i)))
            try Data([UInt8(i & 0xff), 1, 2, 3]).write(to: seg)
            if acked { try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack")) }
        }
        ConversationMetaStore.save(ConversationMeta(startedAt: startedAt, endedAt: startedAt + 60),
                                   captureId: id, baseDir: dir)
    }

    /// An "opened but never received audio" zombie: a meta sidecar, zero segments.
    func seedEmptyOpened(_ id: String) throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        ConversationMetaStore.save(ConversationMeta(startedAt: 1_720_000_000), captureId: id, baseDir: dir)
    }

    func makeManager(fetch: (@Sendable (String) async -> CaptureContent?)? = { _ in nil }) async {
        let m = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                               finalize: { _, _ in }, fetchContent: fetch)
        #if os(iOS)
        m.micPermissionOverrideForTests = true
        #endif
        await m.hydration?.value
        mgr = m
    }
}

private enum ConversationListHonestySteps {
    static func make(world w: ConversationListHonestyWorld) -> [StepDefinition] {
        @MainActor func visibleIds() -> Set<String> { Set(w.mgr.visibleCaptures.map { $0.captureId }) }

        return [
            // MARK: stale empties pruned at launch
            defineStep("yesterday's capture opened but never received any audio") { ctx, _, _ in
                try await MainActor.run { try w.freshDir(); try w.seedEmptyOpened(w.emptyId) }
                return ctx
            },
            defineStep("I launch the app") { ctx, _, _ in await w.makeManager(); return ctx },
            defineCheck("that conversation does not appear in my list") { _, _, _ in
                let absent = await MainActor.run { !visibleIds().contains(w.emptyId) }
                guard absent else { throw BrineStepError("a stale empty capture is visible at launch") }
            },
            defineCheck("it does not appear later in this same session either") { _, _, _ in
                // The prune republished the visible list at launch; it must still be absent
                // when the list is read again later in the same session (no relaunch).
                let absent = await MainActor.run { !visibleIds().contains(w.emptyId) }
                guard absent else { throw BrineStepError("the empty capture reappeared later in the session") }
            },

            // MARK: an ended conversation never claims to be recording
            defineStep("a conversation that ended and has no audio segments on the phone") { ctx, _, _ in
                // The exact fold the card renders through: an empty WAL reports .recording,
                // but not-streaming must resolve to a saved (non-live) state.
                await MainActor.run {
                    w.endedProgress = ConversationProgress.resolve(wal: .recording, streaming: false,
                                                                   door: .stored, hasTitle: false,
                                                                   hasCachedTranscript: false)
                }
                return ctx
            },
            defineStep("I look at its card in the list") { ctx, _, _ in
                await MainActor.run {
                    w.endedStatusWord = CaptureCardPresentation.statusWord(progress: w.endedProgress ?? .recording,
                                                                           droppedReason: nil, destination: .computer)
                }
                return ctx
            },
            defineCheck("its status does not say \"Recording\"") { _, _, _ in
                let (progress, word) = await MainActor.run { (w.endedProgress, w.endedStatusWord) }
                guard progress != .recording, word != "Recording" else {
                    throw BrineStepError("an ended conversation still reads Recording (\(word ?? "nil"))")
                }
            },
            defineCheck("it shows no live green recording indicator") { _, _, _ in
                // The recording indicator is driven by progress == .recording.
                let progress = await MainActor.run { w.endedProgress }
                guard progress != .recording else {
                    throw BrineStepError("an ended conversation shows the live recording indicator")
                }
            },

            // MARK: only the live conversation shows a recording indicator
            defineStep("I am actively recording a conversation right now") { ctx, _, _ in
                await MainActor.run {
                    w.activeProgress = ConversationProgress.resolve(wal: .recording, streaming: true,
                                                                    door: .stored, hasTitle: false,
                                                                    hasCachedTranscript: false)
                }
                return ctx
            },
            defineStep("older conversations exist in my list") { ctx, _, _ in
                await MainActor.run {
                    w.olderProgress = ConversationProgress.resolve(wal: .savedOnPhone, streaming: false,
                                                                   door: .stored, hasTitle: false,
                                                                   hasCachedTranscript: false)
                }
                return ctx
            },
            defineStep("I look at the list") { ctx, _, _ in ctx },
            defineCheck("only the active conversation shows the recording indicator") { _, _, _ in
                let (active, older) = await MainActor.run { (w.activeProgress, w.olderProgress) }
                guard active == .recording, older != .recording else {
                    throw BrineStepError("recording indicator not confined to the live conversation")
                }
            },

            // MARK: a completed conversation stops asking the computer
            defineStep("a conversation whose transcript is already saved on my phone") { ctx, _, _ in
                try await MainActor.run {
                    try w.freshDir()
                    try w.seedCapture(w.cachedId, segments: 2, acked: true)
                    TranscriptCacheStore.save(CachedTranscript(transcript: "the whole conversation",
                                                               title: "Done", summary: "s", fetchedAt: 1),
                                              captureId: w.cachedId, baseDir: w.dir)
                    w.fetchRecorder = FetchRecorder()
                }
                let rec = await MainActor.run { w.fetchRecorder }
                await w.makeManager(fetch: { id in rec.record(id); return nil })
                return ctx
            },
            defineStep("I look at my conversation list") { ctx, _, _ in ctx },
            defineCheck("the app does not keep asking the computer for that conversation's status") { _, _, _ in
                let (calls, progress) = await MainActor.run { () -> ([String], ConversationProgress) in
                    // A completed (cached) conversation is Ready and generates no further
                    // computer requests — the on-sight fetch guards out immediately.
                    w.mgr.ensureRecentTranscriptCached(w.cachedId)
                    let p = ConversationProgress.resolve(wal: .savedToComputer, streaming: false,
                                                         door: .stored, hasTitle: false,
                                                         hasCachedTranscript: true)
                    return (w.fetchRecorder.calls, p)
                }
                guard calls.isEmpty else { throw BrineStepError("a completed conversation still asked the computer (\(calls))") }
                guard progress == .ready else { throw BrineStepError("a cached conversation did not read Ready") }
            },

            // MARK: sync banner counts only real work
            defineStep("some old conversations were discarded as empty") { ctx, _, _ in
                try await MainActor.run { try w.freshDir(); try w.seedEmptyOpened("omi-20260706-080000-empty900") }
                return ctx
            },
            defineStep("a real conversation still has segments waiting to upload") { ctx, _, _ in
                await MainActor.run { w.realPendingCount = 4 }
                try await MainActor.run { try w.seedCapture("omi-20260706-081000-real0001", segments: 4, acked: false) }
                return ctx
            },
            defineStep("I read the sync banner") { ctx, _, _ in
                await w.makeManager()
                await MainActor.run { w.pendingObserved = w.mgr.pendingSegments; w.drainObserved = w.mgr.drainActive }
                return ctx
            },
            defineCheck("the pending count includes only the real conversation's segments") { _, _, _ in
                let (observed, expected) = await MainActor.run { (w.pendingObserved, w.realPendingCount) }
                guard observed == expected else {
                    throw BrineStepError("pending count \(observed ?? -1) != real conversation's \(expected)")
                }
            },
            defineCheck("the banner says syncing only while uploads are actually running") { _, _, _ in
                // "syncing" is gated on an active drain, NOT on the mere existence of
                // unsynced bytes: pending>0 but no drain in flight ⇒ not syncing.
                let (drain, hasPending) = await MainActor.run { (w.drainObserved, w.mgr.hasPending) }
                guard hasPending == true else { throw BrineStepError("expected real pending work") }
                guard drain == false else { throw BrineStepError("banner claims syncing with no drain in flight") }
            },

            // MARK: the banner surfaces how many conversations are processing
            defineStep("two conversations are still being transcribed") { ctx, _, _ in
                try await MainActor.run {
                    try w.freshDir()
                    try w.seedCapture("omi-20260706-120000-proc0001", segments: 3, acked: true, startedAt: 1_720_010_000)
                    try w.seedCapture("omi-20260706-121000-proc0002", segments: 3, acked: true, startedAt: 1_720_011_000)
                }
                return ctx
            },
            defineStep("a third conversation's transcript is ready") { ctx, _, _ in
                try await MainActor.run {
                    try w.seedCapture(w.readyId, segments: 2, acked: true, startedAt: 1_720_012_000)
                    TranscriptCacheStore.save(CachedTranscript(transcript: "ready transcript text",
                                                               title: "Ready one", summary: "s", fetchedAt: 1),
                                              captureId: w.readyId, baseDir: w.dir)
                }
                return ctx
            },
            defineStep("I look at the top of the list") { ctx, _, _ in
                await w.makeManager()
                await MainActor.run {
                    w.processingObserved = w.mgr.processingConversationCount
                    w.readyVisible = w.mgr.visibleCaptures.contains { $0.captureId == w.readyId }
                }
                return ctx
            },
            defineCheck("the banner says two conversations are processing") { _, _, _ in
                let observed = await MainActor.run { w.processingObserved }
                guard observed == 2 else { throw BrineStepError("processing count \(observed ?? -1) != 2") }
            },
            defineCheck("it does not count the ready conversation") { _, _, _ in
                let (visible, count) = await MainActor.run { (w.readyVisible, w.processingObserved) }
                guard visible == true else { throw BrineStepError("the ready conversation is not even visible") }
                guard count == 2 else { throw BrineStepError("the ready conversation was counted as processing") }
            },
        ]
    }
}
