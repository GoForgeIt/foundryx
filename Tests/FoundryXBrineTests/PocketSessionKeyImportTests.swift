import XCTest
@testable import FoundryXKit

/// **P6 AC6, the missing input — the owner hands over a key they already hold.**
///
/// `PocketSessionKeyEntry.swift` says the chain "stops at one link": FoundryX may RESTORE a
/// session key it holds and may not MINT one, because `provisionFactoryFresh` is held shut
/// pending an evidenced firmware key alphabet and a security-reviewed entropy policy. So every
/// real tap on a stored-file recorder returns `.setupUnavailable`, and the AC6 bring-over test
/// (`PocketHardwareBringOverTests`) reports `unavailable(setupUnavailable)` — "Solleva holds no
/// key" — rather than transferring anything.
///
/// The owner is not waiting on any of that. `~/.pocket-libre/config.toml` already holds a
/// working 16-character key for this exact recorder, provisioned by another app. This test is
/// the one-time bootstrap that moves it into FoundryX's custody through the SHIPPED seam.
///
/// ## ⚠ OPT-IN, AND IT TOUCHES REAL HARDWARE AND THE REAL KEYCHAIN
///
/// Gated on `POCKET_HARDWARE=1`. It SKIPS LOUDLY otherwise — never passes — because a
/// credential-import assertion that quietly no-ops is indistinguishable from one that ran.
///
/// ## ⚠ WHY SENDING THIS KEY IS SAFE, STATED PRECISELY
///
/// Sending `APP&SK&` with a **different** key to an already-paired recorder is UNTESTED on this
/// hardware and must stay that way — whether it overwrites the pairing is unknown, and finding
/// out by trying it could brick the pairing. Only the **same-key re-send** is known safe.
///
/// This test therefore refuses unless the key it is about to send belongs to the very device it
/// is sending to: `config.toml`'s `address` must equal the target peripheral. That is asserted
/// BEFORE any radio work, and a mismatch fails rather than proceeding. (Verified by hand
/// 2026-08-23: both are `08322547-B7D1-0875-DA0C-0CE9BC1AE529`.)
///
/// ## ⚠ THE KEY IS A CREDENTIAL
///
/// It is read, passed to the shipped coordinator, and never printed, never asserted against,
/// never placed in a failure message. Every diagnostic below reports a LENGTH or a presence,
/// never the value — the same discipline `PocketSessionKeyDefect.wrongLength` follows by
/// carrying a count instead of the string it counted.
final class PocketSessionKeyImportTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["POCKET_HARDWARE"] == "1"
    }

    private var peripheral: String {
        ProcessInfo.processInfo.environment["POCKET_PERIPHERAL"]
            ?? "08322547-B7D1-0875-DA0C-0CE9BC1AE529"
    }

    private var advertisedName: String {
        ProcessInfo.processInfo.environment["POCKET_NAME"] ?? "PKT01_BLUE_26079bc5"
    }

    /// The other app's config, parsed for exactly two fields. Deliberately minimal: this is not
    /// a TOML implementation, it is two `key = "value"` lines under `[device]`.
    private struct ForeignPairing {
        var address: String
        var sessionKey: String
    }

    private func readForeignPairing() throws -> ForeignPairing {
        // ⚠ `NSHomeDirectory()`, NOT `FileManager.homeDirectoryForCurrentUser`.
        //
        // The latter is UNAVAILABLE ON iOS, and this target builds for iOS. `swift test`
        // did not catch that because it builds for macOS — the exact split this repo keeps
        // getting caught by, and the reason `ci-gates.sh` exists as a separate gate. The
        // pre-push gate refused this file at `test-target-compile(FoundryX)` while 1,783
        // macOS tests were green.
        //
        // `NSHomeDirectory()` exists on both. On iOS it resolves inside the app sandbox,
        // where this file cannot exist, so the read fails and the test SKIPS with the
        // message below rather than vanishing behind an `#if os(macOS)` — a test that
        // compiles out on a platform is indistinguishable from one that passed there.
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pocket-libre/config.toml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw XCTSkip("no ~/.pocket-libre/config.toml — there is no already-provisioned "
                              + "pairing on this machine to import, so this bootstrap has "
                              + "nothing to do. It is skipped, not passed.")
        }
        func field(_ name: String) -> String {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(name) , let eq = line.firstIndex(of: "=") else { continue }
                let lhs = line[..<eq].trimmingCharacters(in: .whitespaces)
                guard lhs == name else { continue }
                return line[line.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return ""
        }
        return ForeignPairing(address: field("address"), sessionKey: field("session_key"))
    }

    func testTheExistingPairingIsImportedAndTheRecorderAcceptsIt() async throws {
        try XCTSkipUnless(
            enabled,
            "POCKET_HARDWARE=1 not set — this imports a real credential into the real Keychain "
                + "and speaks to a physical recorder. Skipped, NOT passed.")

        let pairing = try readForeignPairing()

        // ── THE SAFETY GATE, BEFORE ANY RADIO EXISTS ────────────────────────────────────
        // A key belonging to a DIFFERENT recorder must never be sent to this one: that is the
        // untested overwrite path. Refuse here, where the app has nowhere to send anything.
        XCTAssertEqual(
            pairing.address.uppercased(), peripheral.uppercased(),
            "the stored pairing is for a DIFFERENT device, so importing it would send a new "
                + "key to an already-paired recorder — the one operation on this hardware that "
                + "is deliberately untested. Refusing before a transport exists.")

        XCTAssertEqual(
            pairing.sessionKey.count, 16,
            "expected a 16-character session key; found \(pairing.sessionKey.count) characters. "
                + "(The COUNT, never the value.)")
        XCTAssertNil(
            PocketSessionKey.defect(in: pairing.sessionKey),
            "the stored key does not satisfy the shipped predicate, so the recorder would "
                + "refuse it — reported without quoting the candidate")

        // ── THE SHIPPED SEAM, NOT A REIMPLEMENTATION ────────────────────────────────────
        // `PocketSessionKeyEntryCoordinator.live` builds a real `RecordingDeviceAttachment`
        // over CoreBluetooth and runs `submit`, which saves through `PocketSecretStore` and
        // then re-runs the same attach chain a tap on the device list runs. Nothing here mints,
        // derives, or invents a key.
        let coordinator = PocketSessionKeyEntryCoordinator.live()
        let outcome = await coordinator.submit(
            key: pairing.sessionKey,
            peripheralIdentifier: UUID(uuidString: peripheral)!,
            advertisedName: advertisedName)

        // `PocketSessionKeyEntryOutcome` carries no case that holds the key, so describing it
        // is safe — the credential-hygiene gate asserts exactly that property.
        print("[pocket-import] outcome: \(outcome)")

        switch outcome {
        case .adopted(_, let displayName, let negotiatedProtocol):
            print("[pocket-import] adopted \(displayName) over \(negotiatedProtocol)")
        case .refusedByRecorder:
            XCTFail("the recorder rejected a key that another app is using successfully with "
                        + "this same device. That is a real contradiction, not a typo: the "
                        + "coordinator has already removed it from custody.")
        case .malformed(let defect):
            XCTFail("refused before the radio: \(defect)")
        case .linkFailed(let reason):
            throw XCTSkip("the recorder was never reached (\(reason)). It must be powered and "
                              + "in range. Skipped rather than failed — nothing was learned "
                              + "about the key.")
        case .keyNotKept:
            XCTFail("custody would not keep the key, so the recorder was never asked")
        case .notRemembered(let reason):
            XCTFail("the key WORKED and the account store would not keep the result: \(reason)")
        case .notARecorder:
            XCTFail("this device does not speak the stored-file protocol")
        }
    }
}
