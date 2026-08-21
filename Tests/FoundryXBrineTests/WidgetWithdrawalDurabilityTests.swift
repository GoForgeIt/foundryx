import XCTest
@testable import FoundryXKit

/// The durability guard in `CaptureWidgetSnapshotStore.withdraw(expectedOwner:)` — the
/// one that actually failed on a real device on 2026-08-12 and made "delete everything"
/// stop at step 2 of 13 with `exposureBarrierFailed`, permanently.
///
/// These paths had NEVER executed in any test. Every existing test injects a private
/// UserDefaults inside the XCTest process, where a flush always succeeds, and the only
/// route to `.persistenceFailed` was `.synchronizeFailure` — a fault that returns BEFORE
/// the removal. So the guard that broke was structurally unreachable from the suite that
/// was supposed to cover it. `.absenceProbeSurvives` fires AFTER the removal, which is
/// what makes these three assertions possible at all.
final class WidgetWithdrawalDurabilityTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "widget-durability-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(suite)
    }

    override func tearDown() {
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func seed(owner: String) throws {
        let envelope = CaptureWidgetSnapshotStore.Envelope(
            owner: owner, snapshot: .idle)
        suite.set(owner, forKey: CaptureWidgetSnapshotStore.activeOwnerKey)
        suite.set(try JSONEncoder().encode(envelope),
                  forKey: CaptureWidgetSnapshotStore.key)
    }

    /// THE GATE KEEPS ITS TEETH. A container that cannot be written must still fail the
    /// barrier — the fix must not make `withdraw()` incapable of ever failing.
    func testAContainerThatStillHoldsTheValueIsNotAWithdrawal() throws {
        try seed(owner: "owner-a")
        CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(.absenceProbeSurvives)
        defer { CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(nil) }

        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(expectedOwner: "owner-a"),
            .persistenceFailed,
            "a withdrawal the group domain does not confirm must NOT report success")
    }

    /// THE LOCKOUT IS GONE. The old failure path wrote the payload back and
    /// re-synchronized, reconstructing the precondition so every retry was
    /// bit-identical. A failed attempt must leave the removal in place so the next one
    /// can make progress.
    func testAFailedWithdrawalDoesNotRepublishTheAccount() throws {
        try seed(owner: "owner-a")
        CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(.absenceProbeSurvives)
        // Cleared on the way out as well as at `:72` below. The mid-test clear is part of
        // what this scenario asserts; this one exists for the path where an assertion above
        // it never reaches it, because the fault is process-global and outlives the test.
        defer { CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(nil) }
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(expectedOwner: "owner-a"),
            .persistenceFailed)

        XCTAssertNil(
            suite.data(forKey: CaptureWidgetSnapshotStore.key),
            "the failure path must not restore the payload it was told to erase")
        XCTAssertNil(
            suite.string(forKey: CaptureWidgetSnapshotStore.activeOwnerKey),
            "the failure path must not restore the owner tag either")

        // ...and with the container writable again, the retry now SUCCEEDS. Under the
        // old code this second call saw a restored payload and failed identically.
        CaptureWidgetSnapshotStore.setWithdrawalFaultForTesting(nil)
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(expectedOwner: "owner-a"),
            .alreadyAbsent,
            "Try again must be able to make progress after a transient failure")
    }

    /// A HAPPY WITHDRAWAL STILL SUCCEEDS.
    func testAWritableContainerWithdrawsCleanly() throws {
        try seed(owner: "owner-a")
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.withdraw(expectedOwner: "owner-a"),
            .withdrawn)
        XCTAssertNil(suite.data(forKey: CaptureWidgetSnapshotStore.key))
    }
}
