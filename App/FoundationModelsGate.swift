// FoundationModelsGate — the REAL on-device gate behind the AmbientGate seam
// (ambient-intelligence track 20260710T2030 v3, Tier 1). Same pattern as
// FoundationModelsTitler: Apple Foundation Models where available, availability-
// gated, no fallback — a phone without Apple-Intelligence hardware simply has no
// Tier-1 gate (the lane logs `gate_unavailable` skips; the door-chunk fallback is
// the substrate for those devices, later).
//
// The prompt is ported from omi's proven mentor gate (proactive_notification.py):
// the DEFAULT ANSWER IS NO — interrupt only for a SPECIFIC actionable moment. Ours
// is scoped tighter than omi's (v0 has no facts/goals context): it looks only for
// explicit action moments in the window — a lookup ("I'll have to look that up"),
// a to-do commitment, or a request addressed to the user's named agent.
//
// Lives in the App target (not FoundryXKit/SPM) so tests drive the AmbientGate
// seam with a fake; this class only ever runs on-device.

import Foundation
// NOTE: no `import FoundryXKit` — the app target compiles Sources/FoundryXKit
// directly, so AmbientGate/AmbientCandidate are same-module types here.
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
public final class FoundationModelsGate: AmbientGate, @unchecked Sendable {
    /// The user's agent name (Settings), or nil when unset. A window addressing
    /// the name is a high-confidence marker — checked cheaply BEFORE the model
    /// runs so a mention is never lost to model flakiness.
    private let agentName: @Sendable () -> String?

    public init(agentName: @escaping @Sendable () -> String? = { nil }) {
        self.agentName = agentName
    }

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func evaluate(window: String) async throws -> AmbientCandidate? {
        let bounded = String(window.suffix(1_500))

        // Cheap pre-marker: the agent's name in the window biases hard toward a
        // candidate (the router still owner-checks + confirms before anything runs).
        let named = agentName().flatMap { name -> String? in
            guard !name.isEmpty,
                  bounded.range(of: name, options: .caseInsensitive) != nil else { return nil }
            return name
        }

        let session = LanguageModelSession()
        let prompt = """
        You watch a live conversation transcript for ACTIONABLE MOMENTS. Most windows \
        have none — your default answer is NO.

        Answer YES only when you can point to a SPECIFIC sentence where:
        - someone says they need to look something up / can't remember / will have to check
        - someone commits to a concrete task ("I'll send you the doc Friday")
        \(named.map { "- someone addresses \"\($0)\" (the user's assistant) with a request" } ?? "")

        Do NOT answer YES for: general chat, topics merely related to work, vague \
        intentions, or anything requiring a stretch.

        Reply in EXACTLY this format and nothing else:
        NO
        or:
        YES
        utterance: <the specific sentence, verbatim>
        summary: <what could be done about it, one short clause>
        confidence: <0.0-1.0>

        Transcript window:
        \(bounded)
        """
        let reply = try await session.respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard reply.uppercased() != "NO", !reply.isEmpty else { return nil }
        var utterance = "", summary = "", confidence = 0.0
        for line in reply.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let v = l.lowercased().hasPrefix("utterance:") ? l.dropFirst(10) : nil {
                utterance = v.trimmingCharacters(in: .whitespaces)
            } else if let v = l.lowercased().hasPrefix("summary:") ? l.dropFirst(8) : nil {
                summary = v.trimmingCharacters(in: .whitespaces)
            } else if let v = l.lowercased().hasPrefix("confidence:") ? l.dropFirst(11) : nil {
                confidence = Double(v.trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        // A YES without a citable utterance is a malformed gate reply — treat as NO
        // (default-no beats a vague interrupt).
        guard !utterance.isEmpty else { return nil }
        // An agent-name window is high-confidence by construction.
        if named != nil { confidence = max(confidence, 0.9) }
        guard confidence >= 0.6 else { return nil }
        return AmbientCandidate(utterance: utterance, summary: summary, confidence: confidence)
    }
}
#endif

/// Wiring-time factory: the system gate where the OS has Foundation Models, else
/// nil — the lane then logs honest `gate_unavailable` skips (no fake gate, ever).
public func makeSystemGate(agentName: @escaping @Sendable () -> String? = { nil }) -> AmbientGate? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
        return FoundationModelsGate(agentName: agentName)
    }
    #endif
    return nil
}
