// PocketRecorderCheck.swift — THE FIRST THING IN THIS APP THAT EVER ASKS A RECORDER WHAT IT
// IS HOLDING.
//
// WHAT WAS MISSING, MEASURED RATHER THAN ASSERTED. `PocketBLEClient.listDates()`,
// `listRecordings(on:)` and `download(_:)` shipped fully implemented and fully unit-tested,
// and a tree-wide search for callers outside `Tests/` returned NOTHING. The reason was one
// line up the chain: `RecordingDeviceAttachment.adoptStoredFileRecorder` called
// `client.close()` on every branch and `attach` then called `teardown()`, so the one code path
// in the app that reached an authenticated recorder destroyed the session before returning.
// `withAuthenticatedSession` is the missing scope; this file is its first caller.
//
// WHAT THIS DELIBERATELY DOES NOT DO, AND WHY IT IS NOT A HALF-BUILD.
//
//   * IT DOES NOT DOWNLOAD. `download(_:)` still has no caller. Design §6c is explicit that no
//     bring-over button ships until the download path has run end to end, and the three things
//     standing between here and one are decisions rather than code: `PocketFileEvidence` has
//     no producer anywhere (`PocketDurableSync.importFile` fails closed without it), there is
//     no MP3 decoder in production, and `features/pocket-durable-sync.feature`'s last scenario
//     forbids the WAL that every other capture in this app is written through — so the SINK
//     for an imported file is unspecified. Building a downloader against an unspecified sink
//     is how the unwired modules this file exists beside got written.
//   * IT WRITES NOTHING TO THE RECORDER but the one key handshake custody already performs,
//     and it issues no delete: `PocketRecorderCustodyPromise.text` is a promise this app now
//     has a renderer for, on this panel.
//   * IT DOES NOT RE-PAIR. A check is a READ, and re-recording the PAIR here would make "I
//     looked at my recorder" indistinguishable from "I adopted it".
//
//     IT DOES, HOWEVER, KEEP WHAT THE RECORDER SAID. This bullet used to read "IT DOES NOT
//     TOUCH THE ACCOUNT STORE", which was true and was the defect: a check read the recorder's
//     charge, its firmware and how full it is, rendered them into one panel, and dropped all
//     three when the session closed — so the recorder's own page went on saying `Unavailable`
//     for the facts the check had just measured. Writing an OBSERVATION is not re-pairing:
//     `recordObservedFacts` refuses a device the account does not already remember, so a check
//     still cannot invent a remembered device, and preference and detach are untouched.

import Foundation

/// The recorder's own reported instant for one file, as a line of display text.
///
/// LOCALE-FREE ON PURPOSE. The recorder reports `2026-03-28` and `20260328001919`; a
/// `DateFormatter` would turn a fact the device stated into something that reads differently
/// per phone and would need a time zone this app cannot know (the recorder's clock is not the
/// phone's — see `PocketConversationClock`). So the digits are re-spaced, not re-interpreted.
public enum PocketRecordingLabel {

    /// THE SIX FIELDS A RECORDER'S TIMESTAMP CARRIES, IN EITHER SPELLING IT USES.
    ///
    /// ONE DEVICE, TWO SPELLINGS, MEASURED. `PKT01_BLUE_26079bc5` on firmware 1.6 lists both
    /// bare `20260807142852` and PH-prefixed `PH260811175026` — see
    /// `foundry-hearth/reference/pocket-ble-protocol.md`, hazard 3. Nine of the nineteen
    /// recordings on that device carry the second spelling, and nothing distinguishes them to
    /// the person holding it: same recorder, same shelf, same kind of recording.
    ///
    /// SO NEITHER SPELLING IS "THE" FORMAT. This returns the normalised `yyyyMMddHHmmss` digits
    /// for whichever one it was handed, and nil for anything else. It is the ONLY place either
    /// spelling is interpreted; every other use of a timestamp in this app — the file key, the
    /// removal frame, the receipt, the storage path — carries the recorder's own characters
    /// through untouched, because `(date, timestamp)` is only a stable identity if nothing
    /// normalises it on the way to the wire.
    ///
    /// THE CENTURY IS TAKEN FROM THE `date` FIELD THE RECORDER SENT ALONGSIDE, not assumed to
    /// be 2000. The listing frame is `MCU&F&<date>&<stamp>&<KB>`, so a full four-digit year is
    /// always present in the same frame as the two-digit one, and using it means a device that
    /// someday reports `PH99…` is dated from what it said rather than from what this file
    /// guessed in 2026.
    static func normalisedDigits(date: String, timestamp: String) -> String? {
        let characters = Array(timestamp)
        if characters.count == 14, characters.allSatisfy(\.isNumber) {
            return timestamp
        }
        // `PH` + `yyMMddHHmmss`. The prefix is matched exactly rather than by "two letters":
        // an unrecognised prefix is an unrecognised firmware, and guessing at one is how a
        // recording gets a plausible date nobody measured.
        guard characters.count == 14,
              timestamp.hasPrefix("PH") else { return nil }
        let rest = characters[2...]
        guard rest.allSatisfy(\.isNumber) else { return nil }
        // The century from the four-digit year the same frame carried.
        let day = Array(date.filter(\.isNumber))
        guard day.count == 8 else { return nil }
        let century = String(day[0..<2])
        return century + String(rest)
    }

