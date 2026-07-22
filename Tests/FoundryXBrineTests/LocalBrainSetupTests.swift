import XCTest
@testable import FoundryXKit

// MARK: - Deterministic harness

/// A hand-wound clock: the stall watchdog only ever asks "how long since progress
/// advanced", so a fake clock lets us prove a 60-second stall in milliseconds instead
/// of waiting out a real ~150 MB fetch.
final class FakeSetupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ d: TimeInterval) { lock.lock(); t += d; lock.unlock() }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

/// The on-device brain's bounded, honest setup (track 20260722T1244). Every seam —
/// download, build, clock, sleep — is injected, so these run instantly and
/// deterministically and never touch the network.
@MainActor
final class LocalBrainSetupTests: XCTestCase {

    private let fastPolicy = BrainSetupPolicy(stallTimeout: 60, buildTimeout: 180, pollInterval: 2)

    /// THE BUG: a download that stops advancing used to spin forever. It must now fail
    /// in bounded time into the honest failure state — not the setup state.
    func testStalledDownloadFailsHonestlyInsteadOfSpinningForever() async throws {
        let clock = FakeSetupClock()
        let status = LocalBrainStatus()
        let preparer = LocalBrainPreparer(
            steps: .init(
                download: { onProgress in
                    onProgress(0.1)                      // 10% lands, then the pipe dies
                    try await Task.sleep(nanoseconds: 120_000_000_000)
                },
                build: { XCTFail("build must not run after a stalled download") }),
            policy: fastPolicy,
            status: status,
            clock: { clock.now },
            // Virtual time: each watchdog poll costs `pollInterval` fake seconds.
            sleep: { d in clock.advance(d); await Task.yield() })

        do {
            try await preparer.prepare()
            XCTFail("a stalled download must not succeed")
        } catch let error as BrainSetupError {
            guard case .downloadStalled = error else { return XCTFail("wrong error: \(error)") }
        }

        // The state the user sees is the honest failure — NOT "Setting up your…".
        XCTAssertTrue(status.isFailed, "phase should be .failed, was \(status.phase)")
        XCTAssertFalse(status.isPreparing, "the spinner must be gone")
        XCTAssertTrue(status.canRetry, "a failure with no way out is still a dead end")
        XCTAssertEqual(status.retryLabel, "Try again")
        let banner = try XCTUnwrap(status.bannerText)
        XCTAssertTrue(banner.contains("hasn't moved"), "banner should say it stopped moving: \(banner)")
        XCTAssertTrue(banner.contains("10%"), "banner should say how far it got: \(banner)")
        XCTAssertFalse(banner.hasPrefix("Setting up"), "must not still read as setup: \(banner)")
    }

    /// A SLOW download is not a STUCK one: 300 virtual seconds of steady progress with a
    /// 60-second stall limit must still succeed.
    func testSlowButAdvancingDownloadIsNotKilled() async throws {
        let clock = FakeSetupClock()
        let status = LocalBrainStatus()
        let preparer = LocalBrainPreparer(
            steps: .init(
                download: { onProgress in
                    for i in 1...100 {
                        clock.advance(3)                 // 3s per chunk ⇒ 300s total
                        onProgress(Double(i) / 100)
                        await Task.yield()
                    }
                },
                build: {}),
            policy: fastPolicy,
            status: status,
            clock: { clock.now },
            // The poll itself burns no virtual time here — only real progress moves the
            // clock — so the download outlives the stall limit many times over.
            sleep: { _ in await Task.yield() })

        try await preparer.prepare()

        XCTAssertEqual(status.phase, .ready)
        XCTAssertFalse(status.isFailed)
        XCTAssertNil(status.bannerText)
        XCTAssertGreaterThan(clock.now, fastPolicy.stallTimeout)
    }

