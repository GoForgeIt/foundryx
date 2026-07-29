// OmiRestorationComposition — the composition root for a background-restoration spool,
// LIVING IN THE KIT rather than in `App/`.
//
// WHY IT IS HERE AND NOT IN THE APP DELEGATE. `swift test` compiles only the SwiftPM
// package; the hostless iOS test target does not build `App/` either. Composition that
// lives in `FoundryXAppDelegate` is therefore, structurally, code no test can execute — and
// the composition is exactly where the device identity is resolved and handed to the thing
// that writes it into the user's archive. Putting it in the Kit is what makes the boundary
// falsifiable: omitting the context here reds a feature, instead of compiling silently in a
// file the test bundle cannot see.
//
// The AppDelegate keeps what only it can do — reading the bundle's remote-log config,
// owning the shared DeviceManager, registering the account-exposure participant — and calls
// this for the rest.

import Foundation

public enum OmiRestorationComposition {

    /// Resolve WHICH device a background restoration is about to record from.
    ///
    /// FAILS LOUD, BY TYPE. Both inputs can legitimately be absent during a background
    /// relaunch — the account container may not be resolvable before first unlock, and
    /// there may be no remembered device at all — and neither absence may be papered over.
    /// A placeholder identity written into a capture directory is indistinguishable from a
    /// real one forever after, so the answer is `blocked` and the caller defers.
    /// A stable token for the handset's own input. It names a role, not a serial: there is
    /// exactly one built-in microphone per handset, the account scope already says whose
    /// handset it is, and putting anything device-identifying here would hand the archive a
    /// correlator the privacy work exists to withhold.
    public static let handsetToken = "handset"
    public static let handsetDisplayName = "Phone"

    /// WHY THERE IS NO ACTIVE DEVICE — a value, not a sentence.
    ///
    /// There are five genuinely different ways to have no active recording device, and a
    /// consumer has to be able to tell them apart: "this account remembers nothing" is an
    /// onboarding state, "remembers some but none is attached" is a reconnect state, "the one
    /// attached is one you detached" is a user decision, and "the store could not be read" is
    /// a fault that must never be reported as any of the other four. Collapsing them into
    /// `nil` is how "no device" and "a device we could not read" became the same event.
    ///
    /// IT IS A TYPE BECAUSE THE NEXT CONSUMER MUST BE ABLE TO `switch` (review round 11, M2).
    /// This was five free-form English strings, and the record handed them to T6 as "the
    /// substrate R3's distinction needs" — but the only way to distinguish them was to
    /// substring-match prose, and T6 has to render three of them differently against R6's
    /// three-minute bound. The sentence now lives beside the case it belongs to, so no caller
    /// invents its own wording and no caller has to parse anyone else's.
    public enum NoActiveDeviceReason: Equatable, Sendable {
        /// No account scope is resolvable at all, so there is no account-scoped memory of
        /// recording devices to choose from. Not a statement about devices.
        case noAccountScope
        /// This account has never remembered a recording device.
        case nothingRemembered
        /// This account remembers `count` devices and the transport has none of them attached.
        case rememberedButNoneAttached(count: Int)
        /// A device IS attached, and this account has explicitly detached it. A user decision,
        /// not an absence.
        case attachedButDetached
        /// The account's recording devices could not be read. NOT "no devices" — reporting it
        /// as such would silently un-pair every device the person owns.
        case storeUnreadable(redactedError: String)

        /// The sentence, kept with the case so the copy has exactly one home.
        public var sentence: String {
            switch self {
            case .noAccountScope:
                return "no account scope is resolvable, so this handset has no account-scoped "
                    + "memory of recording devices to choose from"
            case .nothingRemembered:
                return "this account remembers no recording device"
            case .rememberedButNoneAttached(let count):
                return "this account remembers \(count) recording device(s) but none is attached"
            case .attachedButDetached:
                return "the attached recording device is one this account has explicitly "
                    + "detached, so it is not active"
            case .storeUnreadable(let error):
                return "this account's recording devices could not be read (\(error))"
            }
        }

        /// TRUE only for the fault. A surface that offers "connect a device" for this is
        /// telling someone their devices are gone when they are unreadable.
        public var isFault: Bool {
            if case .storeUnreadable = self { return true }
            return false
        }
    }

    /// The ACTIVE device, and why there is not one.
    public enum ActiveDeviceResolution: Equatable, Sendable {
        case active(RecordingDeviceRecord)
        case noneActive(reason: NoActiveDeviceReason)

        public var record: RecordingDeviceRecord? {
            if case .active(let r) = self { return r }
            return nil
        }
    }

