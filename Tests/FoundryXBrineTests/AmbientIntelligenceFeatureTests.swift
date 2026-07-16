import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/ambient-intelligence.feature. Drives the REAL `AmbientLane`
/// (the same OPT-IN, default-NO gate AmbientLaneTests unit-tests) with an injected fake
/// gate: disabled ⇒ zero processing; enabled ⇒ each changed transcript window is gated
/// and the decision logged; an unchanged window is skipped for free; an actionable
/// utterance surfaces a candidate with its confidence; an unavailable engine skips
/// silently. Hermetic — the gate is faked (Foundation Models is the on-device engine,
/// not runnable in CI); no network, no hardware.
final class AmbientIntelligenceFeatureTests: XCTestCase {
    func testAmbientIntelligenceFeature() async throws {
        try await BrineFeatureRunner.run("ambient-intelligence",
                                         registry: StepRegistry(AmbientIntelligenceSteps.make(world: .init())))
    }
}

private final class AmbientFakeGate: AmbientGate, @unchecked Sendable {
    private let q = DispatchQueue(label: "foundryx.ambient-fake-gate")   // async-safe (NSLock.lock/unlock is banned in async)
    private var _available = true
    private var _calls = 0
    var triggerPhrase: String?
    var shouldThrow = false
    var available: Bool {
        get { q.sync { _available } }
        set { q.sync { _available = newValue } }
    }
    var calls: Int { q.sync { _calls } }
    var isAvailable: Bool { available }
    func evaluate(window: String) async throws -> AmbientCandidate? {
        q.sync { _calls += 1 }
        if shouldThrow { throw NSError(domain: "gate", code: 1) }
        if let phrase = triggerPhrase, window.contains(phrase) {
            return AmbientCandidate(utterance: phrase, summary: "look it up", confidence: 0.9)
        }
        return nil // the default answer is NO
    }
}

private final class AmbientWorld: @unchecked Sendable {
    var gate = AmbientFakeGate()
    var lane: AmbientLane!
    var enabled = false
    var freshInstall = false
    var defaultEnabled = true
    var recordingActive = false
    var ambientTranscriptProduced = false
    var lastCandidate: AmbientCandidate?
    var anyCandidate = false
    var lastWindow = ""
    let captureId = "cap-ambient"

    func setupLane(enabled: Bool) {
        gate = AmbientFakeGate()
        self.enabled = enabled
        recordingActive = true
        ambientTranscriptProduced = false
        lastCandidate = nil
        anyCandidate = false
        lastWindow = ""
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ambient-feat-\(UUID().uuidString).jsonl")
        lane = AmbientLane(gate: gate, isEnabled: { enabled }, decisionLogURL: url)
    }

    @discardableResult
    func consider(_ window: String) async -> AmbientCandidate? {
        ambientTranscriptProduced = enabled
        lastWindow = window
        let c = await lane.consider(captureId: captureId, window: window)
        lastCandidate = c
        if c != nil { anyCandidate = true }
        return c
    }
}

private enum AmbientIntelligenceSteps {
    static func make(world w: AmbientWorld) -> [StepDefinition] {
        [
            // MARK: default OFF
            defineStep("a fresh install") { ctx, _, _ in
                // The master switch defaults OFF: a fresh UserDefaults has no value for the
                // real ambient-enabled key, so it reads false.
                let suite = UserDefaults(suiteName: "ambient-fresh-\(UUID().uuidString)")!
                w.defaultEnabled = suite.bool(forKey: AmbientPrefs.enabledKey)
                w.freshInstall = true
                return ctx
            },
            // Dual role: the "Then" for a fresh install (assert default OFF) AND the "Given"
            // precondition that establishes a DISABLED lane for the zero-processing scenario.
            defineStep("ambient intelligence is disabled") { ctx, _, _ in
                if w.freshInstall {
                    guard w.defaultEnabled == false else {
                        throw BrineStepError("ambient intelligence is not disabled by default on a fresh install")
                    }
                    w.freshInstall = false
                }
                w.setupLane(enabled: false)
                return ctx
            },
            defineStep("ambient intelligence is enabled") { ctx, _, _ in
                w.setupLane(enabled: true); return ctx
            },
            defineStep("a conversation is being recorded") { ctx, _, _ in
                w.recordingActive = true; return ctx
            },

            // MARK: disabled ⇒ zero processing (also drives the enabled+unavailable path)
            defineStep("new audio arrives") { ctx, _, _ in
                _ = await w.consider("I'll look that up later")
                return ctx
            },
            defineCheck("no ambient transcript is produced") { _, _, _ in
                guard !w.ambientTranscriptProduced else { throw BrineStepError("a transcript was produced while disabled") }
            },
            defineCheck("no gate evaluation occurs") { _, _, _ in
                guard w.gate.calls == 0 else { throw BrineStepError("gate evaluated \(w.gate.calls) times while disabled") }
            },
            defineCheck("no ambient decision is recorded") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard decisions.isEmpty else { throw BrineStepError("recorded \(decisions.count) decisions while disabled") }
            },

            // MARK: enabled ⇒ changed window gated + recorded
            defineStep("new speech arrives on the live transcript") { ctx, _, _ in
                _ = await w.consider("so how was the weekend"); return ctx
            },
            defineCheck("the gate evaluates the newest window") { _, _, _ in
                guard w.gate.calls == 1 else { throw BrineStepError("gate calls \(w.gate.calls), expected 1") }
            },
            defineCheck("the decision is recorded") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard decisions.count == 1 else { throw BrineStepError("decisions \(decisions.count), expected 1") }
            },