    /// The build phase reports no progress at all, so it gets its own bound rather than
    /// an unbounded wait.
    func testHungBuildTimesOut() async throws {
        let clock = FakeSetupClock()
        let status = LocalBrainStatus()
        let preparer = LocalBrainPreparer(
            steps: .init(
                download: { onProgress in onProgress(1.0) },
                build: { try await Task.sleep(nanoseconds: 120_000_000_000) }),
            policy: fastPolicy,
            status: status,
            clock: { clock.now },
            sleep: { d in clock.advance(d); await Task.yield() })

        do {
            try await preparer.prepare()
            XCTFail("a hung build must not succeed")
        } catch let error as BrainSetupError {
            guard case .buildTimedOut = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertTrue(status.isFailed)
        XCTAssertTrue(status.canRetry)
    }

    /// Retry runs the whole setup again in-process — no relaunch.
    func testRetryAfterFailureSucceedsWithoutRestart() async throws {
        let attempts = AttemptCounter()
        let status = LocalBrainStatus()
        let preparer = LocalBrainPreparer(
            steps: .init(
                download: { _ in
                    if attempts.next() == 1 { throw URLError(.networkConnectionLost) }
                },
                build: {}),
            policy: fastPolicy,
            status: status,
            sleep: { _ in await Task.yield() })

        do {
            try await preparer.prepare()
            XCTFail("first attempt should fail")
        } catch {}
        XCTAssertTrue(status.isFailed)
        XCTAssertTrue(status.canRetry)

        try await preparer.retry()

        XCTAssertEqual(status.phase, .ready)
        XCTAssertNil(status.bannerText)
        XCTAssertFalse(status.canRetry, "a ready brain offers no retry")
        XCTAssertEqual(attempts.count, 2)
    }

    /// The retry action the BANNER holds is the one that actually works — tapping it
    /// (not calling the preparer directly) drives the brain to ready.
    func testBannerRetryActionDrivesTheRealRetry() async throws {
        let attempts = AttemptCounter()
        let status = LocalBrainStatus()
        let preparer = LocalBrainPreparer(
            steps: .init(
                download: { _ in
                    if attempts.next() == 1 { throw URLError(.timedOut) }
                },
                build: {}),
            policy: fastPolicy,
            status: status,
            sleep: { _ in await Task.yield() })

        _ = try? await preparer.prepare()
        let tap = try XCTUnwrap(status.retryAction)
        tap()

        // The action fires a task; wait (bounded) for it to land.
        for _ in 0..<200 where status.phase != .ready {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(status.phase, .ready, "tapping Try again should make the brain ready")
    }

    /// A healthy, already-present model is untouched: straight to ready, no banner.
    func testHealthyModelPreparesWithoutAnyFailureOrBanner() async throws {
        let status = LocalBrainStatus()
        let preparer = LocalBrainPreparer(
            steps: .init(download: { onProgress in onProgress(1.0) }, build: {}),
            policy: fastPolicy,
            status: status,
            sleep: { _ in await Task.yield() })

        try await preparer.prepare()
        XCTAssertEqual(status.phase, .ready)
        XCTAssertNil(status.bannerText)
        let readyAlready = await preparer.ready
        XCTAssertTrue(readyAlready)

        // Idempotent: preparing again neither re-downloads nor disturbs the state.
        try await preparer.prepare()
        XCTAssertEqual(status.phase, .ready)
    }

    /// A late progress report from the attempt that already timed out must not put the
    /// spinner back — that is exactly how "Setting up you…" became immortal.
    func testFailureIsStickyAgainstLateProgressReports() {
        let status = LocalBrainStatus()
        status.setFailed("the download stopped at 10% and hasn't moved for 60s", retry: {})
        status.setDownloading(0.2)
        status.setLoading()
        XCTAssertTrue(status.isFailed)
        XCTAssertFalse(status.isPreparing)
    }

    /// Only ADVANCING progress counts — repeating the same fraction is what a stalled
    /// transfer looks like, and must not reset the stall clock.
    func testHeartbeatOnlyResetsOnRealAdvance() {
        let clock = FakeSetupClock()
        let beat = ProgressHeartbeat(clock: { clock.now })
        beat.advance(to: 0.5)
        clock.advance(30)
        beat.advance(to: 0.5)          // same fraction again: not progress
        XCTAssertEqual(beat.idle, 30)
        beat.advance(to: 0.4)          // going backwards: not progress
        XCTAssertEqual(beat.idle, 30)
        beat.advance(to: 0.6)          // real progress
        XCTAssertEqual(beat.idle, 0)
        XCTAssertEqual(beat.fraction, 0.6)
    }
}
