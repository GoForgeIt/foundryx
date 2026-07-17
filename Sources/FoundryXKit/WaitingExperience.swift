// WaitingExperience — the ONE honest-wait presentation model (perf track WS-C).
//
// The app is on-device first, so most user-visible waits are irreducible on-device
// model runs or a network hop to the user's own Mac. Rather than lie with a fake
// progress bar or a bare spinner, every wait longer than ~1s renders the SAME
// component, driven by this model, which does three things:
//
//   1. NAMES what's happening in plain, honest language, TRUE to the mechanism
//      (on-device Apple Foundation Models for recap/title, on-device Whisper for
//      transcription, an end-to-end-encrypted relay hop to the user's Mac for door
//      fetches, and a durable segment upload for sync/backfill).
//   2. Shows REAL progress ONLY where it is measurable — the sync/backfill drain,
//      where `syncedSegments / totalSegments` is a genuine determinate fraction.
//      The model waits (recap/title/transcription/door) get NO fake bar; they get
//      elapsed-aware phase text instead ("still working — longer recordings take
//      longer").
//   3. Rotates a small deck of genuinely-true, useful facts about what FoundryX is
//      doing locally with the user's data (privacy-forward, plus real library stats
//      when cheaply available) — deterministic + injectable, so it is unit-tested.
//
// This is the pure, view-agnostic layer (lives in FoundryXKit so Brine + unit tests
// drive it with no UIKit). `WaitingExperienceView` (App target) binds a TimelineView
// to it — no timers, so tip rotation cannot leak.

import Foundation

// MARK: - Wait kind

/// The distinct user-visible waits the app has that last long enough (>1s) to warrant
/// a named waiting experience. Each maps to a real, measured mechanism.
public enum WaitKind: String, Sendable, CaseIterable, Equatable {
    /// On-device LLM recap of a day/week of conversations (Apple Foundation Models).
    case recap
    /// On-device foundation-model titling of a conversation (or the Mac's model, whose
    /// title arrives asynchronously) — the "Untitled" placeholder wait.
    case title
    /// On-device speech-to-text of a capture (Whisper), the slowest local wait.
    case transcription
    /// Fetching a conversation's content from the user's Mac over the encrypted relay.
    case doorFetch
    /// Draining the phone-side write-ahead log up to the user's Mac (segment backfill).
    case sync
}

// MARK: - Progress

/// Whether a wait has an HONEST determinate fraction. Only `sync` ever does; the
/// on-device model waits and the network fetch do not, so they never show a fake bar.
public enum WaitProgress: Equatable, Sendable {
    case indeterminate
    /// A real count of finished / total units (sync segments). `total` may briefly be
    /// 0 (nothing measured yet) — the fraction then reads as indeterminate.
    case determinate(done: Int, total: Int)

