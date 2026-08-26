// CaptureCardPresentation — the content-first conversation card, as pure data
// (track 20260714T1800 ux_prototype_realignment, features/capture-home.feature).
//
// The card view renders EXCLUSIVELY from this struct, and the struct simply has
// no field that could carry engineering telemetry: no segment counts, no byte
// totals, no raw transport errors. A sync problem is the single human word
// "Waiting for computer" — the details stay in the logs. Built through `make`
// from the same inputs the view already holds (the WAL status snapshot, the
// ConversationMeta sidecar, the durable card tombstone, and the door poller's
// state), so tests drive the REAL code path the card renders.
//
// This file also owns the capture home's other durable presentation pieces:
//   • CaptureHomeCopy    — the prototype's exact record-CTA + headline copy.
//   • CaptureFindState   — search open/closed + query ("Search all" opens it).
//   • MeterCaptionText   — the recording instrument's human caption (no
//                          frame counts, no byte sizes — ever again).

import Foundation

/// Everything a conversation card can show. Pure + Equatable so brine step-defs
/// assert on the presentation the real builder produced.
public struct CaptureCardPresentation: Equatable, Sendable {
    /// The conversation's NAME — Kiln title, else the durable card title, else the
    /// first words actually spoken. Never a filename or capture id.
    public var title: String
    /// What it was about (Kiln summary → card summary → provisional on-device
    /// transcript). The view clamps it to two lines.
    public var summaryLine: String?
    /// ONE human word for where the conversation is:
    /// Recording / Waiting for computer / Saved to computer / Transcribing / Ready
    /// (phone-only tier: Saved on this phone / Transcribing on this phone).
    public var statusWord: String
    /// "Tue, Jul 14 · 4:16 PM–4:18 PM · 2 min" (+ " · Office" when a place is known).
    public var metaLine: String
    /// The category pill: "Work" when the user filed it, "Work, auto" when the
    /// on-device model did. nil = unfiled (no pill).
    public var categoryLabel: String?
    /// Real segment-size energy buckets for the row's small waveform (empty = none).
    public var waveform: [Double]
    /// The folded pipeline progress — drives the status dot's energy only.
    public var progress: ConversationProgress

    /// Build the card from the view's real inputs. Pure — no I/O, no clocks.
    public static func make(status: CaptureStatus,
                            meta: ConversationMeta?,
                            card: ConversationCardMeta?,
                            pollerStage: CaptureLifecycleStage,
                            pollerTitle: String?,
                            pollerSummary: String?,
                            droppedReason: String?,
                            hasCachedTranscript: Bool,
                            destination: CaptureDestination,
                            categoryName: String?,
                            categoryAutoFiled: Bool,
                            waveform: [Double],
                            manualRecoveryInProgress: Bool = false) -> CaptureCardPresentation {
        let progress = ConversationProgress.resolve(
            wal: status.stage,
            streaming: status.streaming,
            door: pollerStage,
            hasTitle: !(pollerTitle ?? "").isEmpty,
            hasCachedTranscript: hasCachedTranscript)

        let start = cardStart(status: status, meta: meta, card: card)
        var metaLine = timeRangeString(meta: meta, fallback: start)
        if let place = meta?.location?.label, !place.isEmpty {
            metaLine += " · \(place)"
        }

        var label: String?
        if let categoryName, !categoryName.isEmpty {
            label = categoryAutoFiled ? "\(categoryName), auto" : categoryName
        }

        return CaptureCardPresentation(
            title: title(card: card, pollerTitle: pollerTitle, start: start),
            summaryLine: summary(card: card, pollerTitle: pollerTitle, pollerSummary: pollerSummary),
            statusWord: manualRecoveryInProgress
                ? manualRecoveryInProgressWord(destination: destination)
                : statusWord(progress: progress, droppedReason: droppedReason,
                             destination: destination, syncError: status.lastSyncError),
            metaLine: metaLine,
            categoryLabel: label,
            waveform: waveform,
            progress: progress)
    }

    /// Explicitly names the destination and intent; this is never a vague "Retry".
    ///
    /// IT WAS A CONSTANT THAT SAID "computer", offered to every tier — so a phone-only
    /// owner and a Vault owner were both invited to send a voice note to a machine they
    /// do not have. A constant is a Bool with one value: it cannot answer "which of
    /// three", so it is a function of the tier now.
    public static func manualRecoveryActionTitle(destination: CaptureDestination) -> String {
        switch destination {
        case .phone:    return "Save on this phone"
        case .computer: return "Send to computer"
        case .vault:    return "Send to your Vault"
        }
    }

