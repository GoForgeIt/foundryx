// PocketSessionKeyEntry.swift — THE OWNER HANDS OVER A KEY THEY ALREADY HAVE.
//
// WHAT WAS MISSING. `RecordingDeviceAttachment` wired the adoption chain end to end and it
// stops at one link: FoundryX can RESTORE a session key it already holds and it may not MINT
// one, because DESIGN-pocket-connect.md §3.6 / T2 req 3 hold `provisionFactoryFresh` shut
// until an evidenced firmware key alphabet and a security-reviewed entropy policy exist. So
// every real tap on a stored-file recorder returns `.setupUnavailable`.
//
// An owner whose recorder was already provisioned by ANOTHER app is not waiting on any of
// that. They hold the key. `PocketOnboarding.saveSecret` — validated, fingerprinted,
// Keychain-backed — is the seam that would accept it, and it had no UI. This file is that
// path, and it is the difference between a chain that is complete and a chain that reaches.
//
// IT DOES NOT OPEN THE MINTING GATE. `provisionFactoryFresh` still has no caller here or
// anywhere else in `App/` or non-test `Sources/`. Nothing in this file generates a key,
// derives one, or offers to. It takes one the human already possesses, checks it against the
// SHIPPED predicate, puts it in the SHIPPED custody seam, and re-runs the SHIPPED chain.
//
// IT DOES NOT FORK THE CHAIN. The attach leg is `RecordingDeviceAttachment.attach` verbatim —
// the same radio flow, the same characteristic negotiation, the same `PocketBLEClient`, the
// same `PocketOnboardingCoordinator.restore`, the same `PocketRecordingDeviceBridge.observe`,
// the same `RecordingDeviceAdoption.remember`. Once the key is in custody, restore succeeds
// for exactly the reason it succeeds for a recorder FoundryX provisioned itself. That is the
// whole design: the key was the missing input, not a missing code path.
//
// THE KEY IS A CREDENTIAL AND IT IS TREATED AS ONE. It reaches the Keychain seam and the
// recorder's own characteristic and NOTHING else. It is not in a log line, not in an error
// case's payload, not in an outcome's description, not in a diagnostic. Every rejection here
// is a value the presentation words; none of them carries the candidate. That is why
// `PocketSessionKeyDefect.wrongLength` carries a COUNT and not the string it counted.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// What entering a key actually accomplished.
///
/// NOTE WHAT NO CASE CARRIES: the key. Not as an associated value, not in a reason string.
/// `String(describing:)` of any of these is safe to print, and the credential-hygiene gate
/// asserts exactly that.
public enum PocketSessionKeyEntryOutcome: Equatable, Sendable {
    /// Custody kept it, the recorder accepted it, and the account now remembers the device.
    case adopted(identity: RecordingDeviceIdentity,
                 displayName: String,
                 negotiatedProtocol: String)
    /// Refused before a transport existed. The app sent the recorder zero bytes.
    case malformed(PocketSessionKeyDefect)
    /// The handshake ran and the recorder answered something other than `MCU&SK&OK`.
    /// DISTINCT FROM `.linkFailed` by construction — the link was fine.
    case refusedByRecorder
    /// The recorder was never reached, or stopped answering mid-handshake.
    case linkFailed(String)
    /// The Keychain would not keep the key, so it was never offered to the recorder either.
    case keyNotKept
    /// The key worked and the account store could not keep the result.
    case notRemembered(String)
    /// The tapped device does not speak the stored-file protocol at all.
    case notARecorder
}

extension PocketSessionKeyEntryPresentation {
    /// The line an outcome earns, or `nil` for `.adopted`, which closes the screen rather than
    /// saying anything.
    public static func line(for outcome: PocketSessionKeyEntryOutcome) -> String? {
        switch outcome {
        case .adopted:                return nil
        case .malformed(let defect):  return line(for: defect)
        case .refusedByRecorder:      return refusedByRecorderLine
        case .linkFailed:             return linkFailedLine
        case .keyNotKept:             return keyNotKeptLine
        case .notRemembered:          return notRememberedLine
        case .notARecorder:           return notARecorderLine
        }
    }
}

