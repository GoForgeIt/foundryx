// CaptureWidgetSnapshot — the tiny, App-Group-shared capture-state snapshot the
// home/lock-screen WidgetKit widget reads. SHARED source: compiled into BOTH the app
// target (which WRITES it on capture transitions via `CaptureWidgetSnapshotStore`) and
// the widget extension (whose `TimelineProvider` READS it). The app and widget do not
// share memory, only this App-Group container, so the contract is a small Codable
// value persisted to `UserDefaults(suiteName:)`.
//
// Keep it minimal: current capture status + the last finished conversation. NO audio
// levels arrays, NO transcripts — the widget refresh budget is tight and the timeline
// only renders a status tile.

import Foundation

#if canImport(WidgetKit) && os(iOS)
import WidgetKit
#endif

/// The minimal capture status the home-screen widget shows.
public struct CaptureWidgetSnapshot: Codable, Equatable, Sendable {
    /// The DISTINCT capture phase (RECORDING-ACTIVE / PAUSED / IDLE) — the same
    /// real-activity-derived phase the Live Activity uses, so the home widget never
    /// claims a live conversation during silence / while paused. Defaults `.idle` so an
    /// OLD snapshot written before this field existed decodes cleanly.
    public var phase: CaptureActivityPhase
    /// True while a conversation is ACTIVELY being captured (voiced now, not paused).
    public var isRecording: Bool { phase == .recordingActive }
    /// True while capture is open but paused.
    public var isPaused: Bool { phase == .paused }
    /// Human source label ("Omi" / "Phone").
    public var sourceLabel: String
    /// SF Symbol for the active source.
    public var sourceSymbol: String
    /// When the current active-voice run began (for an elapsed display). ONLY set while
    /// `.recordingActive` — nil when paused / listening, so the widget shows no running
    /// timer during silence.
    public var startedAt: Date?
    /// The most-recently finished conversation's display title (shown when idle).
    public var lastFinishedTitle: String?
    /// When that last conversation finished.
    public var lastFinishedAt: Date?
    /// When this snapshot was written — lets the widget show staleness / pick a freshness.
    public var updatedAt: Date

    public init(phase: CaptureActivityPhase = .idle,
                sourceLabel: String = "Phone",
                sourceSymbol: String = "mic.fill",
                startedAt: Date? = nil,
                lastFinishedTitle: String? = nil,
                lastFinishedAt: Date? = nil,
                updatedAt: Date = Date()) {
        self.phase = phase
        self.sourceLabel = sourceLabel
        self.sourceSymbol = sourceSymbol
        self.startedAt = startedAt
        self.lastFinishedTitle = lastFinishedTitle
        self.lastFinishedAt = lastFinishedAt
        self.updatedAt = updatedAt
    }

    /// The idle placeholder shown before any capture has happened.
    public static let idle = CaptureWidgetSnapshot()
}

/// Read/write the snapshot through the shared App Group container. Both the app and
/// the widget extension MUST be members of this App Group (entitlement) for the handoff
/// to work; if the group is missing (mis-provisioned), reads/writes silently no-op and
/// the widget shows its placeholder rather than crashing.
public enum CaptureWidgetSnapshotStore {
    /// The App Group identifier shared by the app + widget extension. Must match the
    /// `com.apple.security.application-groups` entitlement in BOTH targets.
    public static let appGroupID = "group.com.goforgeit.foundryx"

    // These are `internal`, not `private`, because the account-bound WRITE path lives in
    // CaptureAccountScope.swift. The widget extension target compiles this file but NOT
    // that one, so the binding-dependent half must stay out of here or the extension
    // fails to build — which is exactly how this shipped red once (Nick 2026-07-25).
    static let key = "foundryx.capture.widget-snapshot"
    static let activeOwnerKey = "foundryx.capture.widget-snapshot.active-owner"

    /// The snapshot and its account owner travel together. In particular, a legacy
    /// untagged `CaptureWidgetSnapshot` cannot decode as this envelope and therefore
    /// fails closed instead of exposing its last-finished title to another account.
    struct Envelope: Codable {
        let owner: String
        let snapshot: CaptureWidgetSnapshot
    }

    static let stateLock = NSLock()
    /// Test-only replacement for the App-Group suite. Access is serialized by
    /// `stateLock`; production leaves this nil.
    nonisolated(unsafe) static var injectedDefaults: UserDefaults?
    nonisolated(unsafe) static var withdrawalFaultForTesting:
        CaptureWidgetWithdrawalFault?

    static var defaults: UserDefaults? {
        injectedDefaults ?? UserDefaults(suiteName: appGroupID)
    }

