import XCTest
import Foundation
@testable import FoundryXKit

/// T13 / A6 — `BrainChoice` persisted identity, the `T-CHROME-PHONE` invariant.
///
/// Brine driver for `features/brain-choice-persisted-identity.feature`.
///
/// ## What was missing, and why the existing tests did not cover it
///
/// `BrainMigrationTests` proves the migration *policy* — a fresh install defaults to
/// `.justMyPhone`, a paired install stays on `.myComputer`, an explicit choice beats the
/// default. Every one of those tests writes through `BrainStore.select` and reads back
/// through `BrainStore.choice`, so the enum's raw values are supplied by the same source
/// on both sides. **Rename `.myComputer`'s raw value and every one of them still passes**
/// — the round trip agrees with itself. That is precisely the shape of a check that
/// cannot see the defect it is nearest to.
///
/// The bytes on a person's phone were NOT written by this build. They were written by the
/// build they installed months ago, and that build is not available to agree with. So the
/// upgrade fixture below writes the LEGACY BYTES DIRECTLY into the defaults suite — the
/// literal `"computer"` under the literal `"foundryx.brain.choice"`, spelled here as data
/// and never derived from the enum — and then asks this version to read them.
///
/// That is the whole invariant: an upgraded device keeps its brain selection. The two
/// literal-pinning scenarios state the same thing statically, so the failure names WHICH
/// spelling moved rather than only that a fixture stopped round-tripping.
final class BrainChoicePersistedIdentityFeatureTests: XCTestCase {

    /// The persisted key, as a shipped app already wrote it. A LITERAL, deliberately not
    /// `AccountPreferenceCatalog.brainChoice.canonicalKey` — reading the key from the
    /// thing under test is how a rename passes its own check.
    private static let shippedKey = "foundryx.brain.choice"

    /// The raw values a shipped app has already written to disk, paired with the case
    /// they must still select. Literals on both sides of the comparison.
    private static let shippedSpellings: [(bytes: String, choice: BrainChoice)] = [
        ("phone", .justMyPhone),
        ("computer", .myComputer),
        ("cloud", .foundryCloud),
    ]

    /// Asserted separately so that DELETING a row is a failure too. A manifest that only
    /// checks the rows it still contains shrinks quietly to nothing and stays green.
    private static let shippedSpellingCount = 3

    /// A defaults suite standing in for a phone upgraded from an older build: the legacy
    /// bytes are already there, written by a version that is not this one.
    private func upgradedDevice(alreadyChose bytes: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "brain-upgrade-\(UUID().uuidString)")!
        suite.set(bytes, forKey: Self.shippedKey)
        return suite
    }

    // Scenario: an upgraded device keeps its brain selection
    func testAnUpgradedDeviceKeepsItsBrainSelection() {
        let defaults = upgradedDevice(alreadyChose: "computer")

        let store = BrainStore(defaults: defaults, hasPairedDesktop: false)

        XCTAssertEqual(
            store.choice, .myComputer,
            "a phone that chose 'My computer' on an older build must still be on it after "
          + "the upgrade — reading back anything else is a silent identity reset on every "
          + "installed device")
    }

    // Scenario: an upgraded device that chose the phone keeps the phone
    func testAnUpgradedDeviceThatChoseThePhoneKeepsThePhone() {
        let defaults = upgradedDevice(alreadyChose: "phone")

        let store = BrainStore(defaults: defaults, hasPairedDesktop: true)

        XCTAssertEqual(
            store.choice, .justMyPhone,
            "an explicit 'Just my phone' written by an older build outranks the paired-desktop "
          + "default — otherwise upgrading silently moves the person onto their computer")
    }

    // Scenario: the spellings already written to every installed phone are frozen
    func testTheShippedSpellingsAreByteIdentical() {
        XCTAssertEqual(
            Self.shippedSpellings.count, Self.shippedSpellingCount,
            "the frozen-spelling manifest changed size — a row that disappears takes its "
          + "guarantee with it")

        for (bytes, choice) in Self.shippedSpellings {
            XCTAssertEqual(
                choice.rawValue, bytes,
                "BrainChoice.\(choice) persists as '\(choice.rawValue)' but installed phones "
              + "already hold '\(bytes)' — those devices will read back no selection at all")

            XCTAssertEqual(
                BrainChoice(rawValue: bytes), choice,
                "the bytes '\(bytes)' on an installed phone no longer decode to \(choice)")
        }

        XCTAssertEqual(
            Set(BrainChoice.allCases.map(\.rawValue)),
            Set(Self.shippedSpellings.map(\.bytes)),
            "the set of persisted spellings moved — a case added or removed here changes what "
          + "an installed phone's bytes mean")
    }

    // Scenario: the place the selection is stored is frozen too
    func testTheStorageKeyIsByteIdentical() {
        XCTAssertEqual(
            AccountPreferenceCatalog.brainChoice.canonicalKey, Self.shippedKey,
            "the brain selection moved to a different defaults key — every installed phone's "
          + "existing selection becomes unreachable and reads as a fresh install")
    }
}