    /// 0...1 when there is a real, positive total; nil otherwise (⇒ treat as indeterminate).
    public var fraction: Double? {
        guard case let .determinate(done, total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    public var isDeterminate: Bool { fraction != nil }
}

// MARK: - Copy (headline + one privacy-forward line)

/// The named, honest copy for a wait. `headline` names the action in plain language;
/// `privacyLine` is the single true, privacy-forward line under it.
public struct WaitCopy: Equatable, Sendable {
    public let headline: String
    public let privacyLine: String

    public init(headline: String, privacyLine: String) {
        self.headline = headline
        self.privacyLine = privacyLine
    }

    /// The copy for a wait kind. `onDevice` picks the honest destination for the two
    /// waits whose mechanism differs by tier: titling and sync happen on the phone in
    /// the phone-only tier, and on the user's Mac in the computer tier.
    public static func make(for kind: WaitKind, onDevice: Bool) -> WaitCopy {
        switch kind {
        case .recap:
            return WaitCopy(
                headline: "Summarizing on your iPhone",
                privacyLine: "The recap is written by a model running entirely on your device — no conversation text is sent anywhere to summarize it.")
        case .title:
            return WaitCopy(
                headline: "Naming this conversation",
                privacyLine: onDevice
                    ? "A model on your iPhone is reading the transcript to write its title and summary."
                    : "A model on your Mac is reading the transcript to write its title and summary.")
        case .transcription:
            return WaitCopy(
                headline: "Transcribing locally",
                privacyLine: onDevice
                    ? "Speech-to-text runs on your iPhone — the audio never leaves your phone."
                    : "Speech-to-text runs on your own Mac — the audio never goes to a server we run.")
        case .doorFetch:
            return WaitCopy(
                headline: "Fetching from your Mac",
                privacyLine: "Coming over the end-to-end-encrypted tunnel to your computer — even the relay can't read it.")
        case .sync:
            return WaitCopy(
                headline: onDevice ? "Catching up" : "Copying to your computer",
                privacyLine: onDevice
                    ? "Each segment is written to your phone's disk before anything else — nothing is ever lost."
                    : "Each segment is written to your phone's disk first, then copied to your Mac — the phone keeps its own copy too.")
        }
    }
}

// MARK: - Elapsed-aware phase text

/// Elapsed-aware "still working" phrasing for the INDETERMINATE waits — the honest
/// alternative to a fake progress bar. Thresholds are tuned to each wait's measured
/// real-device profile (b230): recap ~7s avg / 12s max, title ~6.5s avg / 15s max /
/// 20s timeout, transcription ~17s avg / 83s max, door ~0.7s avg / 3.2s max. Returns
/// nil before the first threshold (the base copy stands).
public enum WaitPhaseText {
    /// Ordered (after-seconds, phrase) ladders. Pick the LAST rung whose threshold is
    /// ≤ elapsed. `sync` is determinate and has no ladder here.
    static func ladder(for kind: WaitKind) -> [(after: TimeInterval, text: String)] {
        switch kind {
        case .recap:
            return [
                (8, "Still summarizing — almost there."),
            ]
        case .title:
            return [
                (10, "Still working on the title…"),
            ]
        case .transcription:
            return [
                (20, "Still transcribing — longer recordings take longer."),
                (45, "Nearly there — this was a long one."),
            ]
        case .doorFetch:
            return [
                (3, "Still reaching your Mac — the tunnel may be waking up."),
            ]
        case .sync:
            return []
        }
    }

    /// The phase phrase to show after `elapsed` seconds, or nil to keep the base copy.
    public static func phrase(for kind: WaitKind, elapsed: TimeInterval) -> String? {
        var chosen: String?
        for rung in ladder(for: kind) where elapsed >= rung.after {
            chosen = rung.text
        }
        return chosen
    }
}

// MARK: - Determinate progress label

public enum WaitProgressLabel {
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func grouped(_ n: Int) -> String {
        grouping.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// "214 of 1,210 segments safely on your computer" — the honest sync count. `nil`
    /// for indeterminate progress (no fake number). `onDevice` phrases the destination.
    public static func syncLabel(_ progress: WaitProgress, onDevice: Bool) -> String? {
        guard case let .determinate(done, total) = progress, total > 0 else { return nil }
        let clampedDone = min(done, total)
        let where_ = onDevice ? "saved on your phone" : "safely on your computer"
        let unit = total == 1 ? "segment" : "segments"
        return "\(grouped(clampedDone)) of \(grouped(total)) \(unit) \(where_)"
    }
}

// MARK: - Tips (the one entertainment primitive)

/// One rotating fact. Every tip must be TRUE of how FoundryX actually works; the deck
/// mixes evergreen privacy-forward facts with real library stats when they're cheap.
public struct WaitingTip: Equatable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// Cheap, already-in-memory library counts the deck can turn into a true stat tip.
/// All optional — a nil count simply drops that tip (never a fabricated number).
public struct WaitingLibraryStats: Equatable, Sendable {
    public let conversationCount: Int?
    public let segmentsOnComputer: Int?

    public init(conversationCount: Int? = nil, segmentsOnComputer: Int? = nil) {
        self.conversationCount = conversationCount
        self.segmentsOnComputer = segmentsOnComputer
    }

    public static let none = WaitingLibraryStats()
}

/// A deterministic deck of tips for a wait: kind-relevant facts first, then evergreen
/// privacy facts, then any available stat tips. Deterministic order ⇒ `tip(at:)` is a
/// pure function of a rotation index, so rotation is fully testable + injectable.
public struct WaitingTipDeck: Equatable, Sendable {
    public let tips: [WaitingTip]

    public init(tips: [WaitingTip]) {
        // Never empty — fall back to a single evergreen fact so `tip(at:)` is total.
        self.tips = tips.isEmpty ? [WaitingTip(Self.evergreen[0])] : tips
    }

    public init(kind: WaitKind, onDevice: Bool, stats: WaitingLibraryStats = .none) {
        var out: [String] = []
        out.append(contentsOf: Self.kindFacts(kind, onDevice: onDevice))
        out.append(contentsOf: Self.evergreen)
        out.append(contentsOf: Self.statFacts(stats, onDevice: onDevice))
        // De-dupe while preserving order (a kind fact may repeat an evergreen one).
        var seen = Set<String>()
        let deduped = out.filter { seen.insert($0).inserted }
        self.init(tips: deduped.map(WaitingTip.init))
    }

    public var count: Int { tips.count }

    /// The tip at a rotation index, wrapping — safe for any Int (incl. negative).
    public func tip(at index: Int) -> WaitingTip {
        let n = tips.count
        let i = ((index % n) + n) % n
        return tips[i]
    }

    // Evergreen, always-true facts about the app's actual mechanism.
    static let evergreen: [String] = [
        "Every segment is written to your phone's disk before it's sent — a dropped connection never loses a word.",
        "Your transcripts are stored as plain text on your phone, ready to search in an instant.",
        "Your phone keeps its own copy of every recording, even after it's backed up to your Mac.",
        "The link to your Mac is end-to-end encrypted — even the relay that carries it can't read a thing.",
        "Titles, summaries, and recaps are written by a model on your device, not in anyone's cloud.",
    ]

    static func kindFacts(_ kind: WaitKind, onDevice: Bool) -> [String] {
        switch kind {
        case .recap:
            return ["This recap is drawn only from your own conversations — the model is told never to invent details."]
        case .title:
            return ["The title comes from the transcript itself — no conversation content is uploaded to name it."]
        case .transcription:
            return onDevice
                ? ["On-device transcription turns even a private conversation into text without it ever leaving your phone."]
                : ["Transcription happens on your own Mac — your audio is never sent to our servers to be read."]
        case .doorFetch:
            return ["Your conversations live on your Mac, not our servers — this is your own computer answering."]
        case .sync:
            return onDevice
                ? ["Backing up locally keeps everything on devices you own — nothing is uploaded to us."]
                : ["Once a segment reaches your Mac it can't be lost — and your phone still keeps its copy."]
        }
    }

    static func statFacts(_ stats: WaitingLibraryStats, onDevice: Bool) -> [String] {
        var out: [String] = []
        if let c = stats.conversationCount, c > 0 {
            let unit = c == 1 ? "conversation" : "conversations"
            out.append("You've captured \(WaitProgressLabel.grouped(c)) \(unit) so far — kept on your own devices.")
        }
        if let s = stats.segmentsOnComputer, s > 0 {
            let unit = s == 1 ? "segment" : "segments"
            let where_ = onDevice ? "kept safe on your phone" : "safely stored on your Mac"
            out.append("\(WaitProgressLabel.grouped(s)) \(unit) \(where_) and counting.")
        }
        return out
    }
}

// MARK: - Composed model

/// The single view-facing model. A view supplies the kind, tier, live progress, and
/// (cheap) library stats; everything the waiting UI renders is derived here, so the
/// SwiftUI layer is a thin binding with no copy or timing logic of its own.
public struct WaitingExperienceModel: Equatable, Sendable {
    public let kind: WaitKind
    public let onDevice: Bool
    public let progress: WaitProgress
    public let stats: WaitingLibraryStats

    /// Seconds between tip rotations. The view derives the rotation index from elapsed
    /// time via a TimelineView, so there is no timer to retain or invalidate.
    public static let tipRotationInterval: TimeInterval = 4

    public init(kind: WaitKind,
                onDevice: Bool = true,
                progress: WaitProgress = .indeterminate,
                stats: WaitingLibraryStats = .none) {
        self.kind = kind
        self.onDevice = onDevice
        self.progress = progress
        self.stats = stats
    }

    public var copy: WaitCopy { .make(for: kind, onDevice: onDevice) }

    public var tipDeck: WaitingTipDeck {
        WaitingTipDeck(kind: kind, onDevice: onDevice, stats: stats)
    }

    /// The status line under the headline: the honest determinate count for sync, else
    /// the elapsed-aware phase phrase, else the base privacy line.
    public func statusLine(elapsed: TimeInterval) -> String {
        if let label = WaitProgressLabel.syncLabel(progress, onDevice: onDevice) {
            return label
        }
        if let phase = WaitPhaseText.phrase(for: kind, elapsed: elapsed) {
            return phase
        }
        return copy.privacyLine
    }

    /// The rotation index for a given elapsed time (pure ⇒ injectable in tests).
    public func rotationIndex(elapsed: TimeInterval) -> Int {
        guard elapsed > 0 else { return 0 }
        return Int(elapsed / Self.tipRotationInterval)
    }

    /// The tip to show at a given elapsed time.
    public func tip(elapsed: TimeInterval) -> WaitingTip {
        tipDeck.tip(at: rotationIndex(elapsed: elapsed))
    }
}