    /// The VoiceOver hint on that button. It was the bare literal "Retries sending this
    /// voice note's audio to your computer" in the view body — a sentence no test in this
    /// repository could execute, naming a machine two of the three tiers do not have.
    public static func manualRecoveryHint(destination: CaptureDestination) -> String {
        switch destination {
        case .phone:    return "Retries saving this voice note's audio on this phone"
        case .computer: return "Retries sending this voice note's audio to your computer"
        case .vault:    return "Retries sending this voice note's audio to your Vault"
        }
    }

    /// The status word WHILE that recovery is in flight. Same reason, same shape — this
    /// was the bare literal "Sending to computer…" inside `make`.
    public static func manualRecoveryInProgressWord(destination: CaptureDestination) -> String {
        switch destination {
        case .phone:    return "Saving on this phone…"
        case .computer: return "Sending to computer…"
        case .vault:    return "Sending to your Vault…"
        }
    }

    // MARK: title — content first, never an identifier

    /// Words a first-words fallback title keeps from the transcript head.
    static let fallbackTitleWords = 6

    static func title(card: ConversationCardMeta?, pollerTitle: String?, start: Date) -> String {
        let known = [pollerTitle, card?.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let known {
            // Generic/duplicate titles ("Thank you", "Okay"…) get the start time
            // appended so two short captures read distinctly. Unchanged behavior.
            return ConversationTitleDisplay.display(title: known, start: start) {
                Self.timeFmt.string(from: $0)
            }
        }
        // Fallback: the first words actually spoken — never a filename or id.
        if let body = card?.provisionalTranscript?
            .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            let words = body.split(separator: " ").map(String.init)
            let head = words.prefix(fallbackTitleWords).joined(separator: " ")
            return words.count > fallbackTitleWords ? head + "…" : head
        }
        return "Untitled voice note"
    }

    // MARK: summary — what it was about

    static func summary(card: ConversationCardMeta?, pollerTitle: String?,
                        pollerSummary: String?) -> String? {
        if let s = pollerSummary, !s.isEmpty { return s }
        if let s = card?.summary, !s.isEmpty { return s }
        // Until Kiln's summary lands, the on-device provisional transcript is the
        // most honest "what it was about" — but only while still provisional and
        // untitled (once a real title exists, a missing summary stays missing).
        if card?.isProvisional == true, (pollerTitle ?? "").isEmpty,
           let body = card?.provisionalTranscript, !body.isEmpty {
            return body
        }
        return nil
    }

    // MARK: status — one human word

    /// The single human status word, PER TIER. A sync problem (pending segments,
    /// transport errors) reads as "Waiting for computer" / "Waiting for your Vault" —
    /// the raw error NEVER reaches a card.
    ///
    /// THIS TOOK `local: Bool`. `App/CaptureScreen.swift` derived that bit as
    /// `destination == .phone`, which answers `false` for BOTH the computer and the cell,
    /// so every conversation card on a Vault owner's home screen said "Waiting for
    /// computer" and then "Saved to computer" about a machine he does not own — the exact
    /// sentence `3371f9d` fixed one line over and `236c4b2` fixed for the waits.
    static func statusWord(progress: ConversationProgress, droppedReason: String?,
                           destination: CaptureDestination,
                           syncError: String? = nil) -> String {
        if syncError?.hasPrefix("incomplete:") == true {
            return "Incomplete — audio kept on this phone"
        }
        switch progress {
        case .recording:
            return "Taking a note"
        case .savedOnPhone:
            // Durable on the phone, not yet with the second place — whether the last
            // sync attempt errored is a log line, not card copy.
            switch destination {
            case .phone:    return "Saved on this phone"
            case .computer: return "Waiting for computer"
            case .vault:    return "Waiting for your Vault"
            }
        case .savedToComputer:
            switch destination {
            case .phone:    return "Saved on this phone"
            case .computer: return "Saved to computer"
            case .vault:    return "Saved to your Vault"
            }
        case .transcribing:
            switch destination {
            case .phone:            return "Transcribing on this phone"
            case .computer, .vault: return "Transcribing"
            }
        case .ready:
            return "Ready"
        case .failed:
            // Known terminal reasons keep their specific human line; anything
            // unrecognized degrades to a calm word — never a raw interpolation.
            switch droppedReason {
            case "silent_no_transcript", "noise", "junk_purge": return "No speech detected"
            case "key_lost": return "Audio couldn't be recovered"
            default: return "Needs review"
            }
        }
    }

    // MARK: meta line