    public static func title(date: String, timestamp: String) -> String {
        guard let normalised = normalisedDigits(date: date, timestamp: timestamp) else {
            // A firmware that reports something this build has never seen gets its own value
            // shown back to it, never a plausible-looking invention.
            return "\(date) · \(timestamp)"
        }
        let digits = Array(normalised)
        return "\(date) · \(String(digits[8..<10]))\(":")\(String(digits[10..<12]))"
    }

    /// THE INSTANT THE RECORDER SAYS THIS FILE WAS MADE, or nil when it reported something
    /// this build has never seen. The wire form is `yyyyMMddHHmmss`; the conversation-date
    /// pipeline speaks `yyyyMMdd-HHmmss`, so this is one inserted dash and then the SAME
    /// integer parse every capture id goes through — never a `DateFormatter`, which is the
    /// DATEPARSE hang class `CaptureIdTime` exists to keep out of this path.
    ///
    /// nil rather than "now": a file whose reported time cannot be read is a file whose date
    /// is unknown, and dating it to the moment somebody happened to collect it is exactly the
    /// invention `title(date:timestamp:)` above refuses to make.
    public static func reportedInstant(date: String, timestamp: String) -> Date? {
        guard let normalised = normalisedDigits(date: date, timestamp: timestamp) else {
            return nil
        }
        let digits = Array(normalised)
        let stamp = String(digits[0..<8]) + "-" + String(digits[8..<14])
        guard let seconds = CaptureIdTime.epochUTC(fromStamp: stamp) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// LIST_DIRS, then LIST per day — the reference trace's own two commands, in the order the
/// firmware serialises them on one authenticated session.
public enum PocketInventoryReader {

    /// Everything the recorder says it is holding, NEWEST FIRST.
    ///
    /// Ordering is by the recorder's own reported day and instant, both of which are
    /// fixed-width and therefore correctly ordered as text. It is not by arrival order: the
    /// firmware lists days in its own directory order, which is not chronological.
    public static func read(client: PocketBLEClient) async throws -> [PocketRecording] {
        // The protocol permits a repeated day (`pocket-ble-protocol-client.feature`: "Date
        // lists preserve the completed reported sequence"). Asking twice for the same day
        // would list its files twice.
        var days: [String] = []
        for day in try await client.listDates() where !days.contains(day) { days.append(day) }
        var found: [PocketRecording] = []
        for day in days { found += try await client.listRecordings(on: day) }
        return ordered(found)
    }

    /// NEWEST FIRST, BY WHEN THE RECORDING WAS MADE — not by how its name happens to sort.
    ///
    /// THE DEFECT THIS REPLACES. The old comparator was `$0.timestamp > $1.timestamp`, and its
    /// comment justified itself with "both of which are fixed-width and therefore correctly
    /// ordered as text". That is true of ONE spelling. The measured device uses two, and `"P"`
    /// is greater than every digit in ASCII — so every PH-prefixed recording sorted to the top
    /// of its day regardless of when it was made, and on a shelf that is nine-of-nineteen
    /// PH-prefixed the whole day reads in an order that is neither chronological nor arrival.
    ///
    /// So the comparison is on the PARSED instant. The tiebreak is stated rather than left to
    /// the sort: two recordings whose instants are equal, or whose instants this build cannot
    /// read at all, fall back to the raw token so the order is at least STABLE and the same on
    /// every run. A recording with no readable instant sorts BELOW every recording that has
    /// one, because "we do not know when this was made" is not a claim that it is recent.
    ///
    /// It is separate from `read(client:)` so it can be driven without a radio: the ordering is
    /// the part that was wrong, and it was unreachable by any test that did not own a
    /// Bluetooth session.
    public static func ordered(_ recordings: [PocketRecording]) -> [PocketRecording] {
        recordings.sorted { left, right in
            guard left.date == right.date else { return left.date > right.date }
            let leftInstant = PocketRecordingLabel.reportedInstant(date: left.date,
                                                                   timestamp: left.timestamp)
            let rightInstant = PocketRecordingLabel.reportedInstant(date: right.date,
                                                                     timestamp: right.timestamp)
            switch (leftInstant, rightInstant) {
            case let (l?, r?) where l != r: return l > r
            case (nil, _?):                 return false
            case (_?, nil):                 return true
            default:                        return left.timestamp > right.timestamp
            }
        }
    }

    /// The recorder's shelf as manifest items.
    ///
    /// `presences` IS THE ONLY THING THAT CAN MAKE A ROW CLAIM A COPY, and each entry is a
    /// place that was actually ASKED — never an inference from the listing. A row with no
    /// entry gets `onRecorder: yes` (the listing is what produced it) and `unknown` for the
    /// other two, which is the state every caller that has not consulted custody is honestly
    /// in. It USED to get `.recorderOnly`, which asserts this phone does not hold it — a claim
    /// nobody had checked, drawn with the confidence of one that had.
    ///
    /// - Parameter listedAt: when the recorder answered the listing, so `On the recorder`
    ///   carries its own age like every other place.
    public static func manifest(_ recordings: [PocketRecording],
                                presences: [String: PocketRecordingPresence] = [:],
                                listedAt: Date? = nil) -> [StoredFileManifestItem] {
        recordings.map {
            let id = "\($0.date)/\($0.timestamp)"
            return StoredFileManifestItem(
                id: id,
                title: PocketRecordingLabel.title(date: $0.date, timestamp: $0.timestamp),
                sizeBytes: $0.sizeBytes,
                presence: presences[id] ?? PocketRecordingPresence(
                    onRecorder: PocketPlaceReading(answer: .yes, observedAt: listedAt),
                    onThisPhone: .neverAsked,
                    safeElsewhere: .neverAsked))
        }
    }
}

/// THE THREE COMMANDS THE RECORDER SURFACE ISSUES, as a closed vocabulary.
///
/// An ERRAND is one trip to the recorder: it starts when the owner asks for something and
/// stops when the recorder has answered or failed to. `custody.commit` is the one thing an
/// errand can do that OUTLIVES it — a file taken into this phone's keeping — and it is
/// separate from `errand.stop` on purpose: an errand that stopped without one kept nothing,
/// and that difference is the whole diagnosis when somebody says the transfer "worked" and
/// the recording is not here.
///
/// These are constants rather than literals because the app issues them and the scenarios
/// look for them; two spellings of `errand.start` is a gate that passes while the app logs
/// nothing findable.
public enum PocketErrandCommand {
    /// A trip to the recorder began. `subject` says which errand: `shelf` or `bring-over`.
    public static let start = "errand.start"
    /// That trip ended. `outcome` is `DoorLog.succeeded` or a reason token.
    public static let stop = "errand.stop"
    /// A recording is now in this phone's keeping. `subject` is the recorder's own name for
    /// the file — `<date>/<timestamp>` — never a title.
    public static let custodyCommit = "custody.commit"
    /// A recording is no longer on the recorder, and Solleva PROVED it by re-reading the
    /// recorder's own shelf on the same errand. `subject` is the recorder's own name for the
    /// file — `<date>/<timestamp>` — never a title.
    ///
    /// IT IS LOGGED ONLY FOR A REMOVAL THAT ACTUALLY HAPPENED. A refusal and an
    /// acknowledged-but-still-there both stop at `errand.stop` with their own outcome token, so
    /// the presence of this line is the answer to "did my recording really leave the recorder"
    /// rather than "did Solleva ask".
    public static let recorderRemoval = "recorder.removal"

    /// The whole vocabulary, in the order an errand that keeps something issues them.
    public static let every: [String] = [start, stop, custodyCommit, recorderRemoval]

    /// The three errands this surface runs, as `subject` tokens.
    public static let shelfSubject = "shelf"
    public static let bringOverSubject = "bring-over"
    public static let removalSubject = "remove-from-recorder"
}

#if canImport(CoreBluetooth)

/// What one check established.
public enum PocketRecorderCheckOutcome: Sendable, Equatable {
    /// The session opened and the recorder answered. The presentation is the shipped
    /// `StoredFileDevicePresentation.detail` — built here rather than in the view, because
    /// `swift test` cannot compile `App/` and a line invented in a SwiftUI body is a second,
    /// unasserted implementation of the app's voice.
    case checked(StoredFileDeviceDetailPresentation)
    /// There was no session to ask on, and this is what the attach seam established instead.
    case unavailable(RecordingDeviceAttachOutcome)
    /// The session opened and the recorder would not answer the listing. A DIFFERENT ANSWER
    /// from an empty shelf, and the whole reason it is a case rather than an empty array.
    case inventoryFailed(PocketProtocolError)
}

/// Every string this panel can render, in the kit, for the same reason every other device
/// string is: `swift test` cannot compile `App/`.
public enum PocketRecorderCheckPresentation {
    /// While the radio is working. Not "Syncing" and not "Downloading" — nothing is coming
    /// over, and naming the wait after a thing that is not happening is the §6c mistake in a
    /// caption instead of a button.
    public static let checkingLine = "Checking the recorder…"

    public static let sectionTitle = "On the recorder"

    /// A shelf with nothing on it, said in words. A blank panel is indistinguishable from a
    /// panel that failed to load.
    public static let emptyLine = "There's nothing on this recorder right now."

    /// THE HONEST HALF OF DESIGN §6c, AND THE ONE RENDERER THE DELETION PROMISE HAS.
    /// `PocketRecorderCustodyPromise.text` had no caller in `App/` at all, while
    /// `features/pocket-durable-sync.feature` claimed "the shipped deletion promise remains
    /// visible". It is visible here, beside the list it is a promise about.
    ///
    /// IT USED TO SAY "It can't bring these over yet." That was true and is not any more, and
    /// leaving it would be this panel telling somebody an action it is showing them does not
    /// exist. One at a time is the shape `PocketBringOver` actually has, so that is what it
    /// says — the backlog and the cadence are written and still have no caller.
    public static let sectionNote =
        "Solleva can see what's on this recorder and can bring one recording over at a time. "
        + PocketRecorderCustodyPromise.text

    /// WHERE A BROUGHT-OVER RECORDING WILL END UP, in the terms of the brain that is on.
    ///
    /// Kept SEPARATE from `sectionNote` (a `static let` an existing gate reads verbatim) and
    /// separate per tier, because the phone-only brain saves with `markConfirmed: false` — so
    /// on that tier the shelf's "safe elsewhere" can never be true and borrowing the computer's
    /// sentence would be a promise the code cannot keep.
    public static func destinationNote(for brain: BrainChoice) -> String {
        PocketDestinationPresentation.line(for: brain)
    }

    /// The link came up, custody settled, and the recorder would not say what it holds.
    public static let inventoryFailedLine =
        "Solleva connected to this recorder, but it didn't say what it's holding."

    /// FoundryX has no usable key for a recorder the account remembers. It is NOT an offer to
    /// make one: a key written to a recorder that already holds one may silently re-key it,
    /// and that write may only ever happen from the consent screen.
    public static let keyUnusableLine =
        "Solleva doesn't have a working key for this recorder any more, so it can't open a "
        + "session with it. Set it up again from \""
        + RecordingDeviceConnectPresentation.affordanceTitle + "\"."

    /// The tapped device turned out to be a live one, or one this build does not know.
    public static let notThisRecorderLine =
        "That device isn't the recorder Solleva remembers under this name."

    /// Every line this panel can render, so "the panel offers no bring-over" is held over the
    /// POPULATION rather than over whichever string a test author remembered.
    ///
    /// THE ATTACH REASONS ARE PART OF THAT POPULATION. `message(for:)` returns
    /// `RecordingDeviceAttachPresentation.line(for:)` for an unreachable recorder, so a list
    /// of only this enum's own literals would be a population that omits the lines most
    /// likely to be seen — and `allCases` is what keeps a reason added later from slipping
    /// past this panel's own gates.
    public static let everyLine: [String] =
        [checkingLine, sectionTitle, emptyLine, sectionNote, inventoryFailedLine,
         keyUnusableLine, notThisRecorderLine]
        + RecordingDeviceUnreachableReason.allCases
            .map(RecordingDeviceAttachPresentation.line(for:))

    /// The line an outcome earns, or `nil` when the outcome is the panel itself.
    public static func message(for outcome: PocketRecorderCheckOutcome) -> String? {
        switch outcome {
        case .checked:
            return nil
        case .inventoryFailed:
            return inventoryFailedLine
        case .unavailable(let attach):
            switch attach {
            case .unreachable(let reason):
                // THE SAME SENTENCE THE CONNECT SHEET WOULD SAY, FOR THE SAME REASON. This
                // panel reaches the recorder over the identical radio steps, so "it never
                // answered" and "Bluetooth is off on this iPhone" are as different here as
                // they are there. Rendering the reason rather than one shared line is why
                // this is a `let` binding and not a bare `case`.
                return RecordingDeviceAttachPresentation.line(for: reason)
            case .setupUnavailable, .recoveryRequired, .custodyUnreadable,
                 .mintRefused, .mintNotVerified, .keyAcceptedNotDurable, .keyNotKept:
                // ONE SENTENCE FOR SEVEN STATES, AND THAT IS DELIBERATE HERE. On the connect
                // sheet each of these is a whole screen with its own ceremony, because that is
                // where a recorder is being SET UP. This panel is a read on a recorder the
                // account already remembers; the only true and actionable thing to say is that
                // the key no longer works and where setup lives. The mint cases are
                // unreachable from here at all — `withAuthenticatedSession` takes no consent.
                return keyUnusableLine
            case .live, .unrecognised, .adopted, .adoptionNotPersisted:
                return notThisRecorderLine
            }
        }
    }
}

/// WHAT THE RECORDER SAID IT IS HOLDING, IN THE PROTOCOL'S OWN FIELDS, for the one caller that
/// needs it that way.
///
/// `PocketRecorderCheckOutcome.checked` carries a PRESENTATION — titles and durations — and
/// `PocketBringOver.offered` cannot order display text. So a caller that intends to ask for a
/// file hands one of these in and reads it back afterwards. It is a parameter rather than a
/// wider outcome because every panel-only caller would otherwise carry recordings it has no
/// use for, and a second check API would be a second way to open a session.
public final class PocketRecorderShelfNote: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PocketRecording] = []
    public init() {}
    /// Newest first, or empty when no listing was read. AN UNREAD SHELF IS NOT AN EMPTY ONE —
    /// the outcome is the thing that says which of those happened.
    public var recordings: [PocketRecording] { lock.withLock { storage } }
    fileprivate func note(_ recordings: [PocketRecording]) {
        lock.withLock { storage = recordings }
    }
}

