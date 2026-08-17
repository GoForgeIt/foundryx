// PocketPresence.swift — WHERE A RECORDING IS, IN THREE PLACES, EACH WITH ITS OWN AGE.
//
// THE DEFECT THIS REPLACES. `StoredFileCustody { foundryX, recorderOnly }` is a two-valued
// answer to a three-valued question. It cannot say "on this phone, but not yet safe anywhere
// else" — which is the ONLY state that decides whether clearing the recorder is safe — and it
// cannot say "nobody asked". `PocketInventoryReader.manifest`'s `heldFileIDs` defaulted to the
// empty set, so a caller that never consulted custody rendered every row as `.recorderOnly`:
// a place nobody asked about, drawn with the same confidence as a place that answered no.
//
// THE PREDICATE, AND WHY IT IS A DISJUNCTION.
//
//     durableElsewhere(key) ≜ let captureID = custody.conversation(for: key)
//         AND ( TranscriptCacheStore.isConfirmedInLore(captureID)        // the CEILING
//               OR CaptureStatus(captureID).stage == .savedToComputer )  // the FLOOR
//       ; unknown ⇒ false
//
// `savedToComputer` is recomputed from segment files (`CaptureWAL.computeStatus`), and the
// ~30-day retention sweep DELETES those segment files once a capture is confirmed in Lore
// (`CaptureManager.runRetentionSweepOffMain`). So a recording that synced perfectly reads
// `savedOnPhone` again two months later, and a gate built on that disjunct alone closes
// forever BECAUSE THE SYSTEM WORKED. `.lore-confirmed` is the marker the same sweep is
// explicitly written to preserve (`CaptureRetention` keeps it while pruning the audio), and it
// is the fact this app already trusts enough to destroy its own audio on. So it is the ceiling,
// the stage is the floor, and either one is enough.
//
// UNKNOWN IS A VALUE, NOT A MISSING ONE. Every place answers `yes`, `no` or `unknown`, and
// every destructive question reads `answer == .yes`. Nothing anywhere treats `unknown` as a
// yes, and the one-line row label for an unasked place says so in words rather than guessing.

import Foundation

/// What is known about one place. `unknown` is first-class: it is what a place nobody asked
/// about honestly answers, and it is never rounded to `no`.
public enum PocketPresenceAnswer: String, Equatable, Sendable, CaseIterable {
    case yes, no, unknown
}

/// One place's answer, and WHEN it was established. `observedAt == nil` means nobody has ever
/// asked — which is a different fact from "asked a while ago", and the age line says so.
public struct PocketPlaceReading: Equatable, Sendable {
    public let answer: PocketPresenceAnswer
    public let observedAt: Date?

    public init(answer: PocketPresenceAnswer, observedAt: Date?) {
        // A reading nobody made cannot carry an instant, and an `unknown` with a timestamp
        // would render as "we don't know, as of 20 minutes ago" — which is not a fact.
        self.answer = answer
        self.observedAt = answer == .unknown ? nil : observedAt
    }

    public static let neverAsked = PocketPlaceReading(answer: .unknown, observedAt: nil)
    public var isYes: Bool { answer == .yes }
}

/// The three places one recording can be, as of the moment they were each read.
public struct PocketRecordingPresence: Equatable, Sendable {
    /// The recorder's own shelf listed it.
    public let onRecorder: PocketPlaceReading
    /// This phone is holding the bytes (custody).
    public let onThisPhone: PocketPlaceReading
    /// It is safe somewhere that is neither the recorder nor only this phone.
    public let safeElsewhere: PocketPlaceReading

    public init(onRecorder: PocketPlaceReading,
                onThisPhone: PocketPlaceReading,
                safeElsewhere: PocketPlaceReading) {
        self.onRecorder = onRecorder
        self.onThisPhone = onThisPhone
        self.safeElsewhere = safeElsewhere
    }

    public static let nothingAsked = PocketRecordingPresence(
        onRecorder: .neverAsked, onThisPhone: .neverAsked, safeElsewhere: .neverAsked)

    /// THE SAFETY PREDICATE every destructive path reads. `unknown ⇒ false` by construction —
    /// there is no arm of this expression that an unasked place can satisfy.
    public var isDurableElsewhere: Bool { safeElsewhere.answer == .yes }

