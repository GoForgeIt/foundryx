// CaptureDeviceSidecar — WHICH device recorded a conversation, written beside it.
//
// WHY THIS EXISTS. Before this, a capture directory recorded only its SOURCE KIND
// (`.capture-source`, holding `omi` or `phoneMic`). That was enough while there was one
// external device: "an Omi recorded this" and "THE Omi recorded this" were the same
// sentence. With a device-agnostic recording surface they are not. Two consequences, both
// user-visible:
//
//   • RESUME. `resumableCaptureId` continues the newest recent Omi capture. With two
//     remembered devices, device B reconnecting would continue device A's conversation and
//     append B's audio to it. The conversation would be a lie and the archive's attribution
//     would be a lie with it.
//   • ATTRIBUTION. The timeline has to say what recorded a conversation. `omi` is a source
//     kind, not a device.
//
// WHAT IT IS NOT. It is not a migration of `.capture-source`. That marker keeps its exact
// shipped meaning and its exact shipped bytes, because every conversation recorded before
// this shipped depends on it and rewriting them is not something a release may do to a
// user's archive. This is an ADDITIONAL, richer record for conversations opened from here
// on, and the classification below is how a reader tells the two eras apart honestly.

import Foundation

/// The device a capture is being recorded FROM, resolved ONCE by the composition root.
///
/// Nothing that opens a capture is asked to discover this. `OmiRestorationSpool` in
/// particular runs during a background relaunch where the account scope may not be
/// resolvable at all, and a type that discovers its own identity has no way to say "I
/// could not" — it can only guess, and a guessed device identity written into a user's
/// archive is worse than no capture at all.
public struct CaptureDeviceContext: Codable, Equatable, Sendable {
    /// Shape + hardware token. BOTH halves matter: matching on the token alone would let a
    /// device that presents the same token under a different shape inherit a conversation.
    public let identity: RecordingDeviceIdentity
    /// What to call it in the archive. Display only — never an identity.
    public let displayName: String
    /// The account scope that owned the capture, at the moment it was written.
    ///
    /// PROVENANCE METADATA, NOT A CHECK (review finding L2). An earlier comment here claimed
    /// it existed "so a record cannot be read across accounts without noticing" — nothing
    /// notices: `mayContinue` compares identity only and `provenance` never looks at it. It
    /// is recorded because a reader investigating an archive needs to know whose it was, and
    /// it is asserted at write time. Making it a real gate means deciding what a disagreement
    /// with the reading container SHOULD do to a user's capture, which is an account-boundary
    /// policy question T5/T6 own — not something to smuggle in as a silent skip here.
    public let accountScope: String

    public init(identity: RecordingDeviceIdentity, displayName: String, accountScope: String) {
        self.identity = identity
        self.displayName = displayName
        self.accountScope = accountScope
    }

    public var shape: RecordingDeviceShape { identity.shape }
    public var deviceId: String { identity.hardwareToken }
}

/// WHAT IS ACTUALLY RECORDING, asked of the capture that is opening rather than of the
/// handset's address book.
///
/// THE BUG THIS TYPE EXISTS TO MAKE IMPOSSIBLE. The first version of the composition root
/// answered *"which device does this handset remember"* and wrote that into every capture —
/// so a phone-mic recording made while an Omi was paired was recorded in the archive as
/// having been made BY the Omi. The capture directory contradicted itself (`.capture-source`
/// said `phoneMic`, the device record said `bleStream/<omi-uuid>`), it contradicted the
/// running app (the live surface already said "Phone"), and it was durable: every such
/// conversation carried a false recorder forever after. "Which device does this handset
/// remember" and "which device made this conversation" are different questions, and only one
/// of them belongs in the archive.
public enum CaptureRecordingSource: Equatable, Sendable {
    /// The handset's own microphone (the Record button, the Action Button, the Siri intent).
    case handsetMicrophone
    /// A Bluetooth audio INPUT ROUTE the handset is recording from.
    case handsetAudioRoute(token: String, displayName: String)
    /// An external device streaming encoded frames to the handset — the remembered BLE device.
    case externalStream

    var shape: RecordingDeviceShape {
        switch self {
        case .handsetMicrophone: return .builtInMic
        case .handsetAudioRoute: return .audioRoute
        case .externalStream: return .bleStream
        }
    }
}

/// The composition root's answer. `blocked` is a first-class outcome, not an error case to
/// be swallowed: the caller must defer capture rather than record audio it cannot attribute.
public enum CaptureDeviceContextResolution: Equatable, Sendable {
    case resolved(CaptureDeviceContext)
    case blocked(reason: String)

