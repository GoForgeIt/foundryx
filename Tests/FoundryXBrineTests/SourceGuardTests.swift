import XCTest
import Foundation

/// B1(b) — the SOURCE GUARD (track 20260714T1800 ux_prototype_realignment).
///
/// Cross-cutting rule: **no consumer surface renders engineering telemetry** —
/// no segment counts, no frame/byte meters, no raw `DoorError` strings. The
/// presentation-model tests prove what the presentation structs say; THIS test
/// is what makes a fresh leak red anyway: it walks every `App/*.swift` view file
/// at test time and fails on the forbidden literals.
///
/// Two leaks exist at the time this guard lands and are removed by sibling
/// lanes of the same track; they are marked as EXPECTED (non-strict) failures
/// naming the lane that removes them, so the suite stays green now, goes fully
/// strict for any NEW file, and — once the integrator deletes the
/// `expectedLeaks` table after integration — locks red if a leak ever returns.
final class SourceGuardTests: XCTestCase {

    /// Forbidden view-source literals. "· frames " + "lastFrameBytes)B" are the
    /// two halves of the frames/B meter; "segments synced" is the sync-stats
    /// card line; "DoorError" is the raw transport error surfaced in chat.
    private static let forbidden: [String] = [
        "segments synced",
        "DoorError",
        "· frames ",
        "lastFrameBytes)B",
    ]

    /// Known, in-flight leaks: (literal → file basename → the lane that removes
    /// it). DELETE THIS TABLE AT INTEGRATION — an empty table is the locked-in
    /// state where any occurrence anywhere is a hard failure.
    // STRICT (integrated 2026-07-14): every lane removed its leak, so the guard now
    // locks red the instant any forbidden literal reappears in an App/ view file.
    private static let expectedLeaks: [String: [String: String]] = [:]

    /// App/ resolved relative to this test file (tests run from the package
    /// root, but #filePath is absolute and stable).
    private func appDirectory() -> URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/FoundryXBrineTests/SourceGuardTests.swift
            .deletingLastPathComponent()          // …/Tests/FoundryXBrineTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("App", isDirectory: true)
    }

    private func appViewSources() throws -> [(name: String, text: String)] {
        let dir = appDirectory()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw XCTSkip("App/ not present beside the package (checkout layout changed)")
        }
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { url in
            (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
        }
    }

    func testNoViewFileRendersEngineeringTelemetryLiterals() throws {
        let sources = try appViewSources()
        XCTAssertGreaterThan(sources.count, 5,
                             "the guard must actually see the App/ view files — a vacuous walk proves nothing")

        for literal in Self.forbidden {
            let expected = Self.expectedLeaks[literal] ?? [:]
            for (name, text) in sources where text.contains(literal) {
                if let lane = expected[name] {
                    // Known in-flight leak — the named sibling lane removes it.
                    let options = XCTExpectedFailure.Options()
                    options.isStrict = false
                    XCTExpectFailure(
                        "\"\(literal)\" is still in \(name) — removed by the \(lane) lane; delete the expectedLeaks entry at integration",
                        options: options) {
                        XCTFail("forbidden view literal \"\(literal)\" in App/\(name)")
                    }
                } else {
                    XCTFail("forbidden view literal \"\(literal)\" leaked into App/\(name) — consumer surfaces never render engineering telemetry (spec 20260714T1800, cross-cutting rule)")
                }
            }
        }
    }
}
