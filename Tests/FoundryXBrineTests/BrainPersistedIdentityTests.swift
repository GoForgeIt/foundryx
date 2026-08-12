import XCTest
import Foundation
import FoundryXKit

/// T13 `A6` — `BrainChoice` PERSISTED IDENTITY, the `T-CHROME-PHONE` invariant.
///
/// THE CRITERION, VERBATIM FROM THE TRACK'S DISPOSITION: *"raw values (`phone`,
/// `computer`, `cloud`) and the `foundryx.brain.choice` key byte-identical, and an
/// upgraded device keeps its brain selection"*, with the mutation leg *"rename
/// `BrainChoice.myComputer`'s raw value along with its symbol -> the upgraded-device
/// fixture reads back a different selection"*.
///
/// WHY THIS FILE EXISTS.  T13's own criteria disposition recorded A6 as **subject
/// present, no check for the criterion**:
///
///     `BrainChoice`'s raw values and `foundryx.brain.choice` exist
///     (`Sources/FoundryXKit/BrainStore.swift:9-16,31`). What A6 asks for is an
///     **upgraded-device fixture read as opaque bytes**, and that does not exist.
///     Renaming the `.myComputer` raw value *does* redden `BrainMigrationTests.swift:52`
///     — recorded as a **probe, not as coverage**.
///
/// That distinction is the whole point and it is kept here.  `BrainMigrationTests`
/// reddens because `.select(.myComputer)` round-trips through the SAME symbol that was
/// renamed: it asserts the enum agrees with itself, which a consistent rename preserves
/// and which says nothing about the bytes already on a device.  A6 is about the BYTES.
/// Every case below writes a **string literal** under a **string literal key** — never
/// `BrainChoice.myComputer.rawValue`, never `AccountPreferenceCatalog.brainChoice` — so
/// the fixture is what a device upgraded from the shipped build actually holds, and a
/// rename that carried symbol and raw value together still breaks it.
///
/// A NOTE ON WHAT IS *NOT* ASSERTED: this file does not claim the frontier is complete.
/// The whole persisted-identifier frontier is A5's subject and A5 owes its own manifest
/// mutation.  This is `BrainChoice`'s row of it, which is what A6 names.
final class BrainPersistedIdentityTests: XCTestCase {

    /// The bytes a shipped device already has on disk.  Written as literals ON PURPOSE:
    /// deriving them from `BrainChoice` would make this table agree with any rename, and
    /// a table that moves with its subject asserts nothing about persisted state.
    private static let persistedFrontier: [(bytes: String, choice: BrainChoice)] = [
        ("phone", .justMyPhone),
        ("computer", .myComputer),
        ("cloud", .foundryCloud),
    ]

    private static let persistedKey = "foundryx.brain.choice"

    // MARK: the frontier itself, byte-identical and COUNTED

    func testEveryBrainRawValueIsByteIdenticalAndTheSetIsClosed() {
        // NON-VACUOUS FIRST: a table that silently emptied would make every
        // per-element assertion below pass by having nothing to check.
        XCTAssertEqual(Self.persistedFrontier.count, 3,
                       "the persisted frontier table is not the three shipped brains")
        XCTAssertEqual(BrainChoice.allCases.count, Self.persistedFrontier.count,
                       "BrainChoice gained or lost a case; a new brain is a new persisted "
                       + "value and this table is the only place that says which bytes ship")

        var compared = 0
        for (bytes, choice) in Self.persistedFrontier {
            XCTAssertEqual(choice.rawValue, bytes,
                           "\(choice) persists as '\(choice.rawValue)' and the shipped bytes "
                           + "are '\(bytes)'. A device holding the old bytes now reads back a "
                           + "different brain — a silent tier change on every installed phone.")
            compared += 1
        }
        XCTAssertEqual(compared, 3, "the comparison loop did not execute for every brain")
    }

    func testThePersistedKeyIsByteIdentical() {
        XCTAssertEqual(AccountPreferenceCatalog.brainChoice.canonicalKey, Self.persistedKey,
                       "the brain selection moved to a different UserDefaults key; every "
                       + "upgraded device silently reverts to the free tier")
    }

    // MARK: the upgraded device — read as OPAQUE BYTES

    /// A device that already carries a brain selection, expressed the way the shipped
    /// build wrote it: a raw string under a raw key.
    private func upgradedDevice(carrying bytes: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "brain-identity-\(UUID().uuidString)")!
        d.set(bytes, forKey: Self.persistedKey)
        return d
    }

    func testAnUpgradedDeviceKeepsItsBrainSelection() {
        var read = 0
        for (bytes, expected) in Self.persistedFrontier {
            let store = BrainStore(defaults: upgradedDevice(carrying: bytes))
            XCTAssertEqual(store.choice, expected,
                           "a device carrying '\(bytes)' under '\(Self.persistedKey)' read "
                           + "back \(store.choice) instead of \(expected). The upgrade lost "
                           + "the user's brain selection.")
            read += 1
        }
        XCTAssertEqual(read, 3,
                       "the upgraded-device fixture did not run for every persisted value; "
                       + "zero executed is not green")
    }

    /// THE DISCRIMINATING CASE.  Without it the three above would also pass for a store
    /// that ignored persisted state and returned a constant, or one whose migration
    /// default happened to match.  `hasPairedDesktop: true` is the migration signal that
    /// forces `.myComputer` when nothing is stored — so a stored `phone` that survives it
    /// proves the STORED BYTES were read, not the default.
    func testStoredBytesBeatTheMigrationDefault() {
        let store = BrainStore(defaults: upgradedDevice(carrying: "phone"),
                               hasPairedDesktop: true)
        XCTAssertEqual(store.choice, .justMyPhone,
                       "an explicit stored 'phone' was overridden by the paired-desktop "
                       + "migration default; the persisted bytes are not being read")
    }
}
