// WaitingExperience — the ONE honest-wait presentation model (perf track WS-C).
//
// The app is on-device first, so most user-visible waits are irreducible on-device
// model runs or a network hop to the user's own brain — their Mac over the relayed
// door, or their Vault (a hosted cell) over its direct HTTPS door. Rather than lie
// with a fake progress bar or a bare spinner, every wait longer than ~1s renders the
// SAME component, driven by this model, which does three things:
//
//   1. NAMES what's happening in plain, honest language, TRUE to the mechanism
//      (on-device Apple Foundation Models for recap/title on the phone tier, the
//      brain's own pipeline elsewhere, an end-to-end-encrypted relay hop for Mac
//      door fetches, a direct encrypted connection for the Vault, and a durable
//      segment upload for sync/backfill).
//   2. Shows REAL progress ONLY where it is measurable — the sync/backfill drain,
//      where `syncedSegments / totalSegments` is a genuine determinate fraction.
//      The model waits (recap/title/transcription/door) get NO fake bar; they get
//      elapsed-aware phase text instead ("still working — longer recordings take
//      longer").
//   3. Rotates a small deck of genuinely-true, useful facts about what FoundryX is
//      doing with the user's data (privacy-forward, plus real library stats when
//      cheaply available) — deterministic + injectable, so it is unit-tested.
//
// THE TIER IS `CaptureDestination`, NEVER A BOOL. This file used to take
// `onDevice: Bool` — a two-way switch written before the cell tier existed — so
// `.vault` fell into the `.computer` arm byte-identically and a cell owner was told
// "Speech-to-text runs on your own Mac — the audio never goes to a server we run":
// false three ways at once (the audio DID go to a server we run, it did NOT stay
// there, and no Mac was involved). Every switch below is exhaustive over
// `CaptureDestination` with no default, so a FOURTH tier fails to compile until it
// makes an explicit decision about its own words — the same pattern the saved-to
// line adopted in 3371f9d. WaitingDestinationGateTests sweeps every string here.
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
    /// Recaps run on the phone on EVERY tier.
    case recap
    /// Foundation-model titling of a conversation — on the phone, or by the brain's own
    /// pipeline (Mac / Vault) whose title arrives asynchronously.
    case title
    /// Titling that THIS PHONE is doing, whatever the tier.
    ///
    /// IT IS A KIND, NOT AN ARGUMENT. The detail view has two titling waits: one for the
    /// brain's pipeline (`.title`) and one for the on-device fallback synth, and the
    /// second used to be spelled `WaitingExperienceModel(kind: .title, destination: .phone)`
    /// — a hand-written place literal sitting in a view body, indistinguishable at a glance
    /// from the tier bug beside it and impossible to tell apart from a mistake. The
    /// MECHANISM is what differs, so the mechanism is what the type says.
    case onDeviceTitle
    /// Speech-to-text of a capture — on-device Whisper on the phone tier; the brain's
    /// speech service elsewhere.
    case transcription
    /// Fetching a conversation's content from the resolved brain.
    case doorFetch
    /// Draining the phone-side write-ahead log up to the resolved brain (segment backfill).
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

    /// The copy for a wait kind on a tier. Every claim below is load-bearing:
    ///
    ///   - The PHONE tier is the only one allowed to say the audio never leaves a
    ///     device in the owner's hands.
    ///   - The COMPUTER tier reuses the already-shipped PrivacyView sentence — the
    ///     Mac ORCHESTRATES transcription via one cloud speech service; it does not
    ///     perform it, so "transcribing locally" was false even here.
    ///   - The VAULT tier says what is true without frightening: a private machine
    ///     that's yours alone, one speech service, purpose-limited. It must NEVER
    ///     claim "the audio never goes to a server we run" (the Vault IS one) and
    ///     must never mention a Mac or the relay (a Vault owner has neither).
    public static func make(for kind: WaitKind, destination: CaptureDestination) -> WaitCopy {
        switch kind {
        case .recap:
            // Recaps run on the phone on every tier — one true sentence, three tiers.
            switch destination {
            case .phone, .computer, .vault:
                return WaitCopy(
                    headline: "Summarizing on your iPhone",
                    privacyLine: "The recap is written by a model running entirely on your device — no voice note text is sent anywhere to summarize it.")
            }
        case .onDeviceTitle:
            // ONE true sentence, three tiers: this work runs on the handset either way.
            switch destination {
            case .phone, .computer, .vault:
                return WaitCopy(
                    headline: "Naming this voice note",
                    privacyLine: "A model on your iPhone is reading the transcript to write its title and summary.")
            }
        case .title:
            switch destination {
            case .phone:
                return WaitCopy(
                    headline: "Naming this voice note",
                    privacyLine: "A model on your iPhone is reading the transcript to write its title and summary.")
            case .computer:
                return WaitCopy(
                    headline: "Naming this voice note",
                    privacyLine: "A model on your Mac is reading the transcript to write its title and summary.")
            case .vault:
                return WaitCopy(
                    headline: "Naming this voice note",
                    privacyLine: "A model in your Vault is reading the transcript to write its title and summary.")
            }
        case .transcription:
            switch destination {
            case .phone:
                return WaitCopy(
                    headline: "Transcribing on this iPhone",
                    privacyLine: "Speech-to-text runs on your iPhone — the audio never leaves this device.")
            case .computer:
                return WaitCopy(
                    headline: "Transcribing on your computer",
                    privacyLine: "Your computer turns the audio into text with one speech service, for that and nothing else. It never touches our servers.")
            case .vault:
                return WaitCopy(
                    headline: "Transcribing in your Vault",
                    privacyLine: "Your Vault is a private machine that's yours alone. It turns the audio into text with one speech service, for that and nothing else.")
            }
        case .doorFetch:
            switch destination {
            case .phone:
                return WaitCopy(
                    headline: "Opening this voice note",
                    privacyLine: "Read straight from this phone's own storage — nothing leaves your device.")
            case .computer:
                return WaitCopy(
                    headline: "Fetching from your Mac",
                    privacyLine: "Coming over the end-to-end-encrypted tunnel to your computer — even the relay can't read it.")
            case .vault:
                return WaitCopy(
                    headline: "Fetching from your Vault",
                    privacyLine: "Coming straight from your own Vault over an encrypted connection.")
            }
        case .sync:
            switch destination {
            case .phone:
                return WaitCopy(
                    headline: "Catching up",
                    privacyLine: "Each segment is written to your phone's disk before anything else — nothing is ever lost.")
            case .computer:
                return WaitCopy(
                    headline: "Copying to your computer",
                    privacyLine: "Each segment is written to your phone's disk first, then copied to your Mac — the phone keeps its own copy too.")
            case .vault:
                return WaitCopy(
                    headline: "Copying to your Vault",
                    privacyLine: "Each segment is written to your phone's disk first, then copied to your Vault — the phone keeps its own copy too.")
            }
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
    /// ≤ elapsed. `sync` is determinate and has no ladder here. The door rung names the
    /// place being reached — the tunnel is a COMPUTER-tier fact (the Vault has no relay
    /// and the phone has no network hop at all).
    static func ladder(for kind: WaitKind,
                       destination: CaptureDestination) -> [(after: TimeInterval, text: String)] {
        switch kind {
        case .recap:
            return [
                (8, "Still summarizing — almost there."),
            ]
        case .title, .onDeviceTitle:
            return [
                (10, "Still working on the title…"),
            ]
        case .transcription:
            return [
                (20, "Still transcribing — longer voice notes take longer."),
                (45, "Nearly there — this was a long one."),
            ]
        case .doorFetch:
            switch destination {
            case .phone:
                return [
                    (3, "Still opening — one moment."),
                ]
            case .computer:
                return [
                    (3, "Still reaching your Mac — the tunnel may be waking up."),
                ]
            case .vault:
                return [
                    (3, "Still reaching your Vault — it may be waking up."),
                ]
            }
        case .sync:
            return []
        }
    }

    /// The phase phrase to show after `elapsed` seconds, or nil to keep the base copy.
    public static func phrase(for kind: WaitKind, destination: CaptureDestination,
                              elapsed: TimeInterval) -> String? {
        var chosen: String?
        for rung in ladder(for: kind, destination: destination) where elapsed >= rung.after {
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
    /// for indeterminate progress (no fake number). `destination` phrases the place the
    /// segments actually land.
    public static func syncLabel(_ progress: WaitProgress,
                                 destination: CaptureDestination) -> String? {
        guard case let .determinate(done, total) = progress, total > 0 else { return nil }
        let clampedDone = min(done, total)
        let where_: String
        switch destination {
        case .phone:    where_ = "saved on your phone"
        case .computer: where_ = "safely on your computer"
        case .vault:    where_ = "safely in your Vault"
        }
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
        self.tips = tips.isEmpty ? [WaitingTip(Self.evergreen(for: .phone)[0])] : tips
    }

    public init(kind: WaitKind, destination: CaptureDestination,
                stats: WaitingLibraryStats = .none) {
        var out: [String] = []
        out.append(contentsOf: Self.kindFacts(kind, destination: destination))
        out.append(contentsOf: Self.evergreen(for: destination))
        out.append(contentsOf: Self.statFacts(stats, destination: destination))
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

    // Evergreen, always-true facts about the app's actual mechanism ON THIS TIER.
    // These used to be one unconditional list that told phone-only owners about a Mac
    // and a relay neither of which existed for them — the tier decides the truth.
    static func evergreen(for destination: CaptureDestination) -> [String] {
        switch destination {
        case .phone:
            return [
                "Every segment is written to your phone's disk the moment it's heard — a dropped connection never loses a word.",
                "Your transcripts are stored as plain text on your phone, ready to search in an instant.",
                "Your phone keeps the only copy of every voice note — nothing is uploaded to us.",
                "Titles, summaries, and recaps are written by a model on your device, not in anyone's cloud.",
            ]
        case .computer:
            return [
                "Every segment is written to your phone's disk before it's sent — a dropped connection never loses a word.",
                "Your transcripts are stored as plain text on your phone, ready to search in an instant.",
                "Your phone keeps its own copy of every voice note, even after it's backed up to your Mac.",
                "The link to your Mac is end-to-end encrypted — even the relay that carries it can't read a thing.",
            ]
        case .vault:
            return [
                "Every segment is written to your phone's disk before it's sent — a dropped connection never loses a word.",
                "Your transcripts are stored as plain text on your phone, ready to search in an instant.",
                "Your phone keeps its own copy of every voice note, even after it's saved to your Vault.",
                "Your Vault answers over an encrypted connection — a private machine provisioned for you alone.",
            ]
        }
    }

    static func kindFacts(_ kind: WaitKind, destination: CaptureDestination) -> [String] {
        switch kind {
        case .recap:
            switch destination {
            case .phone, .computer, .vault:
                return ["This recap is drawn only from your own voice notes — the model is told never to invent details."]
            }
        case .onDeviceTitle:
            switch destination {
            case .phone, .computer, .vault:
                return ["The title comes from the transcript itself — nothing is uploaded to name it."]
            }
        case .title:
            switch destination {
            case .phone:
                return ["The title comes from the transcript itself — nothing is uploaded to name it."]
            case .computer:
                return ["The title comes from the transcript itself, written by a model on your own computer."]
            case .vault:
                return ["Your Vault reads the transcript and writes the title with one model service — for that and nothing else."]
            }
        case .transcription:
            switch destination {
            case .phone:
                return ["On-device transcription turns even a private conversation into text without it ever leaving your phone."]
            case .computer:
                return ["Your computer sends the audio to one speech service to transcribe — for that purpose and nothing else."]
            case .vault:
                return ["Your Vault sends the audio to one speech service to transcribe — for that purpose and nothing else."]
            }
        case .doorFetch:
            switch destination {
            case .phone:
                return ["Your voice notes live on this phone — nothing has to be fetched from anywhere else."]
            case .computer:
                return ["Your voice notes live on your Mac, not our servers — this is your own computer answering."]
            case .vault:
                return ["Your voice notes live in your Vault — your own private machine answering directly."]
            }
        case .sync:
            switch destination {
            case .phone:
                return ["Backing up locally keeps everything on a device you own — nothing is uploaded to us."]
            case .computer:
                return ["Once a segment reaches your Mac it can't be lost — and your phone still keeps its copy."]
            case .vault:
                return ["Once a segment reaches your Vault it can't be lost — and your phone still keeps its copy."]
            }
        }
    }

    static func statFacts(_ stats: WaitingLibraryStats,
                          destination: CaptureDestination) -> [String] {
        var out: [String] = []
        if let c = stats.conversationCount, c > 0 {
            let unit = c == 1 ? "voice note" : "voice notes"
            let kept: String
            switch destination {
            case .phone:    kept = "kept on this phone"
            case .computer: kept = "kept on your own devices"
            case .vault:    kept = "kept on your phone and in your Vault"
            }
            out.append("You've captured \(WaitProgressLabel.grouped(c)) \(unit) so far — \(kept).")
        }
        if let s = stats.segmentsOnComputer, s > 0 {
            let unit = s == 1 ? "segment" : "segments"
            let where_: String
            switch destination {
            case .phone:    where_ = "kept safe on your phone"
            case .computer: where_ = "safely stored on your Mac"
            case .vault:    where_ = "safely stored in your Vault"
            }
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
    public let destination: CaptureDestination
    public let progress: WaitProgress
    public let stats: WaitingLibraryStats

    /// Seconds between tip rotations. The view derives the rotation index from elapsed
    /// time via a TimelineView, so there is no timer to retain or invalidate.
    public static let tipRotationInterval: TimeInterval = 4

    /// `destination` has NO DEFAULT, deliberately — the same argument `RootGate` and
    /// `ConversationFacesView.brain` already make: a default here is a decision about
    /// where a user's audio went, made by whoever forgot to pass it. A defaulted
    /// `onDevice: Bool = true` is exactly how the cell tier shipped reading "your own
    /// Mac".
    public init(kind: WaitKind,
                destination: CaptureDestination,
                progress: WaitProgress = .indeterminate,
                stats: WaitingLibraryStats = .none) {
        self.kind = kind
        self.destination = destination
        self.progress = progress
        self.stats = stats
    }

    public var copy: WaitCopy { .make(for: kind, destination: destination) }

    public var tipDeck: WaitingTipDeck {
        WaitingTipDeck(kind: kind, destination: destination, stats: stats)
    }

    /// The status line under the headline: the honest determinate count for sync, else
    /// the elapsed-aware phase phrase, else the base privacy line.
    public func statusLine(elapsed: TimeInterval) -> String {
        if kind == .sync,
           let label = WaitProgressLabel.syncLabel(progress, destination: destination) {
            return label
        }
        if let phase = WaitPhaseText.phrase(for: kind, destination: destination,
                                            elapsed: elapsed) {
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
