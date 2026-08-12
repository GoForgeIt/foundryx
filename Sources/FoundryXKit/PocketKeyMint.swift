// PocketKeyMint.swift — BECOMING THE RECORDER'S FIRST OWNER, AND PROVING IT.
//
// WHAT CHANGED, AND WHY IT IS NOW SAFE TO SHIP. `provisionFactoryFresh` was gated because two
// things were unevidenced: a firmware-compatible key alphabet, and a way to tell a real
// provisioning from a blind acknowledgement. Both are settled here.
//
//   THE ALPHABET. The first eight characters of the session key BECOME the recorder's WiFi
//   access-point password, so the alphabet is not a style choice — it is a WPA-PSK
//   compatibility requirement AND a protocol-framing requirement. The wire protocol is
//   `&`-delimited (`APP&SK&<key>`), so a key containing `&` would split its own command. This
//   file's alphabet is unambiguous ASCII alphanumerics: every character is a legal WPA
//   passphrase byte, none of them is `&`, none is whitespace, and none is a glyph pair a human
//   can transcribe wrongly (no `0`/`O`, no `1`/`l`/`I`).
//
//   THE PROOF. `MCU&SK&OK` on its own is an ACK, and an ACK is not evidence that the recorder
//   kept what we sent — a firmware that already holds a vendor key could answer `OK` and go on
//   using the key it had. So a mint is verified by READING BACK the recorder's access-point
//   credentials (`APP&WIFI`) and checking that the password it reports is the first eight
//   characters of OUR key. A recorder still holding somebody else's key cannot produce that
//   string. `PocketAccessPointReadback.provesPossession(ofSessionKey:)` is that check, and
//   nothing in this app reports a successful mint without it.
//
// THE HALF-CREDENTIAL PROBLEM, STATED. The access-point password is literally half the session
// key. So this file's readback type is deliberately NOT `Equatable`, NOT
// `CustomStringConvertible`, and exposes no accessor for the credential fields it parsed. The
// only thing callers can ask it is a yes/no question they already know the answer's input to.

import Foundation
#if canImport(Security)
import Security
#endif

// MARK: - Consent

/// A MINT MAY NOT HAPPEN BY ACCIDENT, AND THE TYPE SYSTEM IS WHERE THAT IS ENFORCED.
///
/// Two things about a stored-file recorder are not known from any hardware session anyone has
/// run (proposal §6b; bench TEST 3 row B was never executed):
///
///   U1. Whether a recorder that ALREADY holds a key refuses a second `APP&SK&` write, or
///       accepts it and silently re-keys. If it refuses, attempting a mint is a free probe. If
///       it accepts, the probe itself destroys the owner's other pairing AND changes their
///       recorder's WiFi password.
///   U2. Whether the factory-reset gesture actually clears the key.
///
/// Because U1 is open, an unattended mint is not a diagnostic — it is a potentially destructive
/// write. `PocketMintConsent` has no public initialiser and exactly one factory, named for what
/// the owner has to have done. A code path that wants to mint has to have a value of this type,
/// and the only way to get one is to say, in code, that a person confirmed it.
public struct PocketMintConsent: Sendable {
    /// The owner read `PocketMintConsentPresentation` — including the sentence about the other
    /// app's pairing and about unsynced recordings — and tapped the confirm action.
    public static func ownerConfirmedAfterReadingTheConsequences() -> PocketMintConsent {
        PocketMintConsent()
    }
    private init() {}
}

// MARK: - The key

public enum PocketKeyMintError: Error, Equatable, Sendable {
    /// No cryptographic random source. Never fall back to `Int.random`.
    case noSecureRandomSource
}

/// THE KEY THIS APP MAKES, AND THE ONLY PLACE IT IS MADE.
public enum PocketSessionKeyMint {