    /// What a factory reset or a forget would cost, per recording: the recorder has it and
    /// this phone does not. `unknown` counts toward the cost, because a place nobody asked
    /// about is not a copy anybody holds.
    public var isOnlyOnTheRecorder: Bool {
        onRecorder.answer == .yes && onThisPhone.answer != .yes
    }
}

/// The two facts that can make a recording safe somewhere other than the recorder.
///
/// A protocol rather than a free function because the two facts come from different places —
/// one is a marker on disk, the other is a live WAL's stage — and a hermetic scenario must be
/// able to state both without owning a `CaptureManager`.
public protocol PocketDurabilityEvidence: Sendable {
    /// The `.lore-confirmed` marker: the CEILING, preserved through both retention passes.
    func confirmedInLore(_ captureID: String) -> Bool
    /// The capture's stage, or nil when this build has no live WAL for it. The FLOOR.
    func stage(of captureID: String) -> CaptureStage?
}

/// The production evidence: the confirmation marker off disk, and a SNAPSHOT of the stages the
/// running app already holds in memory.
///
/// TWO PROPERTIES THIS TYPE EXISTS FOR.
///
///   * IT IS READ OFF THE MAIN THREAD. `TranscriptCacheStore.isConfirmedInLore` is a bare
///     `fileExists` — a synchronous stat — and it is asked once per listed recording. Doing
///     that on the main actor while a shelf renders is the disk-on-main pathology this app has
///     already paid for twice. The gate lives at the operation itself
///     (`CaptureRetention.isConfirmedInLore` notes `CaptureManager.noteMainThreadDecode()`), so
///     ANY caller that reintroduces it on main trips the deterministic counter.
///   * IT MEMOISES ONLY `true`. A confirmation never un-happens: the sweep that deletes the
///     audio is written to keep the marker. Memoising `false` would pin a recording as unsafe
///     for the life of the object, and the shelf is re-read after every bring-over.
public final class PocketCaptureDurability: PocketDurabilityEvidence, @unchecked Sendable {
    private let baseDir: URL
    private let stages: [String: CaptureStage]
    private let lock = NSLock()
    private var confirmed: Set<String> = []

    /// THE DEFECT THIS PARAMETER CLOSES, and it is the one that would have lost a recording.
    ///
    /// The floor of the safety predicate is `CaptureStage.savedToComputer`, which means "every
    /// segment was ACK'd" (`CaptureWAL.swift:796`, ack written at `:471`). On the phone-only
    /// tier that ack is self-issued: `CaptureBackend.swift:71` passes
    /// `uploadSegment: localMode ? { @Sendable _, _, _ in } : nil`, a closure that succeeds by
    /// doing nothing, and the file says so in its own words — *"the WAL's ack then means
    /// 'durably on this phone'"*. `App/RootView.swift` ships `localMode: true` for
    /// `.justMyPhone`. So without this parameter, `isDurableElsewhere` returned TRUE for a
    /// recording whose only copy is on this handset, and the shelf rendered "In Solleva, and
    /// safe elsewhere" directly above the line "The only copy will be on this iPhone." — the
    /// same screen contradicting itself, one tap away from a delete that would have been the
    /// last copy.
    ///
    /// It is a REQUIRED argument with no default. A default would be a decision made by
    /// whoever forgot to pass it, on the one predicate the delete ruling rests on.
    ///
    /// - Parameter brain: which brain is on. `.justMyPhone` means no stage this phone can
    ///   observe is evidence of anywhere else, so the floor is withdrawn entirely and only the
    ///   `.lore-confirmed` ceiling — which a phone-only build never writes — can answer yes.
    /// - Parameter stages: a snapshot taken from the captures the app already has in memory.
    ///   It is a snapshot rather than a live read so resolving a shelf costs no main-actor
    ///   hop per recording and no second enumeration of anybody's segments.
    public init(baseDir: URL, stages: [String: CaptureStage] = [:], brain: BrainChoice) {
        self.baseDir = baseDir
        self.stages = brain.uploadAckProvesAnotherPlace ? stages : [:]
    }

    public func confirmedInLore(_ captureID: String) -> Bool {
        lock.lock()
        let memo = confirmed.contains(captureID)
        lock.unlock()
        if memo { return true }
        guard TranscriptCacheStore.isConfirmedInLore(captureId: captureID, baseDir: baseDir)
        else { return false }
        lock.lock()
        confirmed.insert(captureID)
        lock.unlock()
        return true
    }

