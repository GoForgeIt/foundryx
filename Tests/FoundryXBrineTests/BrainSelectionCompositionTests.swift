import XCTest
import Foundation
@testable import FoundryXKit

/// THE APP-SIDE HALF OF THE BRAIN-SELECTION FIX.
///
/// `swift test` compiles the SPM package only — it cannot see `App/` at all — so the
/// behavioural scenarios in `features/vault-funnel.feature` prove the MODEL moves the
/// brain, and nothing they can do proves the app is wired to that model. Both defects
/// this file holds were exactly that shape: a correct type, correctly tested, connected
/// to nothing.
///
///   * TWO CellStores. `App/RootView.swift` built one (the gate's `cellPaired`) and
///     `VaultFunnelModel.live()` built another (the one the funnel PAIRED into). They
///     share durable keys, so the pairing survived a relaunch and the bug looked like
///     "you have to restart the app" rather than a split instance.
///   * The live screen's "Enter" called `model.dismiss()`. The Brine step drives
///     `enterVault()`; if the button drifts back, the step keeps passing about a code
///     path no user can reach.
///
/// These are source-text gates, in the house style of `DeviceCompositionRootGateTests`,
/// and each one asserts NON-VACUITY first: if the composition root moves out of these
/// files, the gate says so instead of passing because it found nothing to check.
final class BrainSelectionCompositionTests: XCTestCase {

    private func appSource(_ path: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Comments are stripped and string literals blanked: prose naming a call, or a
        // log line quoting it, is not a call.
        return AppSourceTree.code(of: text)
    }

    // MARK: - one CellStore

    func testExactlyOneCellStoreIsConstructedAppSide() throws {
        let constructors = try AppSourceTree.filesContaining("CellStore(")
        XCTAssertEqual(
            constructors, ["App/RootView.swift"],
            "the cell pairing must be built ONCE, at the composition root, and injected. "
                + "A second `CellStore()` is not a duplicate object with a shared file — "
                + "it is a second @Published, and whichever one the Vault funnel pairs "
                + "into is the one the router is not watching. Constructed in: "
                + "\(constructors)")

        let funnelView = try appSource("App/VaultFunnelView.swift")
        XCTAssertTrue(
            funnelView.contains("static func live(cellStore: CellStore"),
            "VaultFunnelModel.live() must TAKE the shared CellStore — this gate is "
                + "checking a factory that no longer exists")

        let rootView = try appSource("App/RootView.swift")
        XCTAssertTrue(
            rootView.contains("VaultFunnelModel.live("),
            "the app no longer builds its Vault funnel in App/RootView.swift — this gate "
                + "is checking a file that no longer holds the composition root")
        XCTAssertTrue(
            rootView.contains("cellStore: cells"),
            "App/RootView.swift builds the Vault funnel without handing it the SAME "
                + "CellStore the gate reads (`cells`)")
    }

    // MARK: - the gate observes the brain

    func testTheRouterObservesTheStoresItRoutesOn() throws {
        let rootView = try appSource("App/RootView.swift")

        // Non-vacuity: the routing decision still lives here, and still reads these stores.
        XCTAssertTrue(rootView.contains("RootGate.destination("),
                      "App/RootView.swift no longer makes the routing decision")
        XCTAssertTrue(rootView.contains("brain: brains.choice"),
                      "the router no longer routes on BrainStore.choice")
        // THIS LINE USED TO READ `XCTAssertTrue(rootView.contains("cellPaired: cells.isPaired"))`,
        // AND THAT ASSERTION COULD NOT FAIL. `cellPaired: cells.isPaired && false)` still
        // CONTAINS that substring, so the mutation that makes the paired-vault rung unreachable
        // in the shipping app left the whole suite green — and `swift test` cannot compile
        // `App/` to catch it any other way. Found by adversarial cross-vendor review, confirmed
        // by reading both files. `BrainSelectionCallSiteRule` is the same question asked so that
        // the answer can be no, and `BrainSelectionCallSiteRuleTests` proves it goes RED on that
        // exact mutation and on the rest of its family.
        let arming = BrainSelectionCallSiteRule.verdict(for: rootView)
        guard case .ok = arming else {
            return XCTFail("""
            the router no longer routes on the cell pairing (verdict: \(arming)). That rung is \
            what keeps a chosen-but-unresolved brain from falling all the way to the tier whose \
            uploads are self-issued ACKs, so a neutralised argument here is silent data loss.
            """)
        }

        // The mechanism. `brains` is reached through a computed property over the
        // composition root, and `select()` publishes on BrainStore — not on the object
        // SwiftUI is subscribed to. Without an explicit forward, a brain switch moved the
        // gate only when some unrelated publisher happened to re-run the body: Settings'
        // checkmark moved instantly (it holds BrainStore as @ObservedObject) while the app
        // kept running on the old brain.
        XCTAssertTrue(
            rootView.contains("objectWillChange") && rootView.contains("forward("),
            "the composition root does not forward its children's objectWillChange, so "
                + "picking a brain in Settings does not re-decide the destination")
        for forwarded in ["forward(brains)", "forward(cells)", "forward(vaultFunnel)"] {
            XCTAssertTrue(rootView.contains(forwarded),
                          "App/RootView.swift does not \(forwarded) — that store can "
                              + "change without the router noticing")
        }
        // An identity boundary REPLACES the BrainStore. A forward set that is not rebuilt
        // leaves the router subscribed to the previous account's store.
        XCTAssertTrue(
            rootView.contains("forward(replacement)"),
            "the replacement BrainStore installed at an identity boundary is never "
                + "observed — the router would stay subscribed to the prior account's store")
    }