    /// UNAMBIGUOUS ASCII ALPHANUMERICS — 57 characters.
    ///
    /// Every constraint this satisfies, and why each one is load-bearing:
    ///
    ///   - **WPA-PSK legal.** A WPA passphrase is 8–63 printable ASCII bytes. The first eight
    ///     characters of the key ARE the recorder's access-point password, so anything outside
    ///     printable ASCII would produce a recorder whose WiFi cannot be joined. Alphanumerics
    ///     are the safest subset — no router, no OS, and no QR encoder treats them specially.
    ///   - **`&`-free.** The control protocol is `&`-delimited. A key containing `&` would
    ///     split `APP&SK&<key>` into a different command, and the recorder would key itself to
    ///     a prefix of what we think we sent.
    ///   - **Whitespace-free.** `PocketSessionKey.normalised` trims leading and trailing
    ///     whitespace, so a key with an edge space could never be re-entered as itself.
    ///   - **Transcribable.** `0`/`O`, `1`/`l`/`I` are omitted. This key is shown to its owner
    ///     (§10 custody) and may be typed on a second device; a glyph collision there is a
    ///     recorder the owner is locked out of.
    ///
    /// 57^16 ≈ 2^93.3 of entropy for a credential whose only online guessing channel is a BLE
    /// write that answers one attempt at a time.
    public static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    public static let length = 16

    /// The number of leading characters that become the recorder's WiFi password.
    public static let accessPointPasswordLength = 8

    /// SecRandomCopyBytes, and a rejection filter so the alphabet is uniform.
    ///
    /// `byte % 57` would make the first 28 characters of the alphabet ~1.14× as likely as the
    /// rest, because 256 is not a multiple of 57. Bytes at or above the largest multiple of 57
    /// that fits in a byte (228) are DISCARDED and redrawn instead. The loop is bounded because
    /// the discard probability per byte is 28/256; the bound exists so a broken RNG cannot hang
    /// the setup screen.
    public static func generate() throws -> String {
        var result = String()
        result.reserveCapacity(length)
        var attempts = 0
        let ceiling = UInt8(256 - (256 % alphabet.count))
        while result.count < length {
            attempts += 1
            guard attempts < 4_096 else { throw PocketKeyMintError.noSecureRandomSource }
            for byte in try randomBytes(count: length) where result.count < length {
                guard byte < ceiling else { continue }
                result.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return result
    }

    /// The eight characters the recorder will use as its access-point password.
    ///
    /// `nil` for anything that is not a well-formed key, so no caller can derive a WPA
    /// passphrase shorter than the 8-byte minimum from a malformed candidate.
    public static func accessPointPassword(for sessionKey: String) -> String? {
        guard PocketSecretRecord.isValid(sessionKey) else { return nil }
        let derived = String(sessionKey.prefix(accessPointPasswordLength))
        guard derived.count == accessPointPasswordLength else { return nil }
        return derived
    }

    /// Would this key survive the trip through the protocol, the Keychain, and a WPA join?
    /// Held as a predicate rather than as a comment so the generator can be checked against it.
    public static func isWireAndWiFiSafe(_ candidate: String) -> Bool {
        guard PocketSecretRecord.isValid(candidate) else { return false }
        return candidate.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 33 && scalar.value <= 126 && scalar != "&"
        }
    }

    private static func randomBytes(count: Int) throws -> [UInt8] {
#if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw PocketKeyMintError.noSecureRandomSource
        }
        return bytes
#else
        throw PocketKeyMintError.noSecureRandomSource
#endif
    }
}

// MARK: - The proof

/// WHAT `APP&WIFI` GAVE BACK, HELD SO THAT ONLY ONE QUESTION CAN BE ASKED OF IT.
///
/// The recorder answers `MCU&WIFI&…` with its access-point credentials. The FIELD ORDER of that
/// response is not evidenced by any hardware session in the record — only the fact that the
/// password is the first eight characters of the session key. So this type does not claim to
/// know which field is which. It keeps every `&`-separated field and answers exactly one
/// question: does ANY of them equal the password our key implies.
///
/// That is order-agnostic, and it is still a real proof. A recorder that ignored our write and
/// kept a vendor key reports the VENDOR key's first eight characters, which cannot equal ours.
///
/// NOT `Equatable`, NOT `CustomStringConvertible`, and no accessor for the fields: the value it
/// holds is half of a live credential, and the discipline that keeps the other half out of logs
/// applies here in full.
public struct PocketAccessPointReadback: Sendable {

