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
    /// The account scope that owned the capture, so a record cannot be read across accounts
    /// without noticing.
    public let accountScope: String

    public init(identity: RecordingDeviceIdentity, displayName: String, accountScope: String) {
        self.identity = identity
        self.displayName = displayName
        self.accountScope = accountScope
    }

    public var shape: RecordingDeviceShape { identity.shape }
    public var deviceId: String { identity.hardwareToken }
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
}

public enum CaptureDeviceSidecar {

    /// The sidecar file, beside the capture's segments.
    public static let fileName = ".capture-device.json"

    /// The instant device records began being written (2026-07-28T00:00:00Z).
    ///
    /// A capture that STARTED before this could not have been given a record, so its absence
    /// is expected rather than a fault. This is a fixed constant on purpose: deriving it
    /// from anything observable at runtime (a build date, a first-launch stamp) would make
    /// the same archive classify differently on two handsets.
    public static let migrationEpoch: UInt64 = 1_785_196_800

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

    public static func load(captureId: String, baseDir: URL) -> CaptureDeviceContext? {
        guard let data = try? Data(contentsOf: url(captureId, baseDir: baseDir)),
              !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(CaptureDeviceContext.self, from: data)
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
        if let context = load(captureId: captureId, baseDir: baseDir) {
            return .identified(context)
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
    static func mayContinue(captureId: String, baseDir: URL,
                            device: RecordingDeviceIdentity?) -> Bool {
        guard let device,
              let recorded = load(captureId: captureId, baseDir: baseDir) else { return true }
        return recorded.identity == device
    }
}