    // MARK: - "Enter" enters

    func testTheLiveScreensEnterButtonEntersTheVault() throws {
        let funnelView = try appSource("App/VaultFunnelView.swift")
        XCTAssertTrue(
            funnelView.contains("GrainButton(") && funnelView.contains("model.enterVault()"),
            "the live screen's primary button does not call enterVault() — the Brine step "
                + "\"they enter their live Vault\" would then be driving a code path the "
                + "button never reaches")
        XCTAssertFalse(
            funnelView.contains("size: .lg) { model.dismiss() }"),
            "the live screen's Enter button is back to closing the sheet without moving "
                + "the app onto the Vault")
        XCTAssertTrue(
            funnelView.contains("selectVaultBrain: selectVaultBrain"),
            "the app never hands the funnel a way to select the Vault brain, so "
                + "enterVault() is a no-op in the shipped build")
        let rootView = try appSource("App/RootView.swift")
        XCTAssertTrue(
            rootView.contains("select(.foundryCloud)"),
            "the composition root's brain-selection seam does not select the cloud brain")
    }

    /// The tour's destination step writes the brain. It used to be handed
    /// `brains ?? BrainStore()` — a throwaway store that swallows the choice with nothing
    /// red anywhere. Every brain-writing surface must be handed the app's real store.
    func testNoBrainWritingSurfaceIsHandedAThrowawayStore() throws {
        let flow = try appSource("App/OnboardingFlowView.swift")
        XCTAssertTrue(flow.contains("OnboardingDestinationStep("),
                      "the destination step is no longer presented here — this gate is "
                          + "checking a file that no longer hands out a BrainStore")
        XCTAssertFalse(
            flow.contains("?? BrainStore()"),
            "App/OnboardingFlowView.swift falls back to a throwaway BrainStore, so the "
                + "tour's destination choice would be written where nothing reads it")
        for file in try AppSourceTree.filesContaining("?? BrainStore()") {
            XCTFail("\(file) defaults a BrainStore at a call site — a selection written "
                        + "there is discarded")
        }
    }

    // MARK: - the pure rules

    func testTheCloudRowsAreMutuallyExclusiveAcrossEveryEntitlement() {
        for entitlement in [VaultEntitlement.off, .live, .unknown] {
            XCTAssertFalse(
                VaultSettingsPresentation.showWaitlist(entitlement: entitlement)
                    && VaultSettingsPresentation.showCellBrain(entitlement: entitlement),
                "entitlement \(entitlement) would draw both a 'coming soon' waitlist and a "
                    + "live Vault brain in the same BRAIN section")
        }
        XCTAssertTrue(VaultSettingsPresentation.showCellBrain(entitlement: .live))
        XCTAssertFalse(VaultSettingsPresentation.showCellBrain(entitlement: .off))
        XCTAssertFalse(
            VaultSettingsPresentation.showCellBrain(entitlement: .unknown),
            "an unknown entitlement must not offer a brain we cannot say exists")
    }

    /// The gate's own rule, held here so the funnel's arrival cannot be quietly undone by
    /// a change on the ROUTING side: a chosen cloud brain with no pairing degrades to the
    /// phone, and a chosen cloud brain WITH a pairing beats a resolved desktop door.
    func testTheCloudChoiceOnlyRoutesToTheCellWhenAVaultIsPaired() {
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: true, brain: .foundryCloud,
                                 hostResolved: true, letStraightIn: true, cellPaired: false),
            .phoneBrain,
            "a cloud brain with nothing paired must degrade, not strand the user on a "
                + "brain that cannot serve")
        XCTAssertEqual(
            RootGate.destination(signedIn: true, splashElapsed: true, brain: .foundryCloud,
                                 hostResolved: true, letStraightIn: true, cellPaired: true),
            .cellBrain,
            "a paying owner who picked their Vault must land in it even with a desktop "
                + "door resolved")
    }
}