    /// Proof of absence the WIDGET would see — not proof that our own cache forgot.
    ///
    /// The barrier's real question is "can the widget extension still render this
    /// account?", and neither half of the old guard answered it:
    ///
    /// * `object(forKey:)` immediately after `removeObject(forKey:)` re-reads the same
    ///   in-process CFPrefs layer the removal just mutated, so it CANNOT disagree. It
    ///   read as a durability check and was a tautology.
    /// * `synchronize()` has been deprecated since iOS 12. Its Bool says one flush
    ///   completed, not that the widget's container changed — and on 2026-08-12 it
    ///   returned false on a real device whose group domain was perfectly readable
    ///   (the branch is only reachable AFTER a successful read), turning
    ///   "delete everything" into exposureBarrierFailed at step 2 of 13, forever.
    ///
    /// So ask the daemon for the group domain instead: `CFPreferencesCopyValue` after
    /// `CFPreferencesAppSynchronize` round-trips through cfprefsd, the same daemon the
    /// widget extension reads through. On a device whose container genuinely cannot be
    /// written, the old value comes back and withdrawal still fails — the gate keeps
    /// its teeth and loses its false positive.
    static func groupValueStillPresent(_ name: String) -> Bool {
        if withdrawalFaultForTesting == .absenceProbeSurvives { return true }
        if let injectedDefaults { return injectedDefaults.object(forKey: name) != nil }
        CFPreferencesAppSynchronize(appGroupID as CFString)
        return CFPreferencesCopyValue(
            name as CFString,
            appGroupID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost) != nil
    }

    /// The last snapshot the app wrote, or `.idle` when none exists yet / the group is
    /// unavailable. The envelope must belong to the currently active account.
    public static func read() -> CaptureWidgetSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let defaults,
              let activeOwner = defaults.string(forKey: activeOwnerKey),
              !activeOwner.isEmpty,
              let data = defaults.data(forKey: key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.owner == activeOwner
        else { return .idle }
        return envelope.snapshot
    }

    /// Bind future widget snapshots to an opaque account owner. Every identity
    /// transition first withdraws the prior owner and then clears its payload, including
    /// sign-out (`nil`), so new writes fail closed throughout an account switch.
    public static func transition(toOwner owner: String?) {
        stateLock.lock()
        if let defaults {
            defaults.removeObject(forKey: activeOwnerKey)
            defaults.removeObject(forKey: key)
            if let owner, !owner.isEmpty {
                defaults.set(owner, forKey: activeOwnerKey)
            }
            // This boundary is consumed by another process (the widget), so make
            // the withdrawal/rebind visible before activation is published.
            _ = defaults.synchronize()
        }
        stateLock.unlock()
        reloadWidgetTimelines()
    }

    /// Publish the already-resolved current scope without manufacturing an identity
    /// transition. This covers first use of the signed-out on-device scope and locked
    /// restoration. A mismatched prior owner is withdrawn and cleared before rebinding;
    /// a matching owner preserves its current snapshot.
    static func publishActiveOwner(_ owner: String) {
        stateLock.lock()
        var changed = false
        if let defaults,
           defaults.string(forKey: activeOwnerKey) != owner {
            defaults.removeObject(forKey: activeOwnerKey)
            defaults.removeObject(forKey: key)
            defaults.set(owner, forKey: activeOwnerKey)
            _ = defaults.synchronize()
            changed = true
        }
        stateLock.unlock()
        if changed { reloadWidgetTimelines() }
    }

    /// Hermetic-test seam: route reads and writes to a unique ephemeral suite.
    static func setDefaultsForTesting(_ defaults: UserDefaults) {
        stateLock.lock()
        injectedDefaults = defaults
        stateLock.unlock()
    }

    /// Restore production App-Group resolution after a test.
    static func resetDefaultsForTesting() {
        stateLock.lock()
        injectedDefaults = nil
        withdrawalFaultForTesting = nil
        stateLock.unlock()
    }

    static var activeOwnerForTests: String? {
        stateLock.withLock {
            defaults?.string(forKey: activeOwnerKey)
        }
    }

    /// The durable cross-process owner tag used to corroborate a cold locked
    /// restoration. Reading the tag never publishes, repairs, or clears it: a
    /// missing/mismatched App-Group handoff must remain distinguishable from proof.
    static var persistedActiveOwner: String? {
        stateLock.withLock {
            guard let owner = defaults?.string(forKey: activeOwnerKey),
                  !owner.isEmpty else {
                return nil
            }
            return owner
        }
    }