    public func stage(of captureID: String) -> CaptureStage? { stages[captureID] }
}

public enum PocketDurability {
    /// `unknown ⇒ false`: no capture id, or no evidence, is not safe.
    public static func durableElsewhere(captureID: String?,
                                        evidence: (any PocketDurabilityEvidence)?) -> Bool {
        guard let captureID, !captureID.isEmpty, let evidence else { return false }
        if evidence.confirmedInLore(captureID) { return true }
        return evidence.stage(of: captureID) == .savedToComputer
    }
}

/// Resolves one recording's three places by ASKING each one, and leaving unasked the ones
/// nobody handed it an authority for.
public enum PocketPresenceReader {

    /// - Parameter listedAt: when the recorder's own shelf listed this file, or nil when this
    ///   answer does not come from a listing at all.
    /// - Parameter custody: what this phone is holding. nil ⇒ the phone was not asked, and the
    ///   answer is `unknown` rather than `no`.
    /// - Parameter durability: nil ⇒ safety was not asked. A `captureID` that custody does not
    ///   have is `no` — it WAS asked, and the answer is that this file never became a
    ///   conversation, so nothing anywhere else can be holding it.
    public static func presence(for key: PocketRecorderFileKey,
                                listedAt: Date?,
                                custody: (any PocketRecorderFileCustody)?,
                                durability: (any PocketDurabilityEvidence)?,
                                askedAt: Date) async -> PocketRecordingPresence {
        let onRecorder: PocketPlaceReading = listedAt.map {
            PocketPlaceReading(answer: .yes, observedAt: $0)
        } ?? .neverAsked

        guard let custody else {
            return PocketRecordingPresence(onRecorder: onRecorder,
                                           onThisPhone: .neverAsked,
                                           safeElsewhere: .neverAsked)
        }
        let held = await custody.alreadyHeld(key)
        let onThisPhone = PocketPlaceReading(answer: held ? .yes : .no, observedAt: askedAt)

        guard durability != nil else {
            return PocketRecordingPresence(onRecorder: onRecorder,
                                           onThisPhone: onThisPhone,
                                           safeElsewhere: .neverAsked)
        }
        let captureID = await custody.conversation(for: key)
        let safe = PocketDurability.durableElsewhere(captureID: captureID, evidence: durability)
        return PocketRecordingPresence(
            onRecorder: onRecorder,
            onThisPhone: onThisPhone,
            safeElsewhere: PocketPlaceReading(answer: safe ? .yes : .no, observedAt: askedAt))
    }
}

/// One place, as a line a person reads: what it is, what the answer is, how old the answer is.
public struct PocketPlaceLine: Equatable, Sendable {
    public let place: String
    public let answer: String
    public let age: String
    public init(place: String, answer: String, age: String) {
        self.place = place; self.answer = answer; self.age = age
    }
}

/// Every string the three places can render. In the kit, like every other device string,
/// because `swift test` cannot compile `App/`.
public enum PocketPresencePresentation {
    public static let onRecorderPlace = "On the recorder"
    public static let onThisPhonePlace = "On this iPhone"
    public static let safeElsewherePlace = "Safe elsewhere"

    public static let yesAnswer = "Yes"
    public static let noAnswer = "No"
    /// NOT "No". A place nobody asked about has not answered.
    public static let unknownAnswer = "Unknown"
    public static let neverCheckedAge = "never checked"

    /// The row's one-line summary. Three sentences for three states, and the third is the one
    /// the two-valued custody label could not say at all.
    public static let inSollevaLabel = "In Solleva"
    public static let onlyOnRecorderLabel = "Only on the recorder"
    public static let phoneNotCheckedLabel = "Solleva hasn't checked this iPhone"
    /// Said only when the phone HAS it and nothing else does — the state that governs a reset.
    public static let onThisPhoneOnlyLabel = "In Solleva, on this iPhone only"
    public static let safeElsewhereLabel = "In Solleva, and safe elsewhere"

    public static func label(_ presence: PocketRecordingPresence) -> String {
        switch presence.onThisPhone.answer {
        case .unknown: return phoneNotCheckedLabel
        case .no:      return onlyOnRecorderLabel
        case .yes:
            switch presence.safeElsewhere.answer {
            case .yes:     return safeElsewhereLabel
            case .no:      return onThisPhoneOnlyLabel
            case .unknown: return inSollevaLabel
            }
        }
    }

