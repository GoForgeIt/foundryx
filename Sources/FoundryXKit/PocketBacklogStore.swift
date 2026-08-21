// PocketBacklogStore.swift — THE DRAIN'S INTENT, SURVIVING THE PROCESS THAT FORMED IT.
//
// `20260821T0153_the_drain_survives_termination` Phase 1. `PocketTransferQueue` holds its
// population, the owner's stops and each recording's attempt count as `private var` on the actor
// (`PocketTransferJob.swift:250-265`). iOS terminates the app and all three are gone: the backlog
// is silently forgotten, and — worse — a recording the owner explicitly STOPPED comes back,
// because the queue re-derives itself from the shelf and nothing remembers the refusal.
//
// The comment on `stoppedRequests` reads "THE OWNER'S STOPS, DURABLY SUPPRESSED". It is an
// in-memory `Set`. The claim was about the re-derivation within one session, and it reads as a
// claim about durability. This file is what makes the word true.
//
// WHY ITS OWN FILE, AND NOT `RecordingDeviceStore`. That store was the obvious home —
// `autoClearArmedAt` is a per-device durable fact and lives there. But `autoClearArmedAt` is ONE
// TIMESTAMP, and a backlog is unbounded operational state on a hot path. `RecordingDeviceStore`
// decodes its whole JSON array on every read and rewrites the whole file on every mutation, and a
// single decode failure makes the WHOLE store unreadable — which would put PAIRING in the blast
// radius of one corrupt queue element. A cross-vendor review of the plan named this and it was
// changed before a line was written.
//
// FAIL SOFT, AND SAY WHICH WAY. `RecordingDeviceStore.autoClear` fails CLOSED with a reason worth
// repeating: "the failure mode of guessing wrong in the other direction is a recording removed
// from the only device holding it." The same asymmetry applies here and points the same way. An
// unreadable backlog yields NO automatic drain — never "drain everything" — and pairing is
// untouched. A drain that does not start is an inconvenience; a drain that starts from a corrupt
// intent is a radio running against a recorder nobody asked it to empty.

import Foundation

/// One recording's place in a drain that has to outlive the app.
public struct PocketBacklogEntry: Codable, Sendable, Equatable {
    public let date: String
    public let timestamp: String
    public let sizeBytes: Int
    /// How many attempts this recording has already spent. Persisted because the budget is
    /// per-recording, and re-reading it as zero on every launch would make the bound meaningless.
    public var attempts: Int
    /// THE OWNER SAID NO. Kept in the same record as the recording rather than in a parallel set,
    /// so a stop cannot be separated from the thing it refers to by a partial write.
    public var stopped: Bool

    public init(date: String, timestamp: String, sizeBytes: Int,
                attempts: Int = 0, stopped: Bool = false) {
        self.date = date
        self.timestamp = timestamp
        self.sizeBytes = sizeBytes
        self.attempts = attempts
        self.stopped = stopped
    }

    public var request: PocketRecordingRequest {
        PocketRecordingRequest(date: date, timestamp: timestamp)
    }

    public var recording: PocketRecording {
        PocketRecording(date: date, timestamp: timestamp, sizeBytes: sizeBytes)
    }
}

/// What one recorder's drain intends, as a value that can be written and read back.
public struct PocketBacklog: Codable, Sendable, Equatable {
    /// Bumped when the shape changes. An unrecognised version is treated as unreadable, which
    /// means NO automatic drain — not a best-effort decode of fields that may have moved.
    public static let currentVersion = 1

    public var version: Int
    public var entries: [PocketBacklogEntry]
    /// The owner's stop-everything intent, which outranks every entry.
    public var stopEverything: Bool