/// THE SHELF, RE-STATED FROM WHAT THIS PHONE HOLDS — WITHOUT TOUCHING THE RADIO.
///
/// WHAT THIS EXISTS FOR, MEASURED. `App/DeviceScreen.swift` ended every bring-over by calling
/// its own `run(…)` again: a second full attach — power-on gate, connect, discovery, key
/// handshake — plus a second `LIST_DIRS` and a second `LIST&` per day, to learn ONE fact the
/// phone's own disk already knew, namely that the file it had just written is here. One tap
/// on "Bring it over" therefore cost TWO authenticated sessions, and the second one asked the
/// recorder a question whose answer could not have changed.
///
/// Custody is the authority on what this phone holds — the SAME authority the transfer
/// consults — so re-asking it is a stat per listed file and no radio time at all. The listing
/// itself cannot have changed: nothing but this app writes to that recorder, and if the owner
/// pressed record in between, the next deliberate check is what should discover it, not a
/// silent re-read they never asked for.
public enum PocketShelfReadModel {

    /// Which of these recordings this phone is already holding, asked one file at a time.
    ///
    /// Per recording rather than a manifest fetch, for the reason `PocketBringOver.offeredNext`
    /// gives: `alreadyHeld` is the only authority on the question, and a second index of it
    /// would be a second answer to "do we have this" — the shape that loses recordings.
    public static func heldFileIDs(_ recordings: [PocketRecording],
                                   custody: any PocketRecorderFileCustody,
                                   identity: RecordingDeviceIdentity) async -> Set<String> {
        var held: Set<String> = []
        for recording in recordings {
            let key = PocketRecorderFileKey(identity: identity,
                                            date: recording.date,
                                            timestamp: recording.timestamp)
            if await custody.alreadyHeld(key) { held.insert("\(recording.date)/\(recording.timestamp)") }
        }
        return held
    }

