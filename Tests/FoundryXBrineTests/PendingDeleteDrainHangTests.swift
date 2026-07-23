import XCTest
import Foundation
@testable import FoundryXKit

/// REGRESSION GATE for the build-286 field hang.
///
/// Device telemetry (owner's phone, 212 conversations) showed 8 MetricKit hangs 598–1939ms
/// and nav-stall spans up to 4161ms. The app's own stack sampler symbolicated the top frame
/// to `CaptureManager.retryPendingDeletes()`:
///
///     stallstack ms=501 fr=libsystem_kernel.dylib+0x6844 ; Foundation+0x26ec8 ;
///                FoundryX@60bd8356+0xb904c ; libswift_Concurrency.dylib+0x53b4
///
/// and the log named the cause outright — the owner had deleted many junk conversations, the
/// desktop door was unreachable, so every delete stayed pending:
///
///     → DELETE capture=omi-20260721-202650-86B2A89A
///     [WARN] remote delete failed (Could not connect to the server.) — staying pending
///
/// The lane, on `@MainActor CaptureManager` and re-entered by EVERY 5s drain cycle:
///   1. did a full synchronous `contentsOfDirectory(at: baseDir)` walk ON the main actor;
///   2. looped serially, one un-timeboxed network call per pending delete;
///   3. had no batch bound and no circuit-breaker for a known-unreachable door.
///
/// The instruments here are the deterministic counters this repo already uses for CQRS
/// invariants (`mainThreadTranscriptDecodesForTests` and friends) — HARD INTEGERS, not
/// wall-clock budgets, so nothing can flake into green:
///
///   * `CaptureManager.mainThreadPendingDeleteDiskOpsForTests` — blocking filesystem work the
///     lane did while ON the main thread. Must be 0.
///   * `CaptureManager.remoteDeleteAttemptsForTests` — door calls attempted per cycle.
///
/// CORRECTNESS IS THE OTHER HALF and is asserted just as hard: a pending delete is NEVER
/// dropped while the door is down, the `.deleted` / `.needs-delete` tombstone survives, and
/// the queue drains completely (tombstone dirs torn down) once the door is reachable again.
@MainActor
final class PendingDeleteDrainHangTests: XCTestCase {

    private let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")

    /// The field shape: many junk conversations deleted in one sitting.
    private static let pendingN = 24