    public static func answer(_ a: PocketPresenceAnswer) -> String {
        switch a {
        case .yes: return yesAnswer
        case .no: return noAnswer
        case .unknown: return unknownAnswer
        }
    }

    /// LOCALE-FREE AND COARSE ON PURPOSE, exactly like `PocketRecordingLabel`: this is the age
    /// of a reading, not a timestamp anybody should plan around.
    public static func age(_ observedAt: Date?, now: Date) -> String {
        guard let observedAt else { return neverCheckedAge }
        let seconds = max(0, Int(now.timeIntervalSince(observedAt)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 {
            let m = seconds / 60
            return m == 1 ? "1 minute ago" : "\(m) minutes ago"
        }
        if seconds < 86_400 {
            let h = seconds / 3_600
            return h == 1 ? "1 hour ago" : "\(h) hours ago"
        }
        let d = seconds / 86_400
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }

    public static func lines(_ presence: PocketRecordingPresence, now: Date) -> [PocketPlaceLine] {
        [(onRecorderPlace, presence.onRecorder),
         (onThisPhonePlace, presence.onThisPhone),
         (safeElsewherePlace, presence.safeElsewhere)]
            .map { PocketPlaceLine(place: $0.0,
                                   answer: answer($0.1.answer),
                                   age: age($0.1.observedAt, now: now)) }
    }

    /// ONE PLACE AS ONE LINE OF TEXT. In the kit because two screens render these now — the
    /// recorder's shelf and a conversation that came off a recorder — and the same three facts
    /// spelled two ways on two screens is how one of them quietly stops matching the other.
    public static func oneLine(_ line: PocketPlaceLine) -> String {
        "\(line.place): \(line.answer) - \(line.age)"
    }

    // MARK: - THE SAME THREE PLACES, SAID ONCE, ON ONE LINE

    // WHAT WAS ON NICK'S SCREEN, VERBATIM, FOR ONE RECORDING:
    //
    //     Only on the recorder
    //     On the recorder: Yes - just now
    //     On this iPhone: No - just now
    //     Safe elsewhere: No - just now
    //
    // Four lines. THREE facts and one summary, and the summary is `label(_:)` — which is the
    // other three said again in prose, derived from them by this very file. Nineteen of those
    // stacked is the page he was shown, and it is the reason the controls that act on those
    // recordings were off the bottom of it.
    //
    // NOTHING IS DROPPED TO FIX IT. The three places and their ages are load-bearing: they are
    // the whole evidence that deleting a recording is safe, and `isOnlyOnTheRecorder` and
    // `isDurableElsewhere` are read straight off them. So the SUMMARY is what leaves the row —
    // it is the only line that states nothing the other three do not — and the three places are
    // compressed onto one line with the age they share stated once.
    //
    // `label(_:)` IS NOT DELETED. It is the shelf read model's one-line answer and eight
    // scenarios assert over it; it simply stops being drawn beside the lines it summarises.

    /// The SHORT name of a place, for the row that says all three at once. It is a second
    /// spelling of the same place, and it lives here, next to the long one, for the reason
    /// every string on this surface does: a word invented in a `Text(…)` is in no population
    /// the promise gate or the language lexer can see.
    public static let onRecorderShortPlace = "Recorder"
    public static let onThisPhoneShortPlace = "iPhone"
    public static let safeElsewhereShortPlace = "Elsewhere"

    /// What the row says before an age it is stating for the whole row rather than per place.
    public static let readPrefix = "Read "

    /// ONE PLACE, AS SHORT AS IT GETS: the place and its answer, and a flag the view turns into
    /// emphasis. The flag is here rather than in the view because "which of these three is the
    /// one to look at" is a decision, and a decision in a SwiftUI body is a decision no test in
    /// this repository can compile.
    public struct PocketPresenceChip: Equatable, Sendable {
        public let place: String
        public let answer: String
        /// The place is holding it. The view draws these in the ink colour and the rest faint.
        public let isHeld: Bool

        public init(place: String, answer: String, isHeld: Bool) {
            self.place = place; self.answer = answer; self.isHeld = isHeld
        }
    }

    /// ONE ROW'S ANSWER TO "WHERE IS THIS RECORDING", COMPLETE AND SAID ONCE.
    public struct PocketPresenceBlock: Equatable, Sendable {
        /// The three places, in the order they have always been listed, each named once.
        public let chips: [PocketPresenceChip]
        /// How old those answers are. ONE clause when every answered place shares an instant —
        /// which is the ordinary case, because one check reads all three — and one clause per
        /// place when they do not. `nil` when no place has an instant at all, because every
        /// chip already reads `Unknown` and saying it a fourth time is the defect this closes.
        public let ageLine: String?

        public init(chips: [PocketPresenceChip], ageLine: String?) {
            self.chips = chips; self.ageLine = ageLine
        }
    }

    /// - Parameter now: the instant the ages are rendered against, injected for the same reason
    ///   `lines(_:now:)` injects it — a scenario states an age as a fact instead of racing it.
    public static func block(_ presence: PocketRecordingPresence,
                             now: Date) -> PocketPresenceBlock {
        let places: [(short: String, reading: PocketPlaceReading)] = [
            (onRecorderShortPlace, presence.onRecorder),
            (onThisPhoneShortPlace, presence.onThisPhone),
            (safeElsewhereShortPlace, presence.safeElsewhere),
        ]
        let chips = places.map {
            PocketPresenceChip(place: $0.short,
                               answer: answer($0.reading.answer),
                               isHeld: $0.reading.isYes)
        }
        // A place with no instant contributes NO age, and it is never silently dropped: its
        // chip already reads `Unknown`, which is the whole of what "nobody asked" means here.
        let dated = places.filter { $0.reading.observedAt != nil }
        guard !dated.isEmpty else { return PocketPresenceBlock(chips: chips, ageLine: nil) }
        let ages = dated.map { age($0.reading.observedAt, now: now) }
        if Set(ages).count == 1 {
            return PocketPresenceBlock(chips: chips, ageLine: readPrefix + ages[0])
        }
        let each = zip(dated, ages).map { "\($0.0.short) \($0.1)" }.joined(separator: ", ")
        return PocketPresenceBlock(chips: chips, ageLine: readPrefix + each)
    }

    /// EVERY LINE ONE ROW STATES ABOUT WHERE A RECORDING IS, in render order. The population
    /// the "nothing is said twice" rule is held over — a rule over a set somebody assembled by
    /// hand would move with the mutation it exists to catch.
    public static func rowLines(_ presence: PocketRecordingPresence, now: Date) -> [String] {
        let b = block(presence, now: now)
        return b.chips.map { "\($0.place) \($0.answer)" } + [b.ageLine].compactMap { $0 }
    }

    public static var everyLine: [String] {
        [onRecorderPlace, onThisPhonePlace, safeElsewherePlace,
         yesAnswer, noAnswer, unknownAnswer, neverCheckedAge,
         inSollevaLabel, onlyOnRecorderLabel, phoneNotCheckedLabel,
         onThisPhoneOnlyLabel, safeElsewhereLabel,
         onRecorderShortPlace, onThisPhoneShortPlace, safeElsewhereShortPlace]
    }
}

/// WHAT TAKING THE RECORDER AWAY WOULD COST, AND WHY THE BUTTON STILL WORKS.
///
/// It is the owner's recorder. A stale shelf is a reason to LOOK again, never a reason for the
/// app to hold the owner's own reset hostage — so staleness moves the primary action and never
/// the enabled state. The old shape of this mistake is an app that disables the way out
/// precisely when it is least sure, which is when a person most needs one.
public enum PocketRecorderCostPresentation {
    public static let resetAction = "Start the recorder over"
    /// What a stale shelf changes: what is asked FIRST, not what is allowed.
    public static let checkFirstAction = "Check the recorder first"
    /// A shelf older than this is stale. A first-class constant, not an env-var knob.
    public static let shelfGoesStaleAfter: TimeInterval = 15 * 60

    public struct ResetGate: Equatable, Sendable {
        /// ALWAYS true. Held by its own scenario so a later "helpful" guard reds here.
        public let isEnabled: Bool
        public let primaryAction: String
        public let cost: String
        public init(isEnabled: Bool, primaryAction: String, cost: String) {
            self.isEnabled = isEnabled; self.primaryAction = primaryAction; self.cost = cost
        }
    }

    /// `count(onRecorder ∧ ¬onPhone)` — and `¬onPhone` includes `unknown`.
    public static func onlyOnTheRecorder(_ presences: [PocketRecordingPresence]) -> Int {
        presences.filter(\.isOnlyOnTheRecorder).count
    }

    /// WHAT A SHELF NOBODY READ COSTS: not nothing — UNKNOWN.
    ///
    /// THE DEFECT THIS SENTENCE CLOSES, and it was the most expensive one on this surface.
    /// `presences` used to be a bare array, and `[]` — the state of every freshly opened
    /// recorder page, because nothing checks a recorder until the owner taps — fell into
    /// `case 0` and printed *"Solleva already has every recording this recorder listed."*
    /// Forget is reachable with no check at all, so the confirmation for the gesture that
    /// destroys the session key — after which every recording the recorder still holds alone
    /// is unreachable forever — stated as a FACT that this phone holds everything, about a
    /// recorder Solleva had never spoken to. One screen away, this same file is careful to
    /// render an unasked place as "Solleva hasn't checked this iPhone".
    ///
    /// `nil` is therefore a distinct state from `[]` and the type carries it: `nil` means
    /// nobody read the shelf, `[]` means the shelf was read and is holding nothing.
    public static let shelfNotCheckedLine =
        "Solleva hasn't checked what this recorder is holding."

    /// - Parameter presences: nil ⇒ nobody has read this recorder's shelf.
    public static func costLine(_ presences: [PocketRecordingPresence]?) -> String {
        guard let presences else { return shelfNotCheckedLine }
        let n = onlyOnTheRecorder(presences)
        switch n {
        case 0:  return "Solleva already has every recording this recorder listed."
        case 1:  return "1 recording is on the recorder and not on this iPhone."
        default: return "\(n) recordings are on the recorder and not on this iPhone."
        }
    }

    public static func resetGate(shelfObservedAt: Date?,
                                 now: Date,
                                 presences: [PocketRecordingPresence]?) -> ResetGate {
        let fresh = shelfObservedAt.map { now.timeIntervalSince($0) <= shelfGoesStaleAfter }
            ?? false
        return ResetGate(isEnabled: true,
                         primaryAction: fresh ? resetAction : checkFirstAction,
                         cost: costLine(presences))
    }

    /// Forgetting states its cost in the SAME terms as the reset, because it is the same cost:
    /// the key goes, and every recording the recorder still holds alone becomes unreachable.
    public static func forgetMessage(warning: String?,
                                     presences: [PocketRecordingPresence]?) -> String {
        guard let warning, !warning.isEmpty else { return costLine(presences) }
        return warning + "\n\n" + costLine(presences)
    }

    public static var everyLine: [String] {
        [resetAction, checkFirstAction,
         costLine(nil),
         costLine([]),
         costLine([oneOnlyOnTheRecorder]),
         costLine([oneOnlyOnTheRecorder, oneOnlyOnTheRecorder])]
    }

    /// A presence used only to enumerate this type's own lines.
    private static let oneOnlyOnTheRecorder = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: Date(timeIntervalSince1970: 0)),
        onThisPhone: PocketPlaceReading(answer: .no, observedAt: Date(timeIntervalSince1970: 0)),
        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: Date(timeIntervalSince1970: 0)))
}