    /// The recorder's advertised network name. Device-derived, not key-derived, so it is safe
    /// to show — it is what the owner picks in iOS WiFi settings.
    public let ssid: String

    private let fields: [String]

    public init(ssid: String, fields: [String]) {
        self.ssid = ssid
        self.fields = fields
    }

    /// `MCU&WIFI&<field>&<field>…`. `nil` when the response is not that shape at all — which is
    /// a different answer from "the fields did not match", and the caller must keep them apart.
    public static func parse(_ response: String) -> PocketAccessPointReadback? {
        let prefix = "MCU&WIFI&"
        guard response.hasPrefix(prefix) else { return nil }
        let payload = String(response.dropFirst(prefix.count))
        let fields = payload.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        guard !fields.isEmpty, fields.contains(where: { !$0.isEmpty }) else { return nil }
        // The SSID is conventionally first and is the only field this type is willing to name.
        // Being wrong about that costs a label on a screen; being wrong about which field is
        // the password would cost the verification itself, which is why the check below does
        // not depend on position.
        return PocketAccessPointReadback(ssid: fields[0], fields: fields)
    }

    /// THE ONE QUESTION. Does the recorder report an access-point password that only a device
    /// holding THIS key could report?
    public func provesPossession(ofSessionKey key: String) -> Bool {
        guard let derived = PocketSessionKeyMint.accessPointPassword(for: key) else { return false }
        return fields.contains(derived)
    }
}

// MARK: - Copy: the branch a possibly-keyed recorder gets

/// THE ALREADY-KEYED BRANCH (design §4, proposal §6b), WORDED FOR THE STATE OF THE EVIDENCE.
///
/// This screen exists because of U1: nobody has run a second `APP&SK&` write against a recorder
/// that already holds a key, so this app genuinely does not know whether the attempt is free or
/// destructive. The copy says that, in those words, and then lets the owner decide. It does not
/// pretend the write is safe, and it does not pretend it is certainly harmful.
public enum PocketMintConsentPresentation {

    public static let title = "Set this recorder up for Solleva"

    /// Said first, because it is the thing the owner is actually being asked to accept.
    public static let whatSollevaWillDo =
        "Solleva will make one key on this iPhone and send it to the recorder once. If the "
        + "recorder takes it, Solleva becomes its owner — like setting the password on a new "
        + "router. No account, no sign-up, and nothing is sent to the maker."

    /// THE UNKNOWN, NOT DRESSED AS A RISK ASSESSMENT. It is the honest reason consent is being
    /// asked for at all.
    public static let whatSollevaDoesNotKnow =
        "If another app already set this recorder up, Solleva can't tell you in advance what "
        + "will happen. The recorder may refuse the new key and keep the one it has, or it may "
        + "take the new key and forget the old one. Solleva has never seen a recorder answer "
        + "this, so it won't guess for you."

    /// THE COST, STATED BEFORE THE TAP AND NOT AFTER IT.
    public static let whatItCouldCost =
        "If the recorder does take the new key: the other app can no longer connect to it, and "
        + "any recording still only on the recorder may be out of reach until you set that app "
        + "up again. Solleva never deletes anything from the recorder."

    /// The recorder's WiFi password changes too — a real, separate consequence that a person
    /// who joined that network on purpose would otherwise discover by failing to join it.
    public static let theWiFiPasswordChanges =
        "The recorder's own WiFi password is made from the key, so it changes with it. Solleva "
        + "shows you the new one after setup."

    /// The confirm action. Named for the act, not for "OK" — a confirm that says "Continue"
    /// reads as a step in a wizard rather than as a decision.
    public static let confirmAction = "Send a new key"
    public static let entryAction = PocketSessionKeyEntryPresentation.entryAction
    public static let resetAction = "How do I start the recorder over?"
    public static let cancelAction = "Not now"

    public static let sections: [PocketEducationSection] = [
        .init(title: "What Solleva will do", body: whatSollevaWillDo),
        .init(title: "What Solleva can't tell you", body: whatSollevaDoesNotKnow),
        .init(title: "What it could cost you", body: whatItCouldCost),
        .init(title: "Your recorder's WiFi password", body: theWiFiPasswordChanges),
    ]