    private func tempDir(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A recorder that models an UNREACHABLE door: it throws the exact URL error the device
    /// log carried ("Could not connect to the server." = NSURLErrorCannotConnectToHost), and
    /// counts how many times it was asked.
    final class DoorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        /// When true every call throws `URLError(.cannotConnectToHost)` — the field condition.
        var unreachable = false
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) throws {
            lock.lock(); _calls.append(id); let down = self.unreachable; lock.unlock()
            if down { throw URLError(.cannotConnectToHost) }
        }
    }

    /// Seed a library of real conversation dirs (meta + card + transcript + a segment), so the
    /// base-dir walk the old lane performed is a genuinely expensive one.
    @discardableResult
    private func seedLibrary(dir: URL, count: Int) throws -> [String] {
        var ids: [String] = []
        for i in 0..<count {
            let id = String(format: "omi-20260721-2026%02d-DEL%05d", i % 60, i)
            ids.append(id)
            let cdir = dir.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
            let seg = cdir.appendingPathComponent(CaptureWAL.segName(0))
            try Data([1, 2, 3, 4]).write(to: seg)
            try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
            ConversationMetaStore.save(ConversationMeta(startedAt: UInt64(1_000 + i * 600),
                                                        endedAt: UInt64(1_060 + i * 600)),
                                       captureId: id, baseDir: dir)
            ConversationCardStore.merge(captureId: id, baseDir: dir,
                                        title: "Junk \(i)", summary: "Deleted by the owner",
                                        stage: "ready")
            TranscriptCacheStore.save(CachedTranscript(transcript: "words \(i)", title: "Junk \(i)",
                                                       summary: "Deleted by the owner", fetchedAt: 1),
                                      captureId: id, baseDir: dir)
        }
        return ids
    }

    private func manager(_ dir: URL, door: DoorRecorder) async -> CaptureManager {
        let m = CaptureManager(target: target, baseDir: dir, source: ReplaySource(frames: []),
                               deleteCapture: { try door.record($0) },
                               fetchContent: { _ in nil })
        await m.hydration?.value
        return m
    }

    private func hasMarker(_ id: String, _ marker: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(marker).path)
    }

    // MARK: - THE REPRO

    /// N pending deletes + an unreachable door, driven through the SAME entry point the drain
    /// loop uses. The main actor must do NO blocking disk work, and the lane must give up on
    /// the cycle after the first connection failure instead of paying N timeouts.
    func testUnreachableDoorDrainDoesNoMainThreadDiskWorkAndStopsAfterFirstFailure() async throws {
        let dir = try tempDir("pending-delete-hang"); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try seedLibrary(dir: dir, count: Self.pendingN)

        let door = DoorRecorder()
        let mgr = await manager(dir, door: door)
        for id in ids { mgr.deleteConversation(id) }          // the owner's deletion sitting
        door.unreachable = true                                // …and the computer is asleep

        CaptureManager.resetPendingDeleteProbesForTests()
        await mgr.retryPendingDeletes()                        // ONE drain cycle

        let diskOps = CaptureManager.mainThreadPendingDeleteDiskOpsForTests
        let attempts = CaptureManager.remoteDeleteAttemptsForTests
        print("REPRO pending-delete: N=\(Self.pendingN) mainThreadDiskOps=\(diskOps) attempts=\(attempts)")

        XCTAssertEqual(diskOps, 0,
                       "the pending-delete lane must do ZERO blocking filesystem work on the " +
                       "main actor — RED: it did \(diskOps) (the build-286 stallstack frame)")
        XCTAssertLessThanOrEqual(attempts, 1,
                                 "an unreachable door must trip the breaker after the FIRST " +
                                 "failure — RED: \(attempts) serial timeouts in one cycle")

        // CORRECTNESS: nothing was dropped. Every tombstone is intact and still queued.
        for id in ids {
            XCTAssertTrue(hasMarker(id, ".deleted", in: dir), "\(id) lost its delete tombstone")
            XCTAssertTrue(hasMarker(id, ".needs-delete", in: dir), "\(id) lost its pending intent")
        }
        XCTAssertEqual(mgr.pendingDeleteQueueDepthForTests, Self.pendingN,
                       "every pending delete must stay queued while the door is unreachable")
    }

    /// Repeated drain cycles inside the breaker's backoff window must cost NOTHING — this is
    /// the recurrence (the freeze came back every 5s), not just the first freeze.
    func testRepeatedCyclesWhileDoorIsDownCostNothing() async throws {
        let dir = try tempDir("pending-delete-recur"); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try seedLibrary(dir: dir, count: Self.pendingN)

        let door = DoorRecorder()
        let mgr = await manager(dir, door: door)
        for id in ids { mgr.deleteConversation(id) }
        door.unreachable = true

        await mgr.retryPendingDeletes()                        // trips the breaker

        CaptureManager.resetPendingDeleteProbesForTests()
        for _ in 0..<10 { await mgr.retryPendingDeletes() }     // ~50s of drain ticks

        XCTAssertEqual(CaptureManager.mainThreadPendingDeleteDiskOpsForTests, 0,
                       "recurring drains must never re-walk the base dir on the main actor")
        XCTAssertEqual(CaptureManager.remoteDeleteAttemptsForTests, 0,
                       "inside the backoff window the lane must not touch the network at all")
        XCTAssertEqual(mgr.pendingDeleteQueueDepthForTests, Self.pendingN,
                       "backing off must never drop a queued delete")
    }

    /// …and the whole point of backing off: when the door comes back, every pending delete
    /// still reaches it and the local tombstones are torn down. Data the user asked to be
    /// deleted must never be resurrected, and must never be forgotten either.
    func testPendingDeletesFullyDrainOnceTheDoorIsReachableAgain() async throws {
        let dir = try tempDir("pending-delete-recover"); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try seedLibrary(dir: dir, count: Self.pendingN)

        let door = DoorRecorder()
        let mgr = await manager(dir, door: door)
        for id in ids { mgr.deleteConversation(id) }
        door.unreachable = true
        await mgr.retryPendingDeletes()

        // The computer wakes up. Drain until the queue empties; each cycle is bounded, and the
        // breaker's backoff window is expired between cycles (a real drain simply waits it out).
        door.unreachable = false
        var cycles = 0
        while mgr.pendingDeleteQueueDepthForTests > 0 && cycles < Self.pendingN + 5 {
            mgr.expirePendingDeleteBackoffForTests()
            await mgr.retryPendingDeletes()
            cycles += 1
        }

        XCTAssertEqual(mgr.pendingDeleteQueueDepthForTests, 0, "the queue must fully drain")
        XCTAssertEqual(Set(door.calls.filter { ids.contains($0) }), Set(ids),
                       "EVERY pending delete must reach the door once it is reachable")
        for id in ids {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(id, isDirectory: true).path),
                           "\(id): an ACKed remote delete must tear the whole tombstone dir down")
        }
    }

    /// A cycle is BOUNDED: it never attempts the whole backlog at once even when every call
    /// succeeds, so one drain tick can't monopolise the lane.
    func testOneCycleIsBounded() async throws {
        let dir = try tempDir("pending-delete-bounded"); defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try seedLibrary(dir: dir, count: Self.pendingN)

        let door = DoorRecorder()
        let mgr = await manager(dir, door: door)
        for id in ids { mgr.deleteConversation(id) }

        CaptureManager.resetPendingDeleteProbesForTests()
        await mgr.retryPendingDeletes()

        XCTAssertLessThanOrEqual(CaptureManager.remoteDeleteAttemptsForTests,
                                 CaptureManager.maxPendingDeletesPerDrain,
                                 "a single drain cycle must attempt at most the batch cap")
        XCTAssertEqual(CaptureManager.mainThreadPendingDeleteDiskOpsForTests, 0,
                       "even the happy path must not tear tombstones down on the main actor")
    }

    /// A door leg that never returns must be abandoned at the deadline rather than parked
    /// forever — the bound that turns "no timeout" into "fails fast".
    func testDeadlineRaceAbandonsAHangingLeg() async throws {
        do {
            _ = try await AsyncDeadline.race(0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return 1
            }
            XCTFail("a hanging leg must not be awaited past its deadline")
        } catch is AsyncDeadline.Exceeded {
            // expected
        }
    }
}
