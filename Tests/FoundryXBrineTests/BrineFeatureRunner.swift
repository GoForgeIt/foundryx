import XCTest
import Foundation
import BrineSwiftCore

/// Shared Brine driver used by the `*FeatureTests` files: parse
/// `features/<name>.feature`, run its scenarios against the supplied step registry
/// (which drives REAL FoundryXKit types), and fail with a readable diff if any scenario
/// does not pass. This is the exact boilerplate ChatSessionTests / CaptureResumeTests /
/// ModelPickerTests each inlined — hoisted here so the newly-wired features share one
/// hermetic runner (no real network, no real hardware; every seam is injected).
enum BrineFeatureRunner {

    /// Repo root is three parents up from this file (Tests/FoundryXBrineTests/…).
    private static func featureText(_ name: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("features/\(name).feature"))
    }

    @discardableResult
    static func run(_ name: String, registry: StepRegistry) async throws -> RunResult {
        let parsed = parseFeatureText(try featureText(name))
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed for \(name)")

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "\(name) scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "\(name): expected 0 failed scenarios")
        return result
    }
}

/// A plain step-failure error whose message surfaces verbatim in the scenario diff.
struct BrineStepError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
