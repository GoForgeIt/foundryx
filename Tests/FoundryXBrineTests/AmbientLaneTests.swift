import XCTest
import Foundation
import FoundryXKit

/// Ambient-intelligence Tier-1 lane (track 20260710T2030 v3, features/
/// ambient-intelligence.feature): OPT-IN default-NO gate over the rolling LIVE
/// transcript window, every decision logged. Off = OFF — zero processing. The gate
/// is faked (Foundation Models is the real engine on-device, not runnable in CI);
/// the transcript is fed as text (the manager passes the live SpeechAnalyzer
/// transcript at runtime).
final class AmbientLaneTests: XCTestCase {

    final class FakeGate: AmbientGate, @unchecked Sendable {
        var available = true
        var calls = 0
        var windows: [String] = []
        /// Surface a candidate when the window contains `triggerPhrase`.
        var triggerPhrase: String?
        var shouldThrow = false
        var isAvailable: Bool { available }
        func evaluate(window: String) async throws -> AmbientCandidate? {
            calls += 1
            windows.append(window)
            if shouldThrow { throw NSError(domain: "gate", code: 1) }
            if let phrase = triggerPhrase, window.contains(phrase) {
                return AmbientCandidate(utterance: phrase, summary: "look it up", confidence: 0.9)
            }
            return nil   // the default answer is NO
        }
    }

    private func logURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambient-\(UUID().uuidString).jsonl")
    }

    // Scenario: disabled means zero ambient processing
    func testDisabledMeansZeroProcessing() async throws {
        let gate = FakeGate()
        let url = logURL()
        let lane = AmbientLane(gate: gate, isEnabled: { false }, decisionLogURL: url)

        let candidate = await lane.consider(captureId: "cap-off", window: "I'll look that up later")

        XCTAssertNil(candidate)
        XCTAssertEqual(gate.calls, 0, "no gate evaluation occurs")
        let decisions = await lane.decisions()
        XCTAssertTrue(decisions.isEmpty, "no ambient decision is recorded")
    }

    // Scenario: while enabled, a window is gated and the decision recorded
    func testEnabledGatesWindowAndRecords() async throws {
        let gate = FakeGate()
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())

        _ = await lane.consider(captureId: "cap-on", window: "so how was the weekend")
        XCTAssertEqual(gate.calls, 1, "the gate evaluates the window")
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.outcome, .gatedNo)
    }

    // An unchanged window (silence: transcript stopped growing) is skipped for free.
    func testUnchangedWindowIsSkippedSilently() async throws {
        let gate = FakeGate()
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())

        _ = await lane.consider(captureId: "c", window: "same words")
        _ = await lane.consider(captureId: "c", window: "same words")   // no new speech
        _ = await lane.consider(captureId: "c", window: "same words new words")  // grew

        XCTAssertEqual(gate.calls, 2, "the identical window is not re-gated")
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.count, 2)
    }

    // Scenario: an ordinary conversation produces no candidates
    func testOrdinaryConversationIsAllGatedNo() async throws {
        let gate = FakeGate()   // no trigger phrase — never a candidate
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())

        for w in ["so how was the weekend", "pretty good we hiked up to the lake",
                  "nice, any wildlife", "just some marmots honestly"] {
            let c = await lane.consider(captureId: "cap-ordinary", window: w)
            XCTAssertNil(c, "no candidate is surfaced")
        }
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.count, 4)
        XCTAssertTrue(decisions.allSatisfy { $0.outcome == .gatedNo }, "every window gated NO")
    }

    // Scenario: an actionable moment becomes a candidate
    func testActionableMomentSurfacesACandidate() async throws {
        let gate = FakeGate(); gate.triggerPhrase = "look up what we decided"
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())

        let candidate = await lane.consider(
            captureId: "cap-act",
            window: "I'll have to look up what we decided about the relay")

        XCTAssertNotNil(candidate, "the gate surfaces a candidate")
        XCTAssertEqual(candidate?.confidence, 0.9)
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.last?.outcome, .candidate)
        XCTAssertEqual(decisions.last?.candidate?.confidence, 0.9,
                       "the candidate is recorded with its confidence")
    }

    // Scenario: a failing/unavailable gate skips silently
    func testUnavailableGateSkipsAndRecordsReason() async throws {
        let gate = FakeGate(); gate.available = false
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())

        let candidate = await lane.consider(captureId: "cap-skip", window: "anything at all")

        XCTAssertNil(candidate)
        XCTAssertEqual(gate.calls, 0)
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.last?.outcome, .skipped)
        XCTAssertEqual(decisions.last?.skipReason, "gate_unavailable")
    }

    func testThrowingGateSkipsWithErrorReason() async throws {
        let gate = FakeGate(); gate.shouldThrow = true
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())
        _ = await lane.consider(captureId: "c", window: "boom")
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.last?.outcome, .skipped)
        XCTAssertEqual(decisions.last?.skipReason, "gate_error")
    }

    // Empty / whitespace-only windows never gate.
    func testEmptyWindowIsInert() async throws {
        let gate = FakeGate()
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: logURL())
        _ = await lane.consider(captureId: "c", window: "   \n  ")
        XCTAssertEqual(gate.calls, 0)
        let decisions = await lane.decisions()
        XCTAssertTrue(decisions.isEmpty)
    }
}
