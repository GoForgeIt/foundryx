import XCTest
import Foundation
import Security
@testable import FoundryXKit

/// THE FIX FOR A MACHINE-GLOBAL, CROSS-*PROCESS* HAZARD.
///
/// `ProcessGlobalStateTestCase` fixed state that leaks between SUITES inside one test
/// process. This fixes the tier above it: state that leaks between test RUNS, because it
/// lives on the machine rather than in the process.
///
/// WHAT WENT WRONG (measured on `main` at 496694a, 2026-08-16).
/// ------------------------------------------------------------
/// A full `swift test` was 42 assertion failures across NINE suites — CaptureStatusCache,
/// CaptureResync, CaptureResyncDrain, CaptureUploadThroughput, DrainGateComputeStatusHang,
/// ConcurrentIngestStress, OmiReconnect, PocketBringOver, ChatSession — and every one of
/// them said some version of "a file that should exist does not":
///
///     "cache written by warm" / "no segment written" / "frames must be durable on disk"
///     "the conversation directory holds no audio at all"
///
/// That is not nine bugs. It is one, and it is not in any of those suites:
///
///   1. `InterruptedDeletionSignInRecoveryFeatureTests` drives the REAL
///      `AuthStore.save(identity)`, which does a real `SecItemAdd` at the fixed service
///      `com.goforgeit.foundryx.auth`. Instrumented, that is the ONE production-keychain
///      write in a 1428-test run. The suite replaces the container and the defaults with
///      throwaway in-memory objects, so the ACTIVATION RECORD dies with the test — but the
///      KEYCHAIN ITEM is machine-global and permanent, and nothing removed it.
///   2. Any LATER process therefore sees `AuthStore.identityPresence() == .present` with no
///      activation record of its own. `CaptureAccountScope` resolves that — CORRECTLY, for
///      production; it is the "identity exists but was never activated" pre-scope install —
///      to `.blocked`.
///   3. `.blocked` ⇒ `resolvedScope` nil ⇒ `binding(forExplicitRoot:)` nil ⇒
///      `CaptureWAL.accountBinding` nil ⇒ `performDurableMutation` skips the closure. The
///      WAL opens, accepts every frame, creates no directory, writes no segment, no `.ack`
///      and no status cache.
///
/// So a suite that PASSES poisons the machine, and unrelated suites in the NEXT run fail
/// with a message that names none of it. A stale
/// `foundryx.capture-account-activation.v2` left in `com.apple.dt.xctest.tool` by an older
/// build does the same thing by the other door (an "active" record whose signed-in mirror
/// does not corroborate it ⇒ `.blocked` again).
///
/// WHY THIS FILE, AND NOT A tearDown IN THE OFFENDING SUITE.
/// ---------------------------------------------------------
/// A tearDown still writes the developer's real keychain, and still leaks it if the run
/// crashes or is interrupted. Worse, it does nothing for a machine ALREADY polluted by an
/// older build — which describes this developer's Mac and, because the self-hosted CI
/// runner is the same user on the same machine, the CI runner and every release gate on it.
/// The fix has to (a) make the production item unreachable from the test bundle, and
/// (b) heal state a previous build already left behind.
///
/// WHY `defaultTestSuite`, AND WHY THAT IS NOT AN ORDERING TRICK.
/// --------------------------------------------------------------
/// XCTest builds the WHOLE suite tree first — it calls `+defaultTestSuite` on every
/// `XCTestCase` subclass in the bundle — and only then runs it. Installing from there
/// therefore happens before ANY test in ANY target of this bundle, not merely before the
/// ones that sort after this file. The class is additionally named to sort first so the two
/// mechanisms agree, and `testHygieneRanBeforeAnyTestInThisBundle` asserts the install
/// actually happened rather than assuming it.
///
/// THE ONE LIMIT, MEASURED RATHER THAN ASSUMED. `swift test --filter CaptureStatusCacheTests`
/// does NOT call `+defaultTestSuite` on classes the filter excludes, so a filtered run does
/// not get the install: measured 3 failures with that filter and 0 with
/// `--filter 'AAAAFoundryXTestBundleHygieneTests|CaptureStatusCacheTests'`, same binary,
/// same machine, seconds apart. That is why this file is the SECOND line of defence and not
/// the first: the first is that nothing writes the production item at all (the polluting
/// suite installs the override itself), and the healing here exists for machines an older
/// build already poisoned. One full `swift test` repairs such a machine permanently.
///
/// WHAT IT DOES NOT DO: it never deletes the production keychain item. A developer may
/// legitimately hold one. It SHADOWS it — the whole bundle reads and writes a service that
/// cannot collide with the shipped one — so the pollution is neutralised without touching
/// anything real. The `com.apple.dt.xctest.tool` defaults domain is a different matter: that
/// domain belongs to the test host itself, nothing shipped can read it, so FoundryX keys
/// found there are test litter by construction and are purged.
enum FoundryXTestBundleHygiene {

