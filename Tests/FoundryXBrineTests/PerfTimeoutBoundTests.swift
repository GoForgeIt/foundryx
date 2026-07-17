import XCTest
import Foundation
@testable import FoundryXKit

/// TARGET 1 (WS-B perf): `withPerfTimeout` must BOUND a non-cooperative op — the caller
/// resumes AT the deadline even when the op ignores cancellation, instead of staying
/// blocked inside a throwing task group until the wedged op eventually finishes.
///
/// Telemetry proof this pins: fm-title-timeout fired at ms=20000 but fm-title-err landed
/// at 86136/88706 — the caller was stuck ~86s on a wedged LanguageModelSession turn.
/// Implicated in sustained CPU burn (fm-title-err 86s × up to 12 backfill calls).
/// A sleep that DOES NOT cooperate with Task cancellation (a fixture for the wedged,
/// non-cancellable FoundationModels turn). `Task.sleep` throws on cancel; this
/// dispatch-timer sleep ignores cancellation entirely. Free function so it can be
/// captured by the `@Sendable` op closure without capturing the (non-Sendable) test case.
private func uncancellableSleep(ms: Int) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) {
            cont.resume()
        }
    }
}

final class PerfTimeoutBoundTests: XCTestCase {

    /// Thread-safe span sink for asserting on emitted PerfHook spans.
    private final class SpanCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var spans: [(String, Int)] = []
        func record(_ name: String, _ ms: Int) { lock.lock(); spans.append((name, ms)); lock.unlock() }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return spans.map(\.0) }
        func ms(for name: String) -> Int? {
            lock.lock(); defer { lock.unlock() }; return spans.first(where: { $0.0 == name })?.1
        }
    }

    // Scenario: the caller resumes AT the deadline even when the op ignores cancellation.
    func testCallerResumesAtDeadlineWhenOpIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await withPerfTimeout("wedge-test", ms: 50) {
                await uncancellableSleep(ms: 3000)   // non-cooperative 3s wedge
                return 42
            }
            XCTFail("should have thrown PerfTimeout at the deadline")
        } catch let e as PerfTimeout {
            XCTAssertEqual(e.name, "wedge-test")
            XCTAssertEqual(e.ms, 50)
        } catch {
            XCTFail("expected PerfTimeout, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5,
                          "caller must resume at the ~50ms deadline, not after the 3s wedged op (was \(elapsed)s)")
    }

    // Scenario: the RESULT path is unchanged — an op that finishes first returns its value.
    func testResultPathReturnsOpValueUnchanged() async throws {
        let r = try await withPerfTimeout("ok", ms: 5000) { () -> Int in
            try await Task.sleep(nanoseconds: 5_000_000)   // 5ms, well under budget
            return 7
        }
        XCTAssertEqual(r, 7)
    }

    // Scenario: an op error (finishing before the deadline) propagates unchanged.
    func testOpErrorPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await withPerfTimeout("e", ms: 5000) { () -> Int in throw Boom() }
            XCTFail("expected the op's error")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    // Scenario: when a wedged op eventually completes AFTER the deadline, an
    // `<name>-orphan-done` span fires so the wedge duration stays visible in telemetry —
    // and resuming the (already-resumed) caller a second time is guarded (no crash).
    func testOrphanDoneSpanFiresWhenWedgedOpEventuallyCompletes() async {
        let collector = SpanCollector()
        PerfHook.install { name, ms in collector.record(name, ms) }
        defer { PerfHook.install { _, _ in } }

        do {
            _ = try await withPerfTimeout("orphan-test", ms: 30) {
                await uncancellableSleep(ms: 250)   // finishes long after the 30ms deadline
                return 1
            }
            XCTFail("expected PerfTimeout at the deadline")
        } catch is PerfTimeout {
            // expected — the caller resumed at 30ms
        } catch {
            XCTFail("expected PerfTimeout, got \(error)")
        }

        // The deadline win emits `<name>-timeout` immediately.
        XCTAssertTrue(collector.names.contains("orphan-test-timeout"),
                      "deadline win emits the -timeout span")

        // Poll for the orphan to finish (~250ms) and emit its -orphan-done span.
        let deadline = Date().addingTimeInterval(3)
        while !collector.names.contains("orphan-test-orphan-done"), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(collector.names.contains("orphan-test-orphan-done"),
                      "the orphaned op emits -orphan-done when it eventually completes")
        if let ms = collector.ms(for: "orphan-test-orphan-done") {
            XCTAssertGreaterThanOrEqual(ms, 200, "the orphan-done span carries the REAL wedge duration")
        }
    }
}