    public var context: CaptureDeviceContext? {
        if case .resolved(let c) = self { return c }
        return nil
    }

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// What a reader can honestly say about which device recorded a capture.
///
/// The three non-identified cases are deliberately distinct. Collapsing them into "unknown"
/// would tell a user whose entire archive predates this release that every one of their
/// conversations lost its device — which is false, and alarming, and unfixable by them.
public enum CaptureDeviceProvenance: Equatable, Sendable {
    /// A device record exists. This is the answer.
    case identified(CaptureDeviceContext)
    /// Recorded before device records shipped. Its `.capture-source` attribution is correct
    /// and complete for what it is; nothing is missing.
    case legacyPreMigration
    /// Recorded after device records shipped, and has none. Genuinely unknown — the record
    /// failed to write or the identity was blocked. A surface should say so.
    case unknownPostMigration(diagnostic: String)
    /// Neither durable metadata nor the capture id can date it, so which era it belongs to
    /// is not knowable. Takes the LEGACY reading — never guessed post-migration, because
    /// guessing that direction invents a missing record that may never have been owed.
    case undatable(diagnostic: String)
    /// A device record IS there and cannot be read. A THIRD state, not a flavour of the
    /// other two (review round 9, L2 / round 8, L4).
    ///
    /// WHY IT IS ITS OWN CASE. `load` used to swallow a decode failure with `try?` and return
    /// `nil`, so a truncated write, a bad sector, or a half-restored backup arrived at the
    /// "there is no record" arm — which says *"nobody wrote one"* (either era, depending on
    /// the date) and, worse, hands the resume gate the answer *"anyone may continue this"*.
    /// Both are false: someone DID write one, it names exactly one device, and we cannot read
    /// which. In a type whose whole design is that "I could not answer" must be a value, a
    /// silent third state is the one thing it may not have.
    case unreadableRecord(diagnostic: String)
}

/// What is actually on disk where a capture's device record goes.
///
/// Three states, because there are three. Absence and unreadability lead to different
/// answers everywhere they are consulted, and folding them together is what made the
/// unreadable case invisible.
public enum CaptureDeviceRecordRead: Equatable, Sendable {
    case present(CaptureDeviceContext)
    /// No record file at all.
    case absent
    /// A record file exists and could not be turned into a record.
    case unreadable(diagnostic: String)
}

public enum CaptureDeviceSidecar {

    /// The sidecar file, beside the capture's segments.
    public static let fileName = ".capture-device.json"

    /// The instant device records began being written **in a build a user can have**.
    ///
    /// WHY A FIXED CONSTANT. Deriving it at runtime — a build date, a first-launch stamp —
    /// would classify the same archive differently on two handsets, which is the one thing a
    /// provenance answer may not do.
    ///
    /// WHY *THIS* CONSTANT, AND THE HONEST COST. My first value was the day the code was
    /// written (2026-07-28T00:00:00Z), and that was wrong in the direction this type exists
    /// to prevent (review finding M2): the release ships AFTER the code is written, so every
    /// conversation a user records on the CURRENT shipped build between the write date and
    /// their upgrade would be classified `unknownPostMigration` — "made after device records
    /// shipped but carries none" — which is false, for exactly the reason the case exists.
    ///
    /// The choice made here is the first of the reviewer's two options: **pin it at the
    /// release timestamp**, deliberately LATE rather than early, and put it on the ship
    /// checklist. Late is the safe direction: a capture made just after the real cutover and
    /// before this instant reads `legacyPreMigration` — "recorded before the upgrade" —
    /// which understates what we know but never invents a missing record. Early is the
    /// unsafe direction: it accuses correct captures of having lost their identity.
    ///
    /// **SHIP CHECKLIST — this value must be moved to the release build's timestamp before
    /// the build that first writes device records reaches a user.** Until then it is set to
    /// a deliberately late placeholder (2026-09-01T00:00:00Z). Its false-classification
    /// window while it stays late: captures recorded by an upgraded user between their
    /// upgrade and this instant read `legacyPreMigration` instead of `identified`/`unknown`
    /// — they still carry their real `.capture-device.json` when one was written, so
    /// `provenance` returns `.identified` for them regardless and the epoch is never
    /// consulted. The window therefore only affects captures that have NO record, where
    /// "recorded before the upgrade" is the conservative reading.
    ///
    /// The alternative — keying to the build that first writes records — was not taken: it
    /// reintroduces per-handset variance (two users on different builds classify the same
    /// synced archive differently), which is the property the constant exists to hold.
    public static let migrationEpoch: UInt64 = 1_788_220_800

    /// PD-ARCHIVE-IDENTITY's wire-stable mapping, in one place so a reader can check the
    /// device record against the shipped `.capture-source` marker rather than trusting that
    /// they were written from the same belief: `.bleStream -> "omi"`,
    /// `.audioRoute`/`.builtInMic -> "phoneMic"`.
    public static func sourceMarker(for shape: RecordingDeviceShape) -> String {
        switch shape {
        case .bleStream: return CaptureSourceKind.omi.rawValue
        case .audioRoute, .builtInMic: return CaptureSourceKind.phoneMic.rawValue
        }
    }