    public init(entries: [PocketBacklogEntry] = [], stopEverything: Bool = false) {
        self.version = Self.currentVersion
        self.entries = entries
        self.stopEverything = stopEverything
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// What a drain may take: everything not stopped. **A stopped recording is never returned**,
    /// which is the whole point of persisting the stop.
    public var drainable: [PocketRecording] {
        entries.filter { !$0.stopped }.map(\.recording)
    }
}

/// WHY A DRAIN IS NOT STARTING, as a value rather than a silent `nil`.
///
/// Three outcomes, and the middle one is the reason this is not `PocketBacklog?`: "nothing to do"
/// and "I could not read what to do" are opposite states that a nil would collapse. The first is
/// success; the second must be visible or an unreadable file looks exactly like an empty queue.
public enum PocketBacklogReadout: Sendable, Equatable {
    /// Read cleanly. May still be empty — that is a real answer.
    case backlog(PocketBacklog)
    /// A file exists and could not be decoded. **No automatic drain.** Pairing is unaffected.
    case unreadable(because: String)
    /// No file. A recorder nothing has ever drained.
    case none
}

/// One recorder's backlog on disk, in a file of its own.
public struct PocketBacklogStore: Sendable {
    /// nil means "resolve through the account scope, every time" — never a captured path.
    private let injectedRoot: URL?

    /// ACCOUNT-SCOPED, AND THE FIRST VERSION WAS NOT.
    ///
    /// It defaulted to `applicationSupportDirectory`, and `AccountDataIsolationFeatureTests`
    /// failed with "User-private durable paths must resolve through CaptureAccountScope." The
    /// gate was right: a backlog NAMES somebody's recordings by day and instant, so two accounts
    /// on one device would have shared one queue. It is user-private for exactly the reason the
    /// audio is.
    ///
    /// RESOLVED PER CALL rather than captured at construction, because the account can change
    /// under a long-lived store and a captured root would keep writing to the previous
    /// account's directory.
    public init(root: URL? = nil) { self.injectedRoot = root }

    private var root: URL {
        injectedRoot ?? CaptureAccountScope.privateURL(for: .pocketBacklogs)
    }

    /// One file per recorder, named by the device's own storage key — the same scoping custody
    /// uses, so two recorders reporting the same day and timestamp cannot collide.
    ///
    /// **`storageKey` CONTAINS A PATH SEPARATOR** (`filePull/PKT01-…`), which is why every write
    /// creates the file's own parent rather than just `root`. The first version created `root`
    /// only and every write failed with a mktemp error that named a temporary file rather than
    /// the missing directory — a misleading error for a trivial cause.
    public func url(for identity: RecordingDeviceIdentity) -> URL {
        root.appendingPathComponent("\(identity.storageKey).json")
    }

    /// Read the intent. **Never throws**: every failure is a readout the caller can act on.
    public func read(for identity: RecordingDeviceIdentity) -> PocketBacklogReadout {
        let file = url(for: identity)
        guard FileManager.default.fileExists(atPath: file.path) else { return .none }
        guard let data = try? Data(contentsOf: file) else {
            return .unreadable(because: "the backlog file could not be opened")
        }
        guard let decoded = try? JSONDecoder().decode(PocketBacklog.self, from: data) else {
            return .unreadable(because: "the backlog file did not decode")
        }
        // A VERSION FROM THE FUTURE IS NOT A BACKLOG. Decoding it field-by-field would be
        // guessing at a shape somebody else defined.
        guard decoded.version == PocketBacklog.currentVersion else {
            return .unreadable(because:
                "the backlog is version \(decoded.version); this build reads "
                    + "\(PocketBacklog.currentVersion)")
        }
        return .backlog(decoded)
    }

    /// Write the intent. Atomic, because a half-written backlog read on the next launch is the
    /// `.unreadable` case — safe, but it would lose a real queue for no reason.
    public func write(_ backlog: PocketBacklog, for identity: RecordingDeviceIdentity) throws {
        let file = url(for: identity)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(backlog)
        try data.write(to: file, options: .atomic)
    }

    /// Forget one recorder's backlog entirely — used when a recorder is unpaired, never as a
    /// recovery from a read failure. **An unreadable file is kept**, because deleting it destroys
    /// the evidence of whatever went wrong.
    public func forget(_ identity: RecordingDeviceIdentity) {
        try? FileManager.default.removeItem(at: url(for: identity))
    }
}
