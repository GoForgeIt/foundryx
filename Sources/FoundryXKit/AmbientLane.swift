// AmbientLane — Tier 1 of the ambient-intelligence ladder (track 20260710T2030 v3).
// While a capture is ACTIVE and the user has OPTED IN, an on-device GATE — whose
// default answer is NO — watches the rolling LIVE transcript (the same SpeechAnalyzer
// preview already streaming for the UI; "we're already double recording"). No
// re-transcription: the live transcript IS the STT, so the gate runs near-real-time.
// ~99% of windows die here, privately: nothing leaves the phone until a candidate
// escalates (Tier 2, desktop).
//
// OFF (the default) means OFF: `consider` returns before touching anything — no gate,
// no decision entry; capture behaves as if this file didn't exist.
//
// The gate is a seam (AmbientGate) so the lane tests hermetically; the real engine is
// Apple Foundation Models (App target). Every gate evaluation appends one
// AmbientDecision to a JSONL decision log — the substrate for the Temper scorer and
// the router council (dismissed cards = labeled false positives).

import Foundation

// MARK: - Preferences

/// Ambient-intelligence preference keys (track 20260710T2030 v3). One place so the
/// lane wiring, Settings, and the door client agree. The master switch defaults OFF;
/// full-context grading defaults ON only when this device has an enrolled owner voice.
enum AmbientPrefs {
    static let enabledKey = "foundryx.ambient.enabled"
    static let agentNameKey = "foundryx.ambient.agentName"
    static let gradingKey = "foundryx.ambient.grading"

    /// Honor an explicit user choice. Until one exists, only an enrolled owner voice
    /// opts this device into sending raw context for grading.
    static func fullContextGrading(
        defaults: UserDefaults = .standard,
        ownerVoiceBaseDir: URL = CaptureWAL.documentsCaptures()
    ) -> Bool {
        if defaults.object(forKey: gradingKey) != nil {
            return defaults.bool(forKey: gradingKey)
        }
        if case .enrolled = OwnerVoiceStore.state(baseDir: ownerVoiceBaseDir) {
            return true
        }
        return false
    }

    /// The Tier-1 gate decision log (shared by the lane wiring, the debug readout,
    /// and the Temper scorer). One place so they never disagree.
    static func decisionLogURL() -> URL {
        CaptureWAL.documentsCaptures().appendingPathComponent("ambient-decisions.jsonl")
    }

    /// The redacted-signal shipper's persisted byte-offset watermark (track v3.3) —
    /// beside the logs so it moves with them.
    static func signalWatermarkURL() -> URL {
        CaptureWAL.documentsCaptures().appendingPathComponent(".ambient-signal-shipped")
    }
}

// MARK: - Gate seam

/// An actionable moment the gate surfaced from a transcript window. Tier 2 (the
/// FoundryX router) decides WHAT to do with it; the lane only finds it.
public struct AmbientCandidate: Codable, Equatable, Sendable {
    /// The actionable line, as heard.
    public let utterance: String
    /// One-line gate summary of what could be done.
    public let summary: String
    /// Gate confidence 0…1 (the router + thresholds consume this).
    public let confidence: Double

    public init(utterance: String, summary: String, confidence: Double) {
        self.utterance = utterance
        self.summary = summary
        self.confidence = confidence
    }
}

public struct AmbientPlaybookPick: Codable, Equatable, Sendable {
    public let kind: String
    public let reason: String

    public init(kind: String, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

/// The door's Tier-2 verdict on a candidate: how it routed, and — for lookups —
/// the answer compiled from the user's OWN memory (nil = memory had nothing, or a
/// non-lookup route). Wire shape of `POST /foundryx/ambient/candidate`.
public struct AmbientRouteOutcome: Codable, Equatable, Sendable {
    /// `lookup` | `todo` | `playbook` | `agent` (`workflow` during rollout)
    public let route: String
    public let answer: String?
    /// Agent route only: did the command's VOICE match a confirmed enrolled
    /// speaker (the owner gate)? Absent/false ⇒ never offer the agent card.
    public let ownerVerified: Bool?
    /// Playbook route only: the repeatable playbook the door selected and why.
    public let playbook: AmbientPlaybookPick?

    enum CodingKeys: String, CodingKey {
        case route, answer, playbook
        case ownerVerified = "owner_verified"
    }

    public init(route: String, answer: String? = nil, ownerVerified: Bool? = nil,
                playbook: AmbientPlaybookPick? = nil) {
        self.route = route
        self.answer = answer
        self.ownerVerified = ownerVerified
        self.playbook = playbook
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        route = try values.decode(String.self, forKey: .route)
        answer = try values.decodeIfPresent(String.self, forKey: .answer)
        ownerVerified = try values.decodeIfPresent(Bool.self, forKey: .ownerVerified)
        playbook = try values.decodeIfPresent(AmbientPlaybookPick.self, forKey: .playbook)
    }
}

/// The on-device gate: evaluate a transcript window, answer `nil` (the DEFAULT — not
/// actionable) or a candidate. Real engine: Apple Foundation Models (App target,
/// availability-gated); tests drive fakes.
public protocol AmbientGate: Sendable {
    var isAvailable: Bool { get }
    func evaluate(window: String) async throws -> AmbientCandidate?
}

// MARK: - Decision log

/// One gate decision, one JSONL line — the lane's flight recorder. The Temper
/// scorer + council read these; `outcome` is the vocabulary they key on.
public struct AmbientDecision: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Window evaluated, gate said no (the overwhelmingly common case).
        case gatedNo = "gated_no"
        /// Gate surfaced a candidate (escalates to Tier 2).
        case candidate
        /// Engine unavailable/failed — window skipped, silently.
        case skipped
    }