/// WHERE A BROUGHT-OVER RECORDING WILL END UP, SAID IN THE TERMS OF THE BRAIN THAT IS ON.
///
/// `LocalBackend.finalize` persists with `markConfirmed: false` — the phone-only brain never
/// writes a `.lore-confirmed` marker, on purpose, because nothing left the phone. So
/// `durableElsewhere` can never be true for a person on that tier, and the shelf must not
/// borrow the computer's sentence to imply otherwise. Every tier's sentence is DISTINCT, and
/// that distinctness is held over the population rather than over one remembered string.
public enum PocketDestinationPresentation {
    public static let phoneOnlyLine = "The only copy will be on this iPhone."
    public static let computerLine =
        "A copy goes to your computer, so it won't be only on this iPhone."
    public static let vaultLine =
        "A copy goes to your Vault, so it won't be only on this iPhone."

    public static func line(for brain: BrainChoice) -> String {
        switch brain {
        case .justMyPhone:  return phoneOnlyLine
        case .myComputer:   return computerLine
        case .foundryCloud: return vaultLine
        }
    }

    /// THE POPULATION. Every choice's line is here, and every line is distinct — which is what
    /// makes "the phone-only tier does not reuse the computer's sentence" an assertion that
    /// cannot be satisfied by an empty set.
    public static var everyLine: [String] { BrainChoice.allCases.map(line(for:)) }
}
