import XCTest
import Foundation
@testable import FoundryXKit

/// The chat model-picker warm cache (track 20260715T1501): a fetched `[ModelOption]` is
/// persisted to UserDefaults so the dropdown paints the full grouped menu instantly on the
/// next open, instead of "Auto" only while a ~3s door fetch runs.
final class ModelCacheTests: XCTestCase {

    private func suite() throws -> UserDefaults {
        let name = "foundryx-modelcache-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    /// A cold cache is empty — the no-regression first-launch path (AC2).
    func testColdCacheIsEmpty() throws {
        let d = try suite()
        XCTAssertEqual(ModelCache.load(d), [])
    }

    /// Save then load returns the same list, order preserved (AC1).
    func testRoundTrip() throws {
        let d = try suite()
        let models = [
            ModelOption(id: "pi:local", label: "On-device"),
            ModelOption(id: "claude-opus", label: "Opus 4.8"),
            ModelOption(id: "gpt-5", label: "GPT-5"),
        ]
        ModelCache.save(models, d)
        XCTAssertEqual(ModelCache.load(d), models)
    }

    /// A later save replaces the cached list (AC3 — background refresh with a changed list).
    func testSaveReplaces() throws {
        let d = try suite()
        ModelCache.save([ModelOption(id: "a", label: "A")], d)
        let next = [ModelOption(id: "b", label: "B"), ModelOption(id: "c", label: "C")]
        ModelCache.save(next, d)
        XCTAssertEqual(ModelCache.load(d), next)
    }
}
