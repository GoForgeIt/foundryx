import XCTest
@testable import FoundryXKit

/// THE ONE SESSION ANYBODY HAS EVER RUN AGAINST A REAL POCKET, HELD AS A TEST.
///
/// Everything this app believed about the Pocket's WiFi family came from a third-party decode of
/// firmware **1.3.3** on a `PKT01_GREY`. On 2026-08-16 the verbs were finally sent to a real
/// recorder — Nick's own `PKT01_BLUE_26079bc5`, device firmware **1.6**, WiFi firmware **V8** —
/// and one of the beliefs was wrong in a way that made fast sync impossible to ship:
///
///     APP&WIFI  ->  MCU&WIFI&PKT01_BLUE_26079bc5&PD9QQDJ8
///     session key   PD9QQDJ6KM3PJDFC
///     app derived   PD9QQDJ6      (sessionKey.prefix(8))     <- EIGHTH CHARACTER DIFFERS
///
/// `PocketAccessPointReadback.provesPossession(ofSessionKey:)` compared exactly those two
/// strings, so it answered FALSE about the owner's own recorder, and `PocketFastSyncCoordinator`
/// refused its own credential gate before it ever attempted a join. The transcript is
/// `foundry-hearth/reference/pocket-ble-protocol.md` (raw capture:
/// `pocket-verb-probe-20260816.json`).
///
/// WHY THE SAMPLE LIVES IN A TEST RATHER THAN IN A COMMENT. A comment recording a measurement
/// cannot notice when somebody "tidies" the derivation back to `prefix(8)` — which reads like a
/// simplification and is a regression that only real hardware can see. This file is the thing
/// that goes red instead.
final class PocketFastSyncHardwareEvidenceTests: XCTestCase {

    /// Verbatim, including the format. Nothing here is normalised: the device said this.
    private static let deviceName = "PKT01_BLUE_26079bc5"
    private static let sessionKey = "PD9QQDJ6KM3PJDFC"
    private static let reportedResponse = "MCU&WIFI&PKT01_BLUE_26079bc5&PD9QQDJ8"
    private static let reportedPassword = "PD9QQDJ8"

    /// THE RED THIS FILE WAS BORN AS. On `main` this assertion failed.
    func testTheRecorderNickOwnsIsRecognisedAsHis() throws {
        guard let readback = PocketAccessPointReadback.parse(Self.reportedResponse) else {
            return XCTFail("the response real hardware gave did not parse: \(Self.reportedResponse)")
        }
        XCTAssertEqual(readback.ssid, Self.deviceName)
        XCTAssertTrue(readback.provesPossession(ofSessionKey: Self.sessionKey), """
        The recorder answered APP&WIFI with `\(Self.reportedResponse)` while holding session key \
        \(Self.sessionKey), and this app did not recognise it as its own. That is not a hardware \
        fault: the app derived `\(Self.sessionKey.prefix(8))` and the device reported \
        `\(Self.reportedPassword)`, which differ in the eighth character. Fast sync fails its own \
        possession gate before it ever tries to join.
        """)
    }

    /// THE PASSWORD THAT ACTUALLY JOINS IS THE DEVICE'S, NOT OURS. A join built from
    /// `sessionKey.prefix(8)` would fail on this recorder — after the access point is already
    /// up, which is the worst place to discover it.
    func testTheJoinUsesWhatTheRecorderReportedAndNotWhatWeDerived() throws {
        guard let readback = PocketAccessPointReadback.parse(Self.reportedResponse) else {
            return XCTFail("the response real hardware gave did not parse")
        }
        guard let credentials = readback.credentials(provenBy: Self.sessionKey) else {
            return XCTFail("a recognised recorder handed out no credentials to join with")
        }
        XCTAssertEqual(credentials.ssid, Self.deviceName,
                       "the SSID is the device name — measured, and it is what the owner sees "
                           + "in the phone's WiFi list")
        XCTAssertEqual(credentials.password, Self.reportedPassword, """
        The join used `\(credentials.password)` and the recorder's access point is on \
        `\(Self.reportedPassword)`. Deriving the password from the session key is exactly the \
        defect this file records; the readback is the authority.
        """)
        XCTAssertNotEqual(credentials.password, String(Self.sessionKey.prefix(8)),
                          "the credential handed to the joiner is the derived one again")
    }

    /// THE PROOF IS STILL A PROOF. Weakening the comparison to the seven characters hardware
    /// agreed on may not weaken it into "any recorder passes".
    func testARecorderHoldingSomebodyElsesKeyIsStillRefused() {
        let ours = Self.sessionKey
        // A vendor key, or another owner's mint: it disagrees from the first character, which
        // is what every real disagreement looks like.
        let theirs = "Aa1Bb2Cc3Dd4Ee5F"
        guard let stale = PocketAccessPointReadback.parse("MCU&WIFI&\(Self.deviceName)&Aa1Bb2Cc") else {
            return XCTFail("fixture did not parse")
        }
        XCTAssertFalse(stale.provesPossession(ofSessionKey: ours),
                       "a recorder reporting another key's password satisfied the proof")
        XCTAssertNil(stale.credentials(provenBy: ours),
                     "a recorder that failed the proof still handed out a password to join with")
        XCTAssertTrue(stale.provesPossession(ofSessionKey: theirs),
                      "non-vacuity: this fixture is a real readback for SOME key, so the two "
                          + "assertions above are refusals rather than a parser returning nothing")
    }

    /// A NEAR MISS IS STILL A MISS. Agreement on six characters is not agreement on seven, and
    /// a password of the wrong LENGTH is not a password at all.
    func testAgreementShorterThanTheEvidencedPrefixIsRefused() {
        let ours = Self.sessionKey                       // PD9QQDJ6…
        for wrong in ["PD9QQDX8", "PD9QQD", "PD9QQDJ89", ""] {
            let readback = PocketAccessPointReadback(ssid: Self.deviceName,
                                                     fields: [Self.deviceName, wrong])
            XCTAssertFalse(readback.provesPossession(ofSessionKey: ours),
                           "`\(wrong)` was accepted as proof of possession of \(ours)")
        }
        // Paired existence over the same population: the exact measured value passes.
        let real = PocketAccessPointReadback(ssid: Self.deviceName,
                                             fields: [Self.deviceName, Self.reportedPassword])
        XCTAssertTrue(real.provesPossession(ofSessionKey: ours),
                      "the measured password itself is refused — the four refusals above pass "
                          + "vacuously and this file proves nothing")
    }

    /// THE NUMBER, NAMED. Seven is a measurement, not a taste, and the day somebody explains
    /// the eighth character this test is where the change is argued.
    func testTheEvidencedPrefixIsSevenBecauseTheEighthCharacterDisagreed() {
        XCTAssertEqual(PocketSessionKeyMint.accessPointPasswordEvidencedPrefixLength, 7)
        XCTAssertEqual(PocketSessionKeyMint.accessPointPasswordLength, 8)
        XCTAssertEqual(PocketSessionKeyMint.accessPointPasswordEvidencedPrefix(for: Self.sessionKey),
                       "PD9QQDJ")
        XCTAssertEqual(String(Self.reportedPassword.prefix(7)), "PD9QQDJ",
                       "the measured pair no longer agrees on seven characters, so the constant "
                           + "above is describing a sample that is not in this file")
        XCTAssertNotEqual(Self.reportedPassword, String(Self.sessionKey.prefix(8)),
                          "the sample this whole file is about has been edited into agreement")
    }
}
