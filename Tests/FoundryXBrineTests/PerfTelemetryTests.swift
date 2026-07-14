import XCTest
import Foundation
import FoundryXKit

/// Performance self-telemetry (features/perf-telemetry.feature). The formatters
/// are pure (no MetricKit, no network) so the line shape — what reaches the
/// diagnostics endpoint and can be grepped/aggregated server-side — is pinned.
final class PerfTelemetryTests: XCTestCase {

    private let ctx = PerfContext(build: "166", installId: "a1b2c3d4")

    // Scenario: a timed span becomes one shippable perf line
    func testSpanMarkerLine() {
        let line = PerfDiag.marker(name: "capture-hydrate", ms: 820, ctx: ctx)
        XCTAssertTrue(line.hasPrefix("perf "), "grep-anchored prefix")
        XCTAssertTrue(line.contains("span=capture-hydrate"))
        XCTAssertTrue(line.contains("ms=820"))
        XCTAssertTrue(line.contains("build=166"))
    }

    // Scenario: a system hang diagnostic becomes a compact line
    func testHangLine() {
        let line = PerfDiag.hang(ms: 7562, blamedFrame: "CaptureWAL.computeStatus", ctx: ctx)
        XCTAssertTrue(line.contains("hang"))
        XCTAssertTrue(line.contains("ms=7562"))
        XCTAssertTrue(line.contains("at=CaptureWAL.computeStatus"))
        XCTAssertTrue(line.contains("build=166"))
    }

    // Scenario: a launch metric becomes a compact line
    func testLaunchLine() {
        let line = PerfDiag.launch(phase: "first-draw", ms: 1400, ctx: ctx)
        XCTAssertTrue(line.contains("launch"))
        XCTAssertTrue(line.contains("phase=first-draw"))
        XCTAssertTrue(line.contains("ms=1400"))
    }

    // Scenario: every perf line carries the build and an anonymous install id
    // …and it never carries personal data.
    func testEveryLineCarriesBuildAndInstallIdOnly() {
        let lines = [
            PerfDiag.marker(name: "x", ms: 1, ctx: ctx),
            PerfDiag.hang(ms: 1, blamedFrame: "y", ctx: ctx),
            PerfDiag.launch(phase: "z", ms: 1, ctx: ctx),
        ]
        for line in lines {
            XCTAssertTrue(line.contains("build=166"))
            XCTAssertTrue(line.contains("dev=a1b2c3d4"), "the anonymous install id, not a name/email")
            // No PII markers ever.
            XCTAssertFalse(line.contains("@"), "no email")
            XCTAssertFalse(line.localizedCaseInsensitiveContains("token"))
        }
    }

    // Scenario: a slow span is flagged, a fast one is not
    func testSlowThreshold() {
        XCTAssertTrue(PerfDiag.isSlow(ms: 820, threshold: 500))
        XCTAssertFalse(PerfDiag.isSlow(ms: 120, threshold: 500))
        // A slow span carries a "SLOW" tag so it greps out of the noise.
        XCTAssertTrue(PerfDiag.marker(name: "x", ms: 820, ctx: ctx, slowThreshold: 500).contains("SLOW"))
        XCTAssertFalse(PerfDiag.marker(name: "x", ms: 120, ctx: ctx, slowThreshold: 500).contains("SLOW"))
    }

    // A PerfSpan measures elapsed time with an injectable clock (deterministic).
    func testPerfSpanMeasuresElapsed() {
        var now: UInt64 = 1_000_000_000            // ns
        let span = PerfSpan(name: "hydrate", clock: { now })
        now += 820_000_000                          // +820ms
        XCTAssertEqual(span.elapsedMs(), 820)
    }

    // The blamed frame extractor pulls the first FoundryX frame from a call stack.
    func testBlamedFrameExtraction() {
        let stack = [
            "0 libsystem_kernel.dylib getxattr",
            "1 Foundation _FileManagerImpl.attributesOfItem",
            "2 FoundryX CaptureWAL.computeStatus",
            "3 FoundryX CaptureManager.loadExisting",
        ]
        XCTAssertEqual(PerfDiag.firstOwnFrame(in: stack, own: "FoundryX"),
                       "CaptureWAL.computeStatus")
        // No own frame → the leaf (still useful).
        XCTAssertEqual(PerfDiag.firstOwnFrame(in: ["0 libsystem getxattr"], own: "FoundryX"),
                       "libsystem getxattr")
    }
}
