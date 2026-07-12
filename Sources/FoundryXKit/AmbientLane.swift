// AmbientLane — Tier 1 of the ambient-intelligence ladder (track 20260710T2030 v3).
// While a capture is ACTIVE and the user has OPTED IN, an on-device transcript
// accrues (the same LocalSTT seam / WhisperKit engine the local brain uses) and an
// on-device GATE — whose default answer is NO — watches rolling windows for
// actionable moments ("I'll have to look that up", a request addressed to the named
// agent). ~99% of windows die here, privately: nothing leaves the phone until a
// candidate escalates (Tier 2, desktop).
//
// OFF (the default) means OFF: `tick` returns before touching audio — no transcript,
// no gate, no decision entry; capture behaves as if this file didn't exist.
//
// Everything is seam-driven (LocalSTT + AmbientGate protocols) so the lane tests
// hermetically with fakes; the real engines are WhisperKit + Apple Foundation
// Models, wired in the App target. Every evaluation appends one AmbientDecision to
// a JSONL decision log — the substrate for the Temper scorer and the router council
// (dismissed cards = labeled false positives).

import Foundation

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
        /// Engine unavailable/busy/failed — window skipped, silently.
        case skipped
    }

    public let ts: UInt64
    public let captureId: String
    /// Size of the evaluated window (chars) — cheap context without storing content.
    public let windowChars: Int
    public let outcome: Outcome
    /// Present when `outcome == .candidate`.
    public let candidate: AmbientCandidate?
    /// Why a skip happened (`stt_unavailable`, `gate_unavailable`, `stt_error`,
    /// `gate_error`) — nil otherwise.
    public let skipReason: String?
    public let latencyMs: UInt64
}

// MARK: - The lane

/// Per-capture Tier-1 lane. Drive `tick(captureId:)` on a cadence (~60s) while a
/// capture is active; it transcribes ONLY the frames that arrived since the last
/// tick, grows the rolling transcript, gates the newest window, and logs the
/// decision. Returns the candidate (if any) for the caller to escalate.
public actor AmbientLane {
    /// Master opt-in, read per tick so a Settings flip applies immediately.
    /// DEFAULT OFF lives at the call site (the App's settings store) — the lane
    /// never assumes.
    private let isEnabled: @Sendable () -> Bool
    private let stt: LocalSTT
    private let gate: AmbientGate
    private let baseDir: URL
    /// Where decision JSONL lines land (`ambient-decisions.jsonl` under baseDir
    /// unless overridden for tests).
    private let decisionLogURL: URL

    /// Frames already transcribed, per capture — the incremental cursor.
    private var consumedFrames: [String: Int] = [:]
    /// The rolling transcript, per capture (in-memory, ephemeral — dropped with the
    /// lane; the authoritative transcript still comes from the normal pipeline).
    private var rolling: [String: String] = [:]

    /// The gate reads at most this much of the rolling tail — enough context to
    /// understand "that" in "I'll look that up" without re-reading the hour.
    private let windowChars = 1_500
    /// Don't bother transcribing a tick with fewer new frames than this (~2s of
    /// 20ms packets) — avoids burning STT on near-empty ticks.
    private let minNewFrames = 100

    public init(
        baseDir: URL,
        stt: LocalSTT,
        gate: AmbientGate,
        isEnabled: @escaping @Sendable () -> Bool,
        decisionLogURL: URL? = nil
    ) {
        self.baseDir = baseDir
        self.stt = stt
        self.gate = gate
        self.isEnabled = isEnabled
        self.decisionLogURL = decisionLogURL
            ?? baseDir.appendingPathComponent("ambient-decisions.jsonl")
    }

    /// The rolling transcript so far (tests + debug readout).
    public func transcript(captureId: String) -> String { rolling[captureId] ?? "" }

    /// One cadence tick. OFF ⇒ returns immediately — no audio touched, no log line
    /// (AC1: disabled means zero ambient processing).
    @discardableResult
    public func tick(captureId: String) async -> AmbientCandidate? {
        guard isEnabled() else { return nil }
        let started = DispatchTime.now()

        // New frames since the last tick (frame-count cursor over the WAL).
        let all = LocalBackend.loadFrames(captureId: captureId, baseDir: baseDir)
        let consumed = consumedFrames[captureId] ?? 0
        let fresh = all.count > consumed ? Array(all[consumed...]) : []
        guard fresh.count >= minNewFrames else { return nil }

        guard stt.isAvailable else {
            log(captureId: captureId, outcome: .skipped, windowChars: 0,
                candidate: nil, skipReason: "stt_unavailable", started: started)
            return nil
        }
        let chunk: String
        do {
            chunk = try await stt.transcribe(opusFrames: fresh)
        } catch {
            log(captureId: captureId, outcome: .skipped, windowChars: 0,
                candidate: nil, skipReason: "stt_error", started: started)
            return nil
        }
        consumedFrames[captureId] = all.count
        let grown = (rolling[captureId].map { $0 + " " } ?? "") + chunk
        rolling[captureId] = grown

        let window = String(grown.suffix(windowChars))
        guard gate.isAvailable else {
            log(captureId: captureId, outcome: .skipped, windowChars: window.count,
                candidate: nil, skipReason: "gate_unavailable", started: started)
            return nil
        }
        do {
            if let candidate = try await gate.evaluate(window: window) {
                log(captureId: captureId, outcome: .candidate, windowChars: window.count,
                    candidate: candidate, skipReason: nil, started: started)
                return candidate
            }
            log(captureId: captureId, outcome: .gatedNo, windowChars: window.count,
                candidate: nil, skipReason: nil, started: started)
            return nil
        } catch {
            log(captureId: captureId, outcome: .skipped, windowChars: window.count,
                candidate: nil, skipReason: "gate_error", started: started)
            return nil
        }
    }

    /// Drop a finished capture's lane state (rolling buffer is ephemeral by design).
    public func endCapture(captureId: String) {
        consumedFrames[captureId] = nil
        rolling[captureId] = nil
    }

    /// All decisions recorded so far (tests + the debug readout; the scorer reads
    /// the file directly).
    public func decisions() -> [AmbientDecision] {
        guard let data = try? Data(contentsOf: decisionLogURL) else { return [] }
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