    /// Withdraw the active owner's shared widget payload and verify the deletion
    /// reached the cross-process preference domain before acknowledging it.
    public static func withdraw(
        expectedOwner: String
    ) -> CaptureWidgetWithdrawalResult {
        stateLock.lock()
        guard let defaults else {
            stateLock.unlock()
            return .persistenceFailed
        }

        let priorOwner = defaults.string(forKey: activeOwnerKey)
        let priorPayload = defaults.data(forKey: key)
        if priorOwner == nil, priorPayload == nil {
            // Corroborate against the group domain before reporting a TERMINAL SUCCESS.
            // Now that a failed withdrawal no longer restores what it removed, a second
            // attempt can read nil/nil from this process's cache while the widget's
            // container still holds both — and `.alreadyAbsent` passes the barrier. The
            // cheap in-process read stays as the fast path; the daemon settles it.
            guard groupValueStillPresent(activeOwnerKey)
                    || groupValueStillPresent(key) else {
                stateLock.unlock()
                return .alreadyAbsent
            }
        }
        if priorOwner != expectedOwner {
            // The owner tag alone is not proof: a stale tag can coexist with a
            // payload written by the account being deleted. Corroborate the
            // envelope before acknowledging that this widget belongs elsewhere.
            if let priorPayload {
                guard let envelope = try? JSONDecoder().decode(
                    Envelope.self, from: priorPayload)
                else {
                    // AN UNREADABLE PAYLOAD IS NOT AN EXPOSURE — IT IS RUBBISH, AND
                    // IT BLOCKED A REAL DELETION.
                    //
                    // This returned .persistenceFailed, which fails the barrier, so
                    // "delete everything" stopped at "Clearing the widget" and told the
                    // owner to close a widget they did not have. Nothing on the device
                    // could clear it; the only escape was reinstalling the app.
                    //
                    // The widget renders through THIS decoder. A payload it cannot
                    // decode is a payload the widget cannot draw — so these bytes are
                    // not showing anyone's account, and removing them is strictly safer
                    // than leaving them. Undecodable almost always means "written by an
                    // older build whose Envelope had a different shape", which is
                    // guaranteed to happen again on the next schema change.
                    //
                    // We cannot prove WHOSE it was, so we do not claim .withdrawn on
                    // someone else's behalf — we clear it and report success only once
                    // the slot is verifiably empty. A synchronize that does not stick
                    // is still .persistenceFailed: that is a write we could not make,
                    // not a value we could not read.
                    defaults.removeObject(forKey: key)
                    _ = defaults.synchronize()   // advisory flush, NOT the verdict
                    guard !groupValueStillPresent(key) else {
                        stateLock.unlock()
                        return .persistenceFailed
                    }
                    stateLock.unlock()
                    reloadWidgetTimelines()
                    return .withdrawn
                }
                if envelope.owner == expectedOwner {
                    guard withdrawalFaultForTesting != .synchronizeFailure else {
                        stateLock.unlock()
                        return .persistenceFailed
                    }
                    defaults.removeObject(forKey: key)
                    _ = defaults.synchronize()
                    guard !groupValueStillPresent(key) else {
                        stateLock.unlock()
                        return .persistenceFailed
                    }
                    stateLock.unlock()
                    reloadWidgetTimelines()
                    return .withdrawn
                }
            }
            stateLock.unlock()
            return .ownerMismatch
        }
        guard withdrawalFaultForTesting != .synchronizeFailure else {
            stateLock.unlock()
            return .persistenceFailed
        }

        defaults.removeObject(forKey: activeOwnerKey)
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
        // NO RESTORE ON FAILURE. This block used to write priorOwner and priorPayload
        // BACK and re-synchronize — a deletion barrier's failure path re-publishing the
        // account it had just been told to erase. That reconstructed the exact
        // precondition, so attempt N+1 was bit-identical to attempt N and "Try again"
        // could never succeed: one transient flush failure became a permanent lockout
        // whose only escape was reinstalling the app. Leaving the removal in place is
        // also strictly the safer half of the trade — the bytes we failed to PROVE gone
        // are the bytes we were asked to delete.
        guard !groupValueStillPresent(activeOwnerKey),
              !groupValueStillPresent(key) else {
            stateLock.unlock()
            return .persistenceFailed
        }
        stateLock.unlock()
        reloadWidgetTimelines()
        return .withdrawn
    }

    static func setWithdrawalFaultForTesting(
        _ fault: CaptureWidgetWithdrawalFault?
    ) {
        stateLock.lock()
        withdrawalFaultForTesting = fault
        stateLock.unlock()
    }

    private static func reloadWidgetTimelines() {
        #if canImport(WidgetKit) && os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

public enum CaptureWidgetWithdrawalResult: Sendable, Equatable {
    case withdrawn
    case alreadyAbsent
    case ownerMismatch
    case persistenceFailed
}

enum CaptureWidgetWithdrawalFault: Sendable, Equatable {
    case synchronizeFailure
    /// The removal ran, but the group domain STILL reports the value — a container
    /// that genuinely cannot be written.
    ///
    /// This exists because `.synchronizeFailure` returns BEFORE `removeObject`, so no
    /// test has ever reached the durability guard that actually failed on Nick's device
    /// on 2026-08-12. A fault that fires after the removal is the only way to prove the
    /// barrier still refuses a withdrawal it could not verify — and that a refusal no
    /// longer restores what it removed.
    case absenceProbeSurvives
}
