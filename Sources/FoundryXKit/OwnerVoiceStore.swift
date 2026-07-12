// OwnerVoiceStore — the durable OWNER voice sample (ambient-intelligence track
// 20260710T2030 v3, AC2: "part of onboarding is teaching my voice").
//
// Onboarding records a ~20-second read-aloud from the phone mic (the same Opus
// frame shape as capture). The frames are stored WAL-encoded under the captures
// base dir so the sample survives relaunches and — when a desktop brain is
// connected — can be shipped for voiceprint enrollment (WeSpeaker embed → the
// enrolled OWNER print the agent-command owner-check verifies against).
//
// States are honest: `none` (never taught / skipped), `recorded` (sample on
// phone, awaiting desktop enrollment), `enrolled` (desktop confirmed the
// voiceprint). Tier-2 escalation flips recorded→enrolled; this store only owns
// the durable sample + state file.

import Foundation

public enum OwnerVoiceState: Equatable, Sendable {
    /// No usable sample stored (never taught, skipped, or a too-short attempt).
    case none
    /// A sample is stored on the phone, not yet enrolled as a voiceprint.
    case recorded(at: UInt64)
    /// The desktop confirmed enrollment (owner voiceprint exists).
    case enrolled(at: UInt64)
}

public enum OwnerVoiceError: Error, Equatable {
    /// The attempt was too short to make a stable voiceprint (~15s minimum).
    case sampleTooShort(frames: Int, minimum: Int)
}

/// Durable storage for the owner's voice sample. All methods are synchronous
/// file I/O on small data (a 20s Opus sample is ~50-100 KB).
public enum OwnerVoiceStore {
    /// 20ms Opus frames — ~15 seconds minimum for a stable WeSpeaker voiceprint
    /// (the enrollment read-aloud targets ~20s; a moment of speech is rejected).
    public static let minimumFrames = 750

    static func dir(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("owner-voice", isDirectory: true)
    }
    static func sampleURL(baseDir: URL) -> URL {
        dir(baseDir: baseDir).appendingPathComponent("sample.opus")
    }
    static func stateURL(baseDir: URL) -> URL {
        dir(baseDir: baseDir).appendingPathComponent("state.json")
    }

    private struct StateFile: Codable {
        var status: String      // "recorded" | "enrolled"
        var at: UInt64
    }

    /// Persist a recorded sample. Rejects attempts too short for a stable
    /// voiceprint (the UI offers retry/skip). Overwrites any prior sample —
    /// re-teaching replaces, never appends.
    public static func save(frames: [Data], baseDir: URL,
                            now: UInt64 = UInt64(max(0, Date().timeIntervalSince1970))) throws {
        guard frames.count >= minimumFrames else {
            throw OwnerVoiceError.sampleTooShort(frames: frames.count, minimum: minimumFrames)
        }
        try FileManager.default.createDirectory(at: dir(baseDir: baseDir),
                                                withIntermediateDirectories: true)
        try CaptureWAL.encodeSegment(frames).write(to: sampleURL(baseDir: baseDir))
        let state = StateFile(status: "recorded", at: now)
        try JSONEncoder().encode(state).write(to: stateURL(baseDir: baseDir))
    }

    /// Mark the stored sample as enrolled (the desktop confirmed the voiceprint).
    /// No-op if there is no recorded sample.
    public static func markEnrolled(baseDir: URL,
                                    now: UInt64 = UInt64(max(0, Date().timeIntervalSince1970))) {
        guard case .recorded = state(baseDir: baseDir) else { return }
        let state = StateFile(status: "enrolled", at: now)
        try? JSONEncoder().encode(state).write(to: stateURL(baseDir: baseDir))
    }

    /// The stored owner-voice state (drives the onboarding step + Settings row).
    public static func state(baseDir: URL) -> OwnerVoiceState {
        guard let data = try? Data(contentsOf: stateURL(baseDir: baseDir)),
              let file = try? JSONDecoder().decode(StateFile.self, from: data),
              FileManager.default.fileExists(atPath: sampleURL(baseDir: baseDir).path)
        else { return .none }
        switch file.status {
        case "enrolled": return .enrolled(at: file.at)
        case "recorded": return .recorded(at: file.at)
        default: return .none
        }
    }

    /// The stored sample's frames (for the enrollment upload). Empty when none.
    public static func sampleFrames(baseDir: URL) -> [Data] {
        guard let data = try? Data(contentsOf: sampleURL(baseDir: baseDir)) else { return [] }
        return CaptureWAL.decodeSegment(data)
    }
}

// MARK: - First-run gate

/// The pure first-run rule for the onboarding flow (mirrors RootGate's style):
/// present exactly once, only after sign-in, never again once completed/dismissed.
public enum OnboardingGate {
    public static func shouldPresent(signedIn: Bool, completed: Bool) -> Bool {
        signedIn && !completed
    }
}