    /// WHERE EACH OF THESE RECORDINGS IS, RESOLVED ONCE, FOR EVERY CALLER THAT ASKS.
    ///
    /// TWO CALLERS, ONE RESOLVER, ON PURPOSE. `PocketRecorderCheck.read` asks it inside an
    /// authenticated session; the recorder page asks it again after a transfer has moved
    /// custody with the session already closed. If those were two pieces of code they would be
    /// two answers to "is this recording safe", and the delete ruling names that as how a
    /// recording gets lost.
    ///
    /// IT IS `nonisolated` AND `async`, WHICH IS LOAD-BEARING. Both authorities read the disk —
    /// `alreadyHeld` stats a file, `confirmedInLore` stats a marker — and a caller on the main
    /// actor awaiting this hops off it. `PocketCaptureDurability` additionally trips a hard
    /// counter if it is ever read on main, so a future caller that inlines this loop is caught
    /// rather than merely discouraged.
    ///
    /// - Parameter listedAt: when the recorder answered, or nil when this recompute is not
    ///   backed by a listing at all — a re-read after a transfer knows the file was on the
    ///   recorder when the session closed, and says so with the age it actually has.
    public static func presences(_ recordings: [PocketRecording],
                                 identity: RecordingDeviceIdentity,
                                 custody: (any PocketRecorderFileCustody)?,
                                 durability: (any PocketDurabilityEvidence)?,
                                 listedAt: Date? = nil,
                                 askedAt: Date) async -> [String: PocketRecordingPresence] {
        var resolved: [String: PocketRecordingPresence] = [:]
        for recording in recordings {
            let key = PocketRecorderFileKey(identity: identity,
                                            date: recording.date,
                                            timestamp: recording.timestamp)
            resolved["\(recording.date)/\(recording.timestamp)"] =
                await PocketPresenceReader.presence(for: key,
                                                    listedAt: listedAt ?? askedAt,
                                                    custody: custody,
                                                    durability: durability,
                                                    askedAt: askedAt)
        }
        return resolved
    }
}

