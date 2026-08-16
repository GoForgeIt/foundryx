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
    public static func title(date: String, timestamp: String) -> String {
        let digits = Array(timestamp)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else {
            // A firmware that reports something this build has never seen gets its own value
            // shown back to it, never a plausible-looking invention.
            return "\(date) · \(timestamp)"
        }
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
        let digits = Array(timestamp)
        guard digits.count == 14, digits.allSatisfy(\.isNumber) else { return nil }
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
        return found.sorted {
            $0.date == $1.date ? $0.timestamp > $1.timestamp : $0.date > $1.date
        }
    }

    /// The recorder's shelf as manifest items.
    ///
    /// `heldFileIDs` IS THE ONLY THING THAT CAN MAKE A ROW SAY `.foundryX`, and it is a set of
    /// files custody was actually ASKED about — never an inference from the listing. The
    /// default is empty, which is the state every caller that has not consulted custody is
    /// honestly in: `StoredFileCustody.foundryX` shipped rendering as "In Solleva" and nothing
    /// had ever produced one, and a row that claims a copy this phone does not hold is the
    /// worst possible thing for this particular panel to say.
    public static func manifest(_ recordings: [PocketRecording],
                                heldFileIDs: Set<String> = []) -> [StoredFileManifestItem] {
        recordings.map {
            let id = "\($0.date)/\($0.timestamp)"
            return StoredFileManifestItem(
                id: id,
                title: PocketRecordingLabel.title(date: $0.date, timestamp: $0.timestamp),
                sizeBytes: $0.sizeBytes,
                custody: heldFileIDs.contains(id) ? .foundryX : .recorderOnly)
        }
    }
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
    public static func run(
        peripheralIdentifier id: UUID,
        advertisedName: String,
        custody: (any PocketRecorderFileCustody)? = nil,
        attachment: RecordingDeviceAttachment = RecordingDeviceAttachment(),
        shelf: PocketRecorderShelfNote? = nil
    ) async -> PocketRecorderCheckOutcome {
        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: id, advertisedName: advertisedName
        ) { client, identity in
            await read(client: client, identity: identity, advertisedName: advertisedName,
                       custody: custody, shelf: shelf)
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
                             shelf: PocketRecorderShelfNote?)
        async -> PocketRecorderCheckOutcome {
        // THE SHIPPED BRIDGE, NOT A SECOND READ OF THE SAME FACTS. `observe` is what the
        // adoption path already uses for battery and firmware, and its output maps 1:1 onto
        // the capability states `StoredFileDevicePresentation.detail` asks for.
        let observation = await PocketRecordingDeviceBridge.observe(
            client: client, identity: identity, advertisedName: advertisedName)
        // KEPT BEFORE THE LISTING IS ATTEMPTED, on purpose. A recorder that answers its
        // charge and its free space and then refuses to list its files has still told this
        // account two true things, and the branch below returns `.inventoryFailed` without
        // ever reaching the write — so doing it afterwards would throw away exactly the
        // readings a person most wants when something is going wrong.
        RecordingDeviceStore.recordObservedFacts(identity: observation.identity,
                                                 readings: observation.readings)
        let declared = RecordingDeviceCapabilities(declared: observation.declaredCapabilities)
        do {
            let recordings = try await PocketInventoryReader.read(client: client)
            shelf?.note(recordings)
            // CUSTODY IS ASKED, ONE FILE AT A TIME, and only when a caller handed one over.
            // "Is this on the phone" is a question with an answer; deriving it from the
            // listing would be the panel deciding what it holds.
            var held: Set<String> = []
            if let custody {
                for recording in recordings {
                    let key = PocketRecorderFileKey(
                        identity: identity.recordingDeviceIdentity,
                        date: recording.date,
                        timestamp: recording.timestamp)
                    if await custody.alreadyHeld(key) {
                        held.insert("\(recording.date)/\(recording.timestamp)")
                    }
                }
            }
            return .checked(StoredFileDevicePresentation.detail(
                name: observation.reportedName,
                link: .connected,
                battery: declared.state(of: .batteryLevel),
                firmware: declared.state(of: .firmwareVersion),
                manifest: PocketInventoryReader.manifest(recordings, heldFileIDs: held)))
        } catch let error as PocketProtocolError {
            return .inventoryFailed(error)
        } catch {
            return .inventoryFailed(.transportFailure)
        }
    }
}

#endif