/// One submitted key's worth of work: judge it, keep it, then run the shipped chain.
///
/// `attach` is the SEAM AND THE ONLY ONE. In the app it builds a real
/// `RecordingDeviceAttachment` over CoreBluetooth; under test it builds the same real
/// `RecordingDeviceAttachment` over the fake BLE stack. Neither is a reimplementation of the
/// chain, which is what makes a passing scenario evidence about the app.
public actor PocketSessionKeyEntryCoordinator {

    public typealias Attach = @Sendable (UUID, String) async -> RecordingDeviceAttachOutcome

    private let secrets: any PocketSecretStore
    private let attach: Attach

    public init(secrets: any PocketSecretStore, attach: @escaping Attach) {
        self.secrets = secrets
        self.attach = attach
    }

    /// The composition the app uses. A fresh `RecordingDeviceAttachment` per submission,
    /// because each one owns and tears down its own central.
    public static func live(
        secrets: any PocketSecretStore = KeychainPocketSecretStore(),
        makeCentral: @escaping @Sendable (BLEEventSink, DispatchQueue, String?) -> BLECentral
            = CoreBluetoothCentral.make,
        deadlines: RecordingDeviceAttachment.Deadlines = .init(),
        log: DoorLog? = nil
    ) -> PocketSessionKeyEntryCoordinator {
        PocketSessionKeyEntryCoordinator(secrets: secrets) { id, name in
            let attachment = RecordingDeviceAttachment(
                makeCentral: makeCentral, secrets: secrets, deadlines: deadlines, log: log)
            return await attachment.attach(peripheralIdentifier: id, advertisedName: name)
        }
    }

    /// - Parameter key: the 16-character session key the owner captured from an HCI trace.
    ///   It is used here and never retained, copied into a message, or logged.
    public func submit(key: String,
                       peripheralIdentifier id: UUID,
                       advertisedName: String) async -> PocketSessionKeyEntryOutcome {
        // ── 1. THE REFUSAL THAT COSTS THE RECORDER NOTHING ──────────────────────────────
        // Before a central is created, before a peripheral is retrieved, before a transport
        // exists. A malformed candidate cannot reach the radio because at this point in the
        // function there is no radio: the app has, literally, nowhere to send it.
        if let defect = PocketSessionKey.defect(in: key) {
            return .malformed(defect)
        }
        let secret = PocketSessionKey.normalised(key)

        guard let identity = try? PocketAuthenticatedIdentity(peripheralIdentifier: id.uuidString)
        else {
            return .linkFailed("this device has no usable durable identity")
        }

        // ── 2. CUSTODY FIRST, THROUGH THE SHIPPED SEAM ──────────────────────────────────
        // `PocketSecretStore.save` re-checks the same predicate and fingerprints the value.
        // The key exists in this process as a parameter and in the Keychain, and in no third
        // place. If custody will not keep it, the recorder is never asked — an app that
        // authenticates with a key it cannot store is an app that works exactly once.
        do {
            try await secrets.save(secret, for: identity)
        } catch {
            return .keyNotKept
        }

        // ── 3. THE EXISTING CHAIN, RE-RUN VERBATIM ──────────────────────────────────────
        // Nothing below is new. With the key in custody, `restore` finds it and the rest of
        // the chain is the same one the unified-list track proved end to end.
        switch await attach(id, advertisedName) {
        case .adopted(let identity, let displayName, let negotiatedProtocol):
            return .adopted(identity: identity,
                            displayName: displayName,
                            negotiatedProtocol: negotiatedProtocol)

        case .recoveryRequired:
            // The recorder answered the handshake and did not accept this key. `restore`
            // reserves this state for `MCU&SK&OK` that never came; a link that died mid
            // handshake comes back `.unreachable` instead, which is what keeps these two
            // answers from collapsing into one another.
            //
            // AND THE KEY COMES BACK OUT OF CUSTODY. It had to go IN first — `restore` reads
            // custody to decide what to send, so there is no way to ask the recorder about a
            // key it is not holding. Now the recorder has said no, and leaving a key the
            // hardware rejected in the Keychain is worse than never having stored it: every
            // later tap restores THAT key, is refused again, and comes back
            // `.recoveryRequired` rather than `.setupUnavailable` — so the person who
            // mistyped one character would keep re-entering a key that is never consulted.
            await forget(identity)
            return .refusedByRecorder

        case .unreachable(let reason):
            // The key is KEPT. Nothing here says it is wrong; the recorder was never reached
            // to have an opinion, and making someone retype 16 characters because their
            // recorder walked out of range is the same collapse `.refusedByRecorder` exists
            // to prevent, one layer down.
            return .linkFailed(reason)

        case .adoptionNotPersisted(let reason):
            // The key WORKED. The account store is what failed, so custody keeps it.
            return .notRemembered(reason)

        case .setupUnavailable, .keyNotKept, .custodyUnreadable:
            // The key was saved a moment ago and custody still could not produce it for this
            // identity — it was not kept, or it could not be read back. Either way this is a
            // storage failure and is said as one, rather than as the §3.6 screen the person
            // just came from. Nothing was written to the recorder on any of these.
            return .keyNotKept

        case .live, .unrecognised:
            // Not a stored-file recorder at all, so the key it was given belongs to something
            // else. Holding a credential against a device that can never use it is custody
            // keeping a secret for no one.
            await forget(identity)
            return .notARecorder

        case .mintRefused, .mintNotVerified, .keyAcceptedNotDurable:
            // UNREACHABLE BY CONSTRUCTION, AND NOT SILENTLY. `attach` mints only when it is
            // handed a `PocketMintConsent`, and this path never passes one — entering a key
            // one already has is the opposite of minting a new one. If one of these ever
            // arrives here, the entry path has grown a minting branch, and the honest report
            // is that this key's fate is unknown rather than a confident sentence about it.
            return .linkFailed("this recorder's setup did not finish")
        }
    }

    /// Best effort by design. The caller is already returning a refusal; a Keychain that also
    /// will not delete cannot make that refusal any more true, and there is no second thing to
    /// tell the person. What it must never do is throw past the answer they are waiting for.
    private func forget(_ identity: PocketAuthenticatedIdentity) async {
        try? await secrets.remove(for: identity)
    }
}

#endif