    /// THE ACCOUNT-SCOPED ANSWER, replacing the legacy single-vendor pairing (review finding
    /// L1; S05 requires attribution to follow the SELECTED ACTIVE device).
    ///
    /// READINESS COMES FROM THE TRANSPORT, NEVER FROM THE STORE, and that is what reconciles
    /// this with the lesson T4 paid for. `RecordingDeviceActivation` chooses only among READY
    /// devices, and `attached` is what the radio actually has right now — so the device this
    /// returns is necessarily one that is attached, i.e. one that can be recording. A device
    /// the user prefers but that is not attached is not ready and cannot be chosen, so
    /// "the selected active device" and "the device that is actually recording" cannot
    /// disagree here. The address book proposes; the transport disposes.
    ///
    /// The legacy pairing is adopted on the way past, idempotently. Without it a user who
    /// paired before this track would have an empty account store on first launch, their first
    /// post-upgrade conversation would resolve to nothing, and `provenance` would then accuse
    /// it of having lost a device record it was never owed.
    public static func activeExternalDevice(
        binding: CaptureAccountScope.AccountBinding?,
        attached: SavedOmi?,
        defaults: UserDefaults = .standard
    ) -> ActiveDeviceResolution {
        guard let binding else { return .noneActive(reason: .noAccountScope) }
        let store = RecordingDeviceStore(root: binding.root, scope: binding.scope)
        do {
            try RecordingDeviceMigration.adoptLegacyPairing(defaults: defaults, into: store)
            let remembered = try store.records()
            let ready: Set<RecordingDeviceIdentity> = attached.map {
                [RecordingDeviceIdentity(shape: .bleStream, hardwareToken: $0.id.uuidString)]
            } ?? []
            guard let active = RecordingDeviceActivation.active(among: remembered, ready: ready) else {
                if remembered.isEmpty { return .noneActive(reason: .nothingRemembered) }
                if ready.isEmpty {
                    return .noneActive(reason: .rememberedButNoneAttached(count: remembered.count))
                }
                return .noneActive(reason: .attachedButDetached)
            }
            return .active(active)
        } catch {
            // LOUD, not empty. An unreadable store is not "no devices" — reporting it as such
            // would silently un-pair every device the person owns and then attribute their
            // conversations to nothing.
            return .noneActive(reason: .storeUnreadable(redactedError:
                RecordingDeviceLogRedaction.redactingAccountScopes(error.localizedDescription)))
        }
    }

    public static func resolveDeviceContext(
        binding: CaptureAccountScope.AccountBinding?,
        activeDevice: ActiveDeviceResolution,
        recording: CaptureRecordingSource
    ) -> CaptureDeviceContextResolution {
        guard let binding else {
            return .blocked(reason:
                "no account scope is resolvable during this background restoration, so any "
                    + "audio recorded now could not be attributed to an owner")
        }
        switch recording {
        case .handsetMicrophone:
            // THE RECORDER IS KNOWN. A handset recording is attributable whether or not an
            // external device is remembered, and it is never attributable TO one — the
            // remembered pairing is not what is making this audio.
            return .resolved(CaptureDeviceContext(
                identity: RecordingDeviceIdentity(shape: .builtInMic,
                                                  hardwareToken: handsetToken),
                displayName: handsetDisplayName,
                accountScope: binding.scope))
        case .handsetAudioRoute(let token, let displayName):
            return .resolved(CaptureDeviceContext(
                identity: RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: token),
                displayName: displayName,
                accountScope: binding.scope))
        case .externalStream:
            // Only HERE does the remembered device answer the question, because only here is a
            // remembered device the thing that is recording.
            guard case .active(let device) = activeDevice else {
                let reason: String
                if case .noneActive(let why) = activeDevice { reason = why.sentence } else { reason = "" }
                return .blocked(reason:
                    "an external stream is recording but no device is active for this account "
                        + "(\(reason)), so this audio could not be attributed to a device")
            }
            return .resolved(CaptureDeviceContext(
                identity: device.identity,
                displayName: device.displayName,
                accountScope: binding.scope))
        }
    }

    /// Build the spool the restoration bootstrap installs, carrying the resolved context in.
    ///
    /// `deviceContext` is NOT defaulted. A default would let the boundary this factory
    /// exists to hold be crossed by omission — the mutation "omit the context at the factory
    /// boundary" would then be a change nobody has to make deliberately. Dropping it here
    /// still compiles (the spool's own parameter is optional, so a directly-constructed
    /// spool keeps its shipped behaviour) and the restoration then records conversations
    /// with no device record — which is what the feature catches.
    public static func makeRestorationSpool(
        binding: CaptureAccountScope.AccountBinding?,
        root: URL,
        executor: DispatchQueue,
        log: DoorLog?,
        silenceGap: TimeInterval,
        paused: @escaping () -> Bool,
        deviceContext: CaptureDeviceContextResolution
    ) -> OmiRestorationSpool {
        if case .blocked(let reason) = deviceContext {
            log?.warn("omi-restore: not recording — \(reason)")
        }
        return OmiRestorationSpool(
            baseDir: root,
            log: log,
            silenceGap: silenceGap,
            paused: paused,
            binding: binding,
            executor: executor,
            deviceContext: deviceContext)
    }
}