    /// The conversation's durable REAL START. Same processing-time-proof priority
    /// the list uses: meta → card → capture-id timestamp → the WAL launch time.
    static func cardStart(status: CaptureStatus, meta: ConversationMeta?,
                          card: ConversationCardMeta?) -> Date {
        if let s = meta?.startedAt, s > 0 { return Date(timeIntervalSince1970: TimeInterval(s)) }
        if let s = card?.startedAt, s > 0 { return Date(timeIntervalSince1970: TimeInterval(s)) }
        if let s = CaptureIdTime.startedAt(fromCaptureId: status.id), s > 0 {
            return Date(timeIntervalSince1970: TimeInterval(s))
        }
        return status.startedAt
    }

    /// "Tue, Jul 14 · 4:16 PM–4:18 PM · 2 min" when closed; date + start time alone
    /// while open. Shared with the detail view so both show the SAME range.
    public static func timeRangeString(meta: ConversationMeta?, fallback: Date) -> String {
        guard let meta else {
            return "\(dayFmt.string(from: fallback)) · \(timeFmt.string(from: fallback))"
        }
        let start = Date(timeIntervalSince1970: TimeInterval(meta.startedAt))
        let day = dayFmt.string(from: start)
        guard let endSecs = meta.endedAt else { return "\(day) · \(timeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(endSecs))
        let span = "\(timeFmt.string(from: start))–\(timeFmt.string(from: end))"
        if let dur = meta.durationSeconds {
            let mins = max(1, Int((Double(dur) / 60).rounded()))
            return "\(day) · \(span) · \(mins) min"
        }
        return "\(day) · \(span)"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f
    }()
}

/// The capture home's prototype copy, pinned in one place (fullflow2.html
/// "08 Capture home"). Pure constants so the scenarios assert the exact words.
public enum CaptureHomeCopy {
    /// The record CTA card's headline.
    public static let recordTitle = "Make a voice note"

    /// The record CTA's where-does-it-go line, per tier. Exhaustive over
    /// `CaptureDestination` — a fourth brain fails to compile until it picks its words
    /// (a Vault owner used to read "on your computer" because this was a Bool).
    public static func recordSubtitle(destination: CaptureDestination) -> String {
        switch destination {
        case .phone:
            // CAUGHT BY `CaptureDestinationFallbackTests`, 2026-08-19. This arm said "It
            // joins your full history when your computer connects" — to the ONE tier that
            // has no computer, in the very function whose own comment boasts that it was
            // converted away from a Bool "because a Vault owner used to read 'on your
            // computer'". The conversion gave `.vault` its words and left `.phone` naming a
            // machine its owner does not have. On this tier the phone IS the full history.
            return "Saved on this phone. This phone holds your full history."
        case .computer:
            return "Saved on this phone. It joins your full history on your computer."
        case .vault:
            return "Saved on this phone. It joins your full history in your Vault."
        }
    }

    /// "Recent on this phone" headline + its "N conversations" row-meta.
    public static let recentHeadline = "Recent on this phone"

    /// The headline for the list when a SECOND PLACE is answering.
    ///
    /// ⚠ "Recent on this phone" BECAME A FALSE CLAIM the moment the list merged. The page
    /// now interleaves what this phone holds with what the second place holds, ordered by
    /// time — so a header saying "on this phone" sits above rows that are not on this
    /// phone. The owner asked for one list precisely so the two places stop being separate
    /// timelines; the label has to stop separating them too.
    ///
    /// Phone tier keeps `recentHeadline`, because there it is simply true.
    public static func recentHeadline(secondPlace: String?) -> String {
        guard let secondPlace, !secondPlace.isEmpty else { return recentHeadline }
        return "Recent on this phone and \(secondPlace)"
    }
    public static func conversationCount(_ n: Int) -> String {
        "\(n) voice note\(n == 1 ? "" : "s")"
    }

    /// The trailing text-action that opens the full-history search.
    public static let searchAll = "Search all"
}

/// The capture home's find state — search open/closed + the live query. The view
/// binds to this instead of private @State so "Search all" and the header icon
/// drive the SAME real state the tests assert on.
public final class CaptureFindState: ObservableObject {
    @Published public var searchOpen = false
    @Published public var query = ""

    public init() {}

    /// "Search all" — opens the search field (idempotent, never toggles it shut).
    public func openSearchAll() {
        searchOpen = true
    }

    /// The header search icon — toggles; closing always clears the stale query.
    public func toggleSearch() {
        searchOpen.toggle()
        if !searchOpen { query = "" }
    }
}

/// The recording instrument's caption — a human state, never diagnostics
/// (frame counts and byte sizes were build-telemetry that shipped to the card;
/// they live in the logs now).
public enum MeterCaptionText {
    public static func caption(paused: Bool, isRecordingMic: Bool) -> String {
        if paused { return "Paused, not listening" }
        return isRecordingMic ? "Taking a note" : "Listening…"
    }
}