    /// A service the shipped app can never use, and that says why it exists if anyone finds
    /// it in a keychain. Fixed rather than UUID-namespaced so repeated runs reuse ONE item
    /// instead of accreting one per run, and so an interrupted run leaves at most that one.
    static let testKeychainService = "com.goforgeit.foundryx.auth.xctest-only"

    /// Every FoundryX-owned key the test host's own defaults domain can accumulate. Matched
    /// by prefix because account-scoped preferences are minted as `<scope>.foundryx.*`.
    private static func isFoundryXOwnedDefaultsKey(_ key: String) -> Bool {
        key.hasPrefix("foundryx.") || key.contains(".foundryx.")
    }

    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var observer: BundleObserver?

    static func installOnce() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }
        installed = true

        // (1) Shadow the production identity service for the whole bundle, then start from
        //     a clean item so a previous run's write cannot decide this run's resolution.
        AuthStore.setKeychainServiceForTests(testKeychainService)
        _ = AuthStore.eraseIdentityCredential()

        // (1b) Heal a machine an OLDER build already polluted. Shadowing stops new
        //      pollution but cannot un-write what is already there, and the poisoned
        //      machine here is also the self-hosted CI runner (same user, same login
        //      keychain), so every release gate on it inherits the fault.
        //      This is safe rather than presumptuous: FoundryX ships iOS-only
        //      (`SDKROOT = iphoneos` for every target in FoundryX.xcodeproj), so the
        //      shipped app cannot ever write a Mac LOGIN keychain. An item at that
        //      service on macOS was written by a test process, by construction.
        eraseLeakedProductionIdentityOnMac()

        // (2) Purge FoundryX litter from the test host's own defaults domain.
        purgeFoundryXDefaults()

        // (3) Leave the machine as we found it, so the NEXT run — and any other tool on
        //     this machine — starts clean too.
        let observer = BundleObserver()
        Self.observer = observer
        XCTestObservationCenter.shared.addTestObserver(observer)
    }

    /// Delete a leaked production identity item. macOS only — on an iOS test host the
    /// keychain is per-container and the shipped app's item is a legitimate, private thing.
    @discardableResult
    static func eraseLeakedProductionIdentityOnMac() -> OSStatus {
        #if os(macOS)
        return SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AuthStore.productionKeychainService,
            kSecAttrAccount as String: "identity",
        ] as CFDictionary)
        #else
        return errSecSuccess
        #endif
    }

    static func purgeFoundryXDefaults() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where isFoundryXOwnedDefaultsKey(key) {
            defaults.removeObject(forKey: key)
        }
        _ = defaults.synchronize()
    }

    /// Non-nil only when the bundle is still reachable from the production service — i.e.
    /// the install did not happen. Used by the guard test below.
    static var leakedProductionReachability: String? {
        AuthStore.effectiveKeychainService == AuthStore.productionKeychainService
            ? "the test bundle is still bound to \(AuthStore.productionKeychainService)"
            : nil
    }

    private final class BundleObserver: NSObject, XCTestObservation {
        func testBundleDidFinish(_ testBundle: Bundle) {
            _ = AuthStore.eraseIdentityCredential()
            FoundryXTestBundleHygiene.eraseLeakedProductionIdentityOnMac()
            FoundryXTestBundleHygiene.purgeFoundryXDefaults()
        }
    }
}

/// Named to sort first, but correctness does not depend on that — the install runs from
/// `defaultTestSuite`, i.e. during XCTest's discovery pass, before any test executes.
final class AAAAFoundryXTestBundleHygieneTests: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        FoundryXTestBundleHygiene.installOnce()
        return super.defaultTestSuite
    }

    func testHygieneRanBeforeAnyTestInThisBundle() {
        XCTAssertNil(
            FoundryXTestBundleHygiene.leakedProductionReachability,
            """
            the test bundle can still reach the SHIPPED identity keychain service. A test \
            that saves an identity would then leave a machine-global item behind, and every \
            later test process would resolve CaptureAccountScope to .blocked and silently \
            write no capture segments at all.
            """)
    }

    /// The load-bearing consequence, asserted directly rather than inferred: with the
    /// bundle hygienic, an unauthenticated capture fixture resolves to a REAL, writable
    /// signed-out root instead of the fail-closed one.
    func testAnUnauthenticatedFixtureResolvesToAWritableSignedOutRoot() throws {
        CaptureAccountScope.resetTestEnvironment()
        defer { CaptureAccountScope.resetTestEnvironment() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "foundryx-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNotNil(
            CaptureAccountScope.binding(forExplicitRoot: root),
            """
            an explicit capture root has no account binding, so every durable WAL write in \
            this process is a no-op. That is the signature of leaked machine-global identity \
            state, not of a bug in the suite that fails.
            """)
    }
}