    public let ts: UInt64
    public let captureId: String
    /// Size of the evaluated window (chars) — cheap context without storing content.
    public let windowChars: Int
    public let outcome: Outcome
    /// Present when `outcome == .candidate`.
    public let candidate: AmbientCandidate?
    /// Why a skip happened (`gate_unavailable`, `gate_error`) — nil otherwise.
    public let skipReason: String?
    public let latencyMs: UInt64
}

// MARK: - The lane

/// Per-capture Tier-1 lane. Drive `consider(captureId:window:)` on a cadence (~10s)
/// with the current rolling LIVE transcript while a capture is active; it gates the
/// window (skipping when unchanged, e.g. during silence) and logs the decision.
/// Returns the candidate (if any) for the caller to escalate + notify.
public actor AmbientLane {
    /// Master opt-in, read per call so a Settings flip applies immediately.
    /// DEFAULT OFF lives at the call site (the App's settings store).
    private let isEnabled: @Sendable () -> Bool
    private let gate: AmbientGate
    /// Where decision JSONL lines land (`ambient-decisions.jsonl`).
    public let decisionLogURL: URL

    /// The last window we actually gated, per capture — so an unchanged window
    /// (silence: the live transcript stopped growing) is skipped for free, no gate
    /// call, no log line.
    private var lastGated: [String: String] = [:]
    /// The gate reads at most this much of the window tail — enough context to
    /// understand "that" in "I'll look that up" without re-reading the hour.
    private let maxWindowChars = 1_500

    public init(
        gate: AmbientGate,
        isEnabled: @escaping @Sendable () -> Bool,
        decisionLogURL: URL
    ) {
        self.gate = gate
        self.isEnabled = isEnabled
        self.decisionLogURL = decisionLogURL
    }

    /// Gate the current rolling transcript window. OFF ⇒ returns immediately — no
    /// gate, no log line (AC1: disabled means zero ambient processing). An unchanged
    /// window (no new speech since the last gate) ⇒ skipped silently, no log.
    @discardableResult
    public func consider(captureId: String, window: String) async -> AmbientCandidate? {
        guard isEnabled() else { return nil }
        let trimmed = String(window.trimmingCharacters(in: .whitespacesAndNewlines)
            .suffix(maxWindowChars))
        guard !trimmed.isEmpty, lastGated[captureId] != trimmed else { return nil }
        lastGated[captureId] = trimmed
        let started = DispatchTime.now()

        guard gate.isAvailable else {
            log(captureId: captureId, outcome: .skipped, windowChars: trimmed.count,
                candidate: nil, skipReason: "gate_unavailable", started: started)
            return nil
        }
        do {
            if let candidate = try await gate.evaluate(window: trimmed) {
                log(captureId: captureId, outcome: .candidate, windowChars: trimmed.count,
                    candidate: candidate, skipReason: nil, started: started)
                return candidate
            }
            log(captureId: captureId, outcome: .gatedNo, windowChars: trimmed.count,
                candidate: nil, skipReason: nil, started: started)
            return nil
        } catch {
            log(captureId: captureId, outcome: .skipped, windowChars: trimmed.count,
                candidate: nil, skipReason: "gate_error", started: started)
            return nil
        }
    }

    /// Drop a finished capture's lane state.
    public func endCapture(captureId: String) {
        lastGated[captureId] = nil
    }

    /// All decisions recorded so far (tests + the debug readout; the scorer reads
    /// the file directly). Newest last.
    public func decisions() -> [AmbientDecision] {
        Self.readDecisions(at: decisionLogURL)
    }

    /// Read the decision log without a lane instance (the Settings debug readout).
    public static func readDecisions(at url: URL) -> [AmbientDecision] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? dec.decode(AmbientDecision.self, from: Data($0))
        }
    }

    private func log(
        captureId: String, outcome: AmbientDecision.Outcome, windowChars: Int,
        candidate: AmbientCandidate?, skipReason: String?, started: DispatchTime
    ) {
        let latencyMs = UInt64(
            (DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000)
        let decision = AmbientDecision(
            ts: UInt64(max(0, Date().timeIntervalSince1970)),
            captureId: captureId, windowChars: windowChars, outcome: outcome,
            candidate: candidate, skipReason: skipReason, latencyMs: latencyMs)
        guard var line = try? JSONEncoder().encode(decision) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: decisionLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: decisionLogURL)
        }
    }
}