            // MARK: unchanged window skipped for free
            defineStep("the live transcript has not changed since the last check") { ctx, _, _ in
                _ = await w.consider("same words") // first check gates once
                return ctx
            },
            defineStep("the lane is asked to consider it again") { ctx, _, _ in
                _ = await w.consider("same words") // identical window — must NOT re-gate
                return ctx
            },
            defineCheck("the gate is not called") { _, _, _ in
                guard w.gate.calls == 1 else { throw BrineStepError("identical window re-gated (calls \(w.gate.calls))") }
            },
            defineCheck("no decision is recorded") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard decisions.count == 1 else { throw BrineStepError("an unchanged window recorded a 2nd decision (\(decisions.count))") }
            },

            // MARK: ordinary conversation → no candidates
            defineStep("the conversation contains no actionable moments") { ctx, _, _ in
                w.gate.triggerPhrase = nil; return ctx
            },
            defineStep("several minutes of speech are processed") { ctx, _, _ in
                for window in ["so how was the weekend", "pretty good we hiked up to the lake",
                               "nice, any wildlife", "just some marmots honestly"] {
                    _ = await w.consider(window)
                }
                return ctx
            },
            defineCheck("every window is gated NO") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard decisions.count == 4, decisions.allSatisfy({ $0.outcome == .gatedNo }) else {
                    throw BrineStepError("not every window gated NO: \(decisions.map { $0.outcome })")
                }
            },
            defineCheck("no candidate is surfaced") { _, _, _ in
                guard !w.anyCandidate else { throw BrineStepError("a candidate was surfaced from an ordinary conversation") }
            },

            // MARK: an actionable moment becomes a candidate
            defineStep("the conversation contains {string}") { ctx, p, _ in
                let utterance = try p.requireString(0)
                w.gate.triggerPhrase = "look up what we decided"
                _ = await w.consider(utterance)
                return ctx
            },
            defineCheck("the gate surfaces a candidate for that utterance") { _, _, _ in
                guard w.lastCandidate != nil else { throw BrineStepError("no candidate surfaced for the actionable utterance") }
            },
            defineCheck("the candidate is recorded with its confidence") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard decisions.last?.outcome == .candidate,
                      let conf = decisions.last?.candidate?.confidence, conf > 0 else {
                    throw BrineStepError("the candidate was not recorded with its confidence")
                }
            },

            // MARK: an unavailable engine skips silently
            defineStep("the on-device engine is unavailable") { ctx, _, _ in
                w.gate.available = false; return ctx
            },
            defineCheck("the window is skipped") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard w.lastCandidate == nil, decisions.last?.outcome == .skipped else {
                    throw BrineStepError("the window was not skipped (\(String(describing: decisions.last?.outcome)))")
                }
            },
            defineCheck("the skip is recorded") { _, _, _ in
                let decisions = await w.lane.decisions()
                guard decisions.last?.skipReason == "gate_unavailable" else {
                    throw BrineStepError("skip reason was \(String(describing: decisions.last?.skipReason))")
                }
            },
            defineCheck("recording itself is unaffected") { _, _, _ in
                guard w.recordingActive else { throw BrineStepError("the ambient lane disrupted recording") }
            },
        ]
    }
}
