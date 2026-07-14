import XCTest
import Foundation
@testable import FoundryXKit

/// Delete conversation (phone side): deletion is an instant local tombstone plus a
/// durable remote-delete intent. The tests stay door-free by injecting the delete
/// seam; disk is still real so relaunch/idempotence are covered.
@MainActor
final class CaptureDeleteTests: XCTestCase {

    private let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedConversation(_ id: String, baseDir: URL) throws {
        let cdir = baseDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([1, 2, 3, 4]).write(to: seg)
        try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
        try Data().write(to: cdir.appendingPathComponent(".needs-finalize"))
        ConversationMetaStore.save(ConversationMeta(startedAt: 100, endedAt: 160),
                                   captureId: id, baseDir: baseDir)
        ConversationCardStore.merge(captureId: id, baseDir: baseDir,
                                    title: "Delete me", summary: "Temporary", stage: "ready")
        TranscriptCacheStore.save(CachedTranscript(transcript: "words", title: "Delete me",
                                                   summary: "Temporary", fetchedAt: 1),
                                  captureId: id, baseDir: baseDir)
    }

    private func manager(_ dir: URL,
                         deletes: DeleteRecorder = DeleteRecorder()) async -> CaptureManager {
        let m = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                               deleteCapture: { try deletes.record($0) },
                               fetchContent: { _ in nil })
        await m.hydration?.value   // hydration is async now (startup-hang fix)
        return m
    }

    final class DeleteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var shouldFail = false
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) throws {
            lock.lock()
            _calls.append(id)
            let fail = shouldFail
            lock.unlock()
            if fail { throw DoorError.http(503) }
        }
    }

    func testDeleteRemovesFromCapturesWritesMarkersAndDeletesFiles() async throws {
        let dir = try tempDir("delete-local")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260707-120000-delete01"
        try seedConversation(id, baseDir: dir)
        let mgr = await manager(dir)
        XCTAssertTrue(mgr.captures.contains { $0.captureId == id })

        mgr.deleteConversation(id)

        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        XCTAssertFalse(mgr.captures.contains { $0.captureId == id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".deleted").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".needs-delete").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(CaptureWAL.segName(0)).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cdir.appendingPathComponent("meta.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cdir.appendingPathComponent("card.json").path))
        XCTAssertFalse(TranscriptCacheStore.hasCachedTranscript(captureId: id, baseDir: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".lore-confirmed").path))
    }

    func testDeletedIdNeverRehydratesViaLoadExisting() async throws {
        let dir = try tempDir("delete-relaunch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260707-120100-delete02"
        try seedConversation(id, baseDir: dir)
        await manager(dir).deleteConversation(id)

        let relaunched = await manager(dir)

        XCTAssertFalse(relaunched.captures.contains { $0.captureId == id })
        XCTAssertFalse(relaunched.visibleCaptures.contains { $0.captureId == id })
    }

    func testSecondDeleteIsNoOp() async throws {
        let dir = try tempDir("delete-idempotent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260707-120200-delete03"
        try seedConversation(id, baseDir: dir)
        let mgr = await manager(dir)

        mgr.deleteConversation(id)
        mgr.deleteConversation(id)

        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".deleted").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".needs-delete").path))
        XCTAssertFalse(mgr.captures.contains { $0.captureId == id })
    }

    func testPendingNeedsDeleteSurvivesRelaunchAndRetries() async throws {
        let dir = try tempDir("delete-retry")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "omi-20260707-120300-delete04"
        try seedConversation(id, baseDir: dir)
        let failing = DeleteRecorder()
        failing.shouldFail = true
        let first = await manager(dir, deletes: failing)
        first.deleteConversation(id)
        await first.retryPendingDeletes()
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".needs-delete").path))

        let succeeding = DeleteRecorder()
        let relaunched = await manager(dir, deletes: succeeding)
        await relaunched.retryPendingDeletes()

        XCTAssertEqual(succeeding.calls, [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cdir.path),
                       "ACKed remote delete removes the whole tombstone dir")
    }
}