extension StoredFileDeviceDetailPresentation {
    /// THE SAME PANEL, WITH ONLY THE CUSTODY COLUMN RE-STATED.
    ///
    /// Name, link, battery and firmware are facts the RECORDER supplied on the session that
    /// is now closed; re-deriving them here would be this file inventing device state. Only
    /// the manifest moves, because only custody can have changed.
    public func withManifest(_ items: [StoredFileManifestItem])
        -> StoredFileDeviceDetailPresentation {
        StoredFileDeviceDetailPresentation(
            name: name,
            eyebrow: eyebrow,
            linkLabel: linkLabel,
            battery: battery,
            firmware: firmware,
            manifest: StoredFileDevicePresentation.manifest(items),
            showsRecordingState: showsRecordingState,
            showsLiveActivity: showsLiveActivity)
    }
}

/// ONE CHECK: open a session, read the shelf, close it.
public enum PocketRecorderCheck {

    /// - Parameter custody: what this phone is holding, so a row can say "In Solleva" about a
    ///   file that has actually been brought over. `nil` — the default — means the check does
    ///   not consult custody at all and every row is `.recorderOnly`, which keeps every
    ///   existing caller and every hermetic scenario exactly as truthful as it was.
    /// - Parameter attachment: injected so the Brine scenario drives the SHIPPED attachment
    ///   over a faked radio rather than a faked attachment. The default is the production one.
    ///   A fresh attachment per check is not an optimisation to remove: `teardown()` retires
    ///   the object's link and generation, so an attachment is single-use by construction.
    /// - Parameter shelf: handed in by a caller that intends to ASK FOR A FILE, and filled with
    ///   what the recorder listed. `nil` — the default — is a panel-only check.
    /// - Parameter durability: what makes a row able to say a recording is SAFE ELSEWHERE. nil
    ///   — the default — means safety was not asked, and every row reads `Unknown` for that
    ///   place rather than `No`: a question nobody put to the disk has no answer, and the
    ///   destructive paths read `answer == .yes` only.
    public static func run(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        custody: (any PocketRecorderFileCustody)? = nil,
        durability: (any PocketDurabilityEvidence)? = nil,
        attachment: RecordingDeviceAttachment = RecordingDeviceAttachment(),
        shelf: PocketRecorderShelfNote? = nil
    ) async -> PocketRecorderCheckOutcome {
        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: id, advertisedName: advertisedName
        ) { client, identity in
            await read(client: client, identity: identity, advertisedName: advertisedName,
                       custody: custody, durability: durability, shelf: shelf)
        }
        switch result {
        case .unavailable(let outcome): return .unavailable(outcome)
        case .ran(let outcome):         return outcome
        }
    }

    private static func read(client: PocketBLEClient,
                             identity: PocketAuthenticatedIdentity,
                             advertisedName: String,
                             custody: (any PocketRecorderFileCustody)?,
                             durability: (any PocketDurabilityEvidence)?,
                             shelf: PocketRecorderShelfNote?)
        async -> PocketRecorderCheckOutcome {
        // THE SHIPPED BRIDGE, NOT A SECOND READ OF THE SAME FACTS. `observe` is what the
        // adoption path already uses for battery and firmware, and its output maps 1:1 onto
        // the capability states `StoredFileDevicePresentation.detail` asks for.
        let observation = await PocketRecordingDeviceBridge.observe(
            client: client, identity: identity, advertisedName: advertisedName)
        // KEPT BEFORE THE LISTING IS ATTEMPTED, on purpose. A recorder that answers its
        // charge and then refuses to list its files has still told this account two true
        // things, and the branch below returns `.inventoryFailed` without ever reaching the
        // write — so doing it afterwards would throw away exactly the readings a person most
        // wants when something is going wrong.
        RecordingDeviceStore.recordObservedFacts(identity: observation.identity,
                                                 readings: observation.readings)
        let declared = RecordingDeviceCapabilities(declared: observation.declaredCapabilities)
        do {
            let recordings = try await PocketInventoryReader.read(client: client)
            let listedAt = Date()
            // FREE SPACE IS ASKED ONLY NOW — AFTER THE LISTING HAS ALREADY SUCCEEDED.
            //
            // `APP&SPACE` runs inside `protected(.information)`, which RETIRES the whole
            // authenticated session on a timeout. Asked before the listing (which is where it
            // used to live), a firmware that silently ignores the command would turn every
            // "Connect and check now" into "it didn't say what it's holding" for a recorder
            // that would have listed fine — trading the one thing the owner opened the page
            // for against a number. These bytes have never been issued to a real recorder from
            // this app; probe P3 has not run. So the listing is banked first, and a free-space
            // reading that never arrives renders as the never-asked state with the action that
            // would ask it.
            if let space = await PocketRecordingDeviceBridge.storageReading(client: client,
                                                                            now: listedAt) {
                RecordingDeviceStore.recordObservedFacts(
                    identity: observation.identity,
                    readings: [RecordingDeviceCapabilityKey.freeSpace.rawValue: space])
            }
            shelf?.note(recordings)
            // EACH PLACE IS ASKED, ONE FILE AT A TIME, and only when a caller handed over an
            // authority for it. "Is this on the phone" and "is this safe elsewhere" are two
            // questions with two answers; deriving either from the listing would be the panel
            // deciding what it holds. A place with no authority stays `unknown`.
            //
            // THIS RUNS OFF THE MAIN ACTOR. `read` is called from inside
            // `withAuthenticatedSession`'s async body, and `PocketCaptureDurability` reads the
            // `.lore-confirmed` marker with `CaptureManager.noteMainThreadDecode()` gating it —
            // so a future caller that drags this onto the main thread trips a hard counter.
            let presences = await PocketShelfReadModel.presences(
                recordings,
                identity: identity.recordingDeviceIdentity,
                custody: custody,
                durability: durability,
                listedAt: listedAt,
                askedAt: listedAt)
            return .checked(StoredFileDevicePresentation.detail(
                name: observation.reportedName,
                link: .connected,
                battery: declared.state(of: .batteryLevel),
                firmware: declared.state(of: .firmwareVersion),
                manifest: PocketInventoryReader.manifest(recordings, presences: presences,
                                                         listedAt: listedAt),
                now: listedAt))
        } catch let error as PocketProtocolError {
            return .inventoryFailed(error)
        } catch {
            return .inventoryFailed(.transportFailure)
        }
    }
}

#endif