    public static let actions = [confirmAction, entryAction, resetAction, cancelAction]

    public static var everyLine: [String] {
        [title] + sections.flatMap { [$0.title, $0.body] } + actions
    }
}

/// THE RECORDER REFUSED THE KEY — the safe answer to U1, and the informative one.
public enum PocketMintRefusedPresentation {
    public static let title = "This recorder already belongs to another app"

    public static let body =
        "The recorder refused the new key and kept the one it already has. That means another "
        + "app set it up first.\n\nNothing changed on the recorder. Its old key still works, "
        + "and Solleva sent it nothing else."

    public static let options =
        "You can enter the key that app set it up with, or start the recorder over from "
        + "scratch — which clears that app's setup."

    public static let actions = [PocketSessionKeyEntryPresentation.entryAction,
                                 PocketMintConsentPresentation.resetAction,
                                 "Done"]

    public static var everyLine: [String] { [title, body, options] + actions }
}

/// ACCEPTED, BUT NOT PROVEN — the state a bare `MCU&SK&OK` earns.
public enum PocketMintNotVerifiedPresentation {
    public static let title = "Solleva can't confirm this recorder took the key"

    /// SAYS WHAT WAS DONE AND WHAT COULD NOT BE CHECKED, and stops. It does not say the setup
    /// worked, and it does not say it failed, because neither is known.
    public static let body =
        "The recorder said yes to the new key, but it wouldn't tell Solleva its WiFi password "
        + "afterwards — and that's the only way Solleva can check the key really took.\n\n"
        + "Solleva has kept the key, so nothing is lost either way. It just won't tell you the "
        + "recorder is set up when it can't confirm it."

    /// NAMED, NOT TYPED TWICE. The screen that routes these actions matches on the constant;
    /// a literal here and a literal there is a routing bug that compiles.
    public static let retryAction = "Try connecting again"

    public static let actions = [retryAction, PocketKeyCustodyPresentation.entryAction]

    public static var everyLine: [String] { [title, body] + actions }
}

/// THE FACTORY RESET (proposal §6b), WITH THE COST FIRST AND THE LIMITS SAID OUT LOUD.
///
/// The gesture is the maker's. Solleva cannot perform it, cannot observe it, and cannot verify
/// it — the only check available is trying to pair afterwards. All three of those are stated,
/// because a person who believes the app is supervising a destructive gesture will do it
/// casually.
public enum PocketFactoryResetPresentation {
    public static let title = "Starting the recorder over"

    /// FIRST, BEFORE THE STEPS. Someone skimming for the instructions reads this on the way.
    public static let costFirst =
        "This clears whoever owns the recorder now. You lose the other app's setup, and any "
        + "recording that is still only on the recorder and hasn't been synced anywhere may be "
        + "out of reach afterwards. Do this only if you mean to."

    public static let sollevaCannotDoIt =
        "Solleva can't do this for you. It's a gesture on the recorder itself, and Solleva "
        + "can't see the recorder's button or its light."

    public static let steps =
        "1. Triple-click the side button.\n"
        + "2. The light starts blinking red.\n"
        + "3. Immediately hold the button down until the red stops."

    public static let sollevaCannotVerifyIt =
        "Solleva can't tell you whether it worked. The only way to find out is to set the "
        + "recorder up again afterwards and see whether it takes a new key."

    public static let provenance =
        "These steps come from the maker's guide. Solleva hasn't verified them on a unit."

    public static let sections: [PocketEducationSection] = [
        .init(title: "What this costs you", body: costFirst),
        .init(title: "Solleva can't do it for you", body: sollevaCannotDoIt),
        .init(title: "The gesture", body: steps),
        .init(title: "Solleva can't check it worked", body: sollevaCannotVerifyIt),
        .init(title: "Where this comes from", body: provenance),
    ]

    public static let retryAction = "Try setting it up again"
    public static let actions = [retryAction, "Close"]

    public static var everyLine: [String] {
        [title] + sections.flatMap { [$0.title, $0.body] } + actions
    }
}