    public static func url(_ captureId: String, baseDir: URL) -> URL {
        baseDir.appendingPathComponent(captureId, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Write the record. Returns whether it landed — a caller that needs the capture to be
    /// attributable can act on `false` rather than discovering it later.
    @discardableResult
    public static func write(_ context: CaptureDeviceContext,
                             captureId: String, baseDir: URL) -> Bool {
        let target = url(captureId, baseDir: baseDir)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(context).write(to: target, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// The full three-state answer. Everything that consults the record goes through here.
    public static func read(captureId: String, baseDir: URL) -> CaptureDeviceRecordRead {
        let target = url(captureId, baseDir: baseDir)
        guard FileManager.default.fileExists(atPath: target.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            return .unreadable(diagnostic:
                "this recording's device record could not be read from disk "
                    + "(\(error.localizedDescription))")
        }
        guard !data.isEmpty else {
            return .unreadable(diagnostic:
                "this recording's device record is empty — the write did not complete")
        }
        do {
            return .present(try JSONDecoder().decode(CaptureDeviceContext.self, from: data))
        } catch {
            return .unreadable(diagnostic:
                "this recording's device record could not be understood "
                    + "(\(error.localizedDescription))")
        }
    }

    /// The record, or `nil` when there is nothing readable there. Callers that must tell an
    /// ABSENT record from an UNREADABLE one use `read` — this is the convenience for the ones
    /// that only need the context itself.
    public static func load(captureId: String, baseDir: URL) -> CaptureDeviceContext? {
        if case .present(let context) = read(captureId: captureId, baseDir: baseDir) {
            return context
        }
        return nil
    }

    /// The durable start of a capture, in Unix seconds.
    ///
    /// FILESYSTEM DATES ARE FORBIDDEN HERE, and not as a style rule. Restoring from a
    /// backup, migrating to a new handset, or materialising an offloaded file all rewrite
    /// mtime — so an mtime-dated classification would relabel a user's entire pre-upgrade
    /// archive as "device record missing" the first time they got a new phone. Both sources
    /// below travel WITH the data: the conversation's own durable metadata, and failing
    /// that the timestamp embedded in the capture id itself.
    static func durableStart(captureId: String, baseDir: URL) -> UInt64? {
        if let meta = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir),
           meta.startedAt > 0 {
            return meta.startedAt
        }
        return CaptureIdTime.startedAt(fromCaptureId: captureId)
    }

    public static func provenance(captureId: String, baseDir: URL,
                                  migrationEpoch: UInt64 = migrationEpoch) -> CaptureDeviceProvenance {
        switch read(captureId: captureId, baseDir: baseDir) {
        case .present(let context):
            return .identified(context)
        case .unreadable(let diagnostic):
            // NOT dated, NOT guessed. A capture whose record is corrupt is post-migration by
            // construction — the record only exists in that era — so the epoch has nothing to
            // add, and neither of the two "no record" answers is true about it.
            return .unreadableRecord(diagnostic: diagnostic)
        case .absent:
            break
        }
        guard let started = durableStart(captureId: captureId, baseDir: baseDir) else {
            return .undatable(diagnostic:
                "this recording carries no durable start and no dated id, so whether it "
                    + "predates device records is not knowable; it is read as pre-upgrade")
        }
        guard started >= migrationEpoch else { return .legacyPreMigration }
        return .unknownPostMigration(diagnostic:
            "this recording was made after device records shipped but carries none — the "
                + "device that made it was not resolvable when it opened")
    }

    /// May a device continue this capture?
    ///
    /// THE WIDENING IS GATED ON THE RECORD EXISTING, which is the plan's rule and the only
    /// safe one: a capture with no record cannot answer the question, and refusing it would
    /// fragment exactly the conversations this track exists to keep whole. So the answer is
    /// yes for every era except the one where we KNOW the answer and it is a different
    /// device.
    ///
    /// AN UNREADABLE RECORD IS REFUSED, and it is the one place the two "cannot answer"
    /// states diverge. An ABSENT record means nobody ever claimed this conversation, so the
    /// shipped un-narrowed rule is the honest one. An UNREADABLE record means exactly one
    /// device claimed it and we cannot tell which — so "anyone may continue" is a coin flip
    /// on whether a second device's audio gets appended to the first device's conversation,
    /// which is the precise failure the record exists to prevent. Refusing costs one
    /// conversation split in two, honestly; allowing costs one conversation that is a lie.
    static func mayContinue(captureId: String, baseDir: URL,
                            device: RecordingDeviceIdentity?) -> Bool {
        // No resuming identity ⇒ the caller cannot be narrowed at all and the shipped rule
        // applies, exactly as before.
        guard let device else { return true }
        switch read(captureId: captureId, baseDir: baseDir) {
        case .present(let recorded): return recorded.identity == device
        case .absent: return true
        case .unreadable: return false
        }
    }
}
