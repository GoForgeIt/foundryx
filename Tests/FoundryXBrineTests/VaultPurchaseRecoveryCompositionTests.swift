import XCTest
import Foundation
@testable import FoundryXKit

/// THE APP-SIDE HALF of the Vault purchase-recovery fixes.
///
/// `swift test` compiles the SPM package only — it cannot see `App/` at all — so
/// `features/vault-purchase-recovery.feature` proves the MODEL and the COPY, and nothing
/// it can do proves a screen reaches either. Three of the four defects it covers were
/// exactly that shape: a state nothing rendered, a benefits list nothing showed, and a
/// chevron whose destination did not exist.
///
/// House style (`BrainSelectionCompositionTests`, `DeviceCompositionRootGateTests`): source
/// gates that assert NON-VACUITY first, so a moved composition root fails loudly instead of
/// passing because the gate found nothing to look at.
final class VaultPurchaseRecoveryCompositionTests: XCTestCase {

    private func appSource(_ path: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Comments stripped, string literals kept: prose naming a call is not a call, but
        // the copy a screen renders IS a string literal.
        return AppSourceTree.code(of: text)
    }

    // MARK: - defect 1: the abandoned-checkout screen is reachable

    func testTheFunnelRendersTheAbandonedCheckoutRecovery() throws {
        let funnel = try appSource("App/VaultFunnelView.swift")
        XCTAssertTrue(
            funnel.contains("switch model.state"),
            "App/VaultFunnelView.swift no longer switches on the funnel state — this gate "
                + "is checking a file that no longer renders the funnel")
        XCTAssertTrue(
            funnel.contains("case .checkoutIncomplete"),
            "the funnel view has no arm for .checkoutIncomplete, so the recovery state the "
                + "model can now reach renders as a BLANK SCREEN — worse than the dead end "
                + "it replaced")
        XCTAssertTrue(
            funnel.contains("model.resumeCheckout()"),
            "nothing in the funnel view calls resumeCheckout() — 'pick up where you left "
                + "off' would be a model API with no button attached to it")
        XCTAssertTrue(
            funnel.contains("model.seePlans()"),
            "the recovery screen offers no way to choose a different plan")
    }

    // MARK: - defect 3: the live screen says what you can do now

    func testTheLiveScreenRendersWhatTheVaultActuallyDoes() throws {
        let funnel = try appSource("App/VaultFunnelView.swift")
        XCTAssertTrue(
            funnel.contains("VaultLiveBenefits.items"),
            "the live screen does not render VaultLiveBenefits — the owner is told their "
                + "Vault is live and nothing about what $79 changed")
        // The old hardcoded body must not sit alongside the honest list saying something else.
        XCTAssertFalse(
            funnel.contains("\"Your Vault is live\"") && !funnel.contains("presentation.title"),
            "the live screen hardcodes its title instead of rendering the tested copy, so "
                + "the scenarios would assert a string no screen shows")
    }

    /// The one promise this build must never print on the success screen. Chat through the
    /// cell answers 503 and nothing pulls recordings off a Pocket.
    func testNoUnshippedCapabilityIsPromisedByTheLiveCopy() {
        let text = (VaultLiveBenefits.items.map(\.line)
                    + [VaultLiveBenefits.summary]
                    + VaultFunnelCopy.presentation(
                        for: .live(CellConfig(url: "https://v.example", auth: .bearer("b")))
                    ).details)
            .joined(separator: " ")
            .lowercased()
        for word in ["chat", "pocket", "sync", "agent", "playbook"] {
            XCTAssertFalse(
                text.contains(word),
                "the live Vault copy promises \"\(word)\", which this build does not do: \(text)")
        }
        XCTAssertTrue(text.contains("recording"), "the copy dropped the capture change")
        XCTAssertTrue(text.contains("search"), "the copy dropped full-history search")
    }

    // MARK: - defect 4: the chevron leads somewhere

    func testTheSettingsVaultRowLeadsToTheVaultDetail() throws {
        let settings = try appSource("App/SettingsScreen.swift")
        XCTAssertTrue(
            settings.contains("vaultFunnel.statusPresentation"),
            "App/SettingsScreen.swift no longer builds the Vault row from the funnel's "
                + "durable status — this gate is checking a file that no longer draws it")
        XCTAssertTrue(
            settings.contains("VaultDetailView("),
            "the Settings Vault row does not lead to a Vault detail. A chevron is a promise "
                + "that there is somewhere to go; tapping the live row called "
                + "activateFromSettings(), which returns immediately for a live Vault")
        XCTAssertTrue(
            settings.contains(".openVaultDetail"),
            "nothing in Settings distinguishes the row that navigates from the row that "
                + "opens the funnel sheet, so the detail is unreachable or the sheet is")

        let detail = try appSource("App/VaultDetailView.swift")
        XCTAssertTrue(
            detail.contains("VaultDetail.presentation("),
            "App/VaultDetailView.swift does not render the tested VaultDetail presentation")
        XCTAssertTrue(
            detail.contains("AccountDeletionView("),
            "the Vault detail cannot delete the Vault it describes")
        XCTAssertTrue(
            detail.contains("model.enterVault()") || detail.contains("vaultFunnel.enterVault()"),
            "the Vault detail cannot move the app onto the Vault")
        XCTAssertTrue(
            detail.contains("select(.justMyPhone)"),
            "the Vault detail is a one-way door — no route back to the phone brain")
    }

    // NOTE ON DEFECT 2 (the hand-back). There is deliberately no source gate here. The
    // app-side half — that the URL handed to the browser always carries
    // `return=foundryx://vault/return` and the attempt id, whether or not the service
    // supplied its own checkout URL — is proved BEHAVIOURALLY by
    // "checkout always carries the way back into the app" in
    // features/vault-purchase-recovery.feature, which drives the real model through a
    // browser seam that records what it was asked to open. A source gate over the same
    // thing could only be vacuous next to it.
}
