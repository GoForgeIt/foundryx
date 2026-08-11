import XCTest
import Foundation

/// T-PHONE-CHATLAW's 12px-floor requirement (tracks.md): "recording foot caption 8.5,
/// island status 8, live transcript 10.5 must come up." Three NAMED sites only —
/// `RecordingScreen.swift` carries other sub-12 text (e.g. the 9px "Title updates as
/// you speak." caption) that belongs to `T-GRAIN-TYPE`'s full sub-12px sweep across all
/// five consumers, not this track; asserting the whole file would silently widen this
/// track's scope into that one's. `swift test` compiles only the SPM package and
/// cannot import `App/` at all (the exact gap `scripts/ci-gates.sh`'s `compile` phase
/// exists to close; see its header comment). So this reads the REAL shipped source
/// file by repo path, the same `#filePath`-relative mechanism `BrineFeatureRunner`
/// already uses for `features/` (three parents up from `Tests/FoundryXBrineTests/`),
/// rather than duplicating the literal in a second place a source edit could drift
/// away from.
final class RecordingScreen12pxFloorTests: XCTestCase {

    private static func recordingScreenSource() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("App/RecordingScreen.swift"))
    }

    /// Every `GrainFont.sans(<n>` literal size in a source string, in appearance order.
    static func sansSizes(in source: String) -> [Double] {
        let pattern = #"GrainFont\.sans\(\s*([0-9]+(?:\.[0-9]+)?)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .compactMap { Double(ns.substring(with: $0.range(at: 1))) }
    }

    private struct MarkerNotFound: Error, CustomStringConvertible {
        let marker: String
        var description: String { "marker not found (source drifted?): \(marker)" }
    }

    /// The text strictly between two markers, exclusive — used to isolate one named
    /// computed property / type's body so the assertion cannot accidentally read a
    /// DIFFERENT, out-of-scope site that happens to share the same file. A missing
    /// marker throws (fails the test LOUD) rather than silently scanning zero text.
    private static func region(_ source: String, from start: String, to end: String) throws -> String {
        guard let s = source.range(of: start) else { throw MarkerNotFound(marker: start) }
        let tail = source[s.upperBound...]
        let e = tail.range(of: end) ?? tail.endIndex..<tail.endIndex
        return String(tail[..<e.lowerBound])
    }

    /// Scenario: island status (breathing dot · status word · elapsed clock) — both
    /// `GrainFont.sans` calls in this region — sit at or above the 12px floor.
    func testIslandStatusAtOrAbove12() throws {
        let source = try Self.recordingScreenSource()
        let region = try Self.region(source,
            from: "private var islandStatus: some View {",
            to: "// MARK: 2")
        let sizes = Self.sansSizes(in: region)
        XCTAssertEqual(sizes.count, 2, "expected exactly 2 GrainFont.sans() calls in islandStatus, found \(sizes)")
        XCTAssertTrue(sizes.allSatisfy { $0 >= 12 }, "island status text below the 12px floor: \(sizes)")
    }

    /// Scenario: the recording foot's caption ("Saves this voice note and returns to
    /// Capture.") sits at or above the 12px floor.
    func testRecordingFootCaptionAtOrAbove12() throws {
        let source = try Self.recordingScreenSource()
        let region = try Self.region(source,
            from: "private var recordingFoot: some View {",
            to: "\n}\n")
        let sizes = Self.sansSizes(in: region)
        XCTAssertEqual(sizes.count, 1, "expected exactly 1 GrainFont.sans() call in recordingFoot, found \(sizes)")
        XCTAssertTrue(sizes.allSatisfy { $0 >= 12 }, "recording foot caption below the 12px floor: \(sizes)")
    }

    /// Scenario: the live transcript's rendered words sit at or above the 12px floor.
    func testLiveTranscriptAtOrAbove12() throws {
        let source = try Self.recordingScreenSource()
        let region = try Self.region(source,
            from: "private struct RecordingLiveTranscript: View {",
            to: "\n}\n")
        let sizes = Self.sansSizes(in: region)
        XCTAssertEqual(sizes.count, 1, "expected exactly 1 GrainFont.sans() call in RecordingLiveTranscript, found \(sizes)")
        XCTAssertTrue(sizes.allSatisfy { $0 >= 12 }, "live transcript below the 12px floor: \(sizes)")
    }

    /// Falsification: the scan MUST be able to go red. Feed it a mutant string with an
    /// 11px node — proven here rather than asserted about a scratch build nobody can
    /// see, per T-PHONE-CHATLAW's own falsification clause ("inject an 11px node and
    /// require the check to name it").
    func testScannerDetectsAnInjectedSub12Mutant() {
        let mutant = """
        Text("mutant")
            .font(GrainFont.sans(11))
            .foregroundStyle(GrainColor.textMuted)
        """
        let sizes = Self.sansSizes(in: mutant)
        XCTAssertEqual(sizes, [11])
        XCTAssertFalse(sizes.allSatisfy { $0 >= 12 },
                       "the scanner failed to catch its own planted 11px mutant")
    }
}
