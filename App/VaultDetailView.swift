import SwiftUI
import Grain
// NOTE: no `import FoundryXKit` — the app target compiles Sources/FoundryXKit directly into
// this same module (project.yml), so VaultDetail, VaultLiveBenefits, VaultFunnelModel,
// BrainStore and AccountDeletionModel are already in scope.

// VaultDetailView — WHERE THE CHEVRON GOES.
//
// The Settings row "Your Vault is live / Your private Vault is ready." wore a chevron and
// did nothing at all when tapped: it called `vaultFunnel.activateFromSettings()`, which
// returns immediately for a live Vault ("there is nothing to turn on"). A chevron is a
// promise that there is somewhere to go, so this is the somewhere: what state the Vault is
// in, what it actually holds, and how to manage or delete it.
//
// Content comes from `VaultDetail.presentation(entitlement:host:)` — pure and gated by
// features/vault-purchase-recovery.feature — so this file stays a renderer.
struct VaultDetailView: View {
    @ObservedObject var vaultFunnel: VaultFunnelModel
    @ObservedObject var brains: BrainStore
    @ObservedObject var accountDeletion: AccountDeletionModel
    /// The current sign-in id_token, for the deletion leg that talks to the server.
    var idToken: () -> String?
    /// Called after a deletion that ends the session, so the app can return to a clean state.
    var onDeleted: (AccountDeletionScope) -> Void
    /// Dismiss back to Settings after an action that changes where the app runs.
    var onLeave: () -> Void = {}

    var body: some View {
        List {
            if let detail = VaultDetail.presentation(
                entitlement: vaultFunnel.entitlement, host: vaultHost) {
                Section {
                    HStack(spacing: GrainSpacing.x2) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(GrainColor.sage)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.title).grainTextStyle(.body)
                                .foregroundStyle(GrainColor.ink)
                            Text(detail.stateLine)
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("vault-detail-state")
                } header: {
                    GrainSectionEyebrow("STATE")
                }

                Section {
                    ForEach(detail.holds, id: \.title) { item in
                        HStack(spacing: GrainSpacing.x3) {
                            Image(systemName: item.icon).frame(width: 24)
                                .foregroundStyle(GrainColor.forgeBlue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).grainTextStyle(.body)
                                    .foregroundStyle(GrainColor.ink)
                                Text(item.detail)
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } header: {
                    GrainSectionEyebrow("WHAT IT HOLDS")
                } footer: {
                    Text("Only what this build actually does. Anything else you've heard about a Vault isn't on yet.")
                }

                Section {
                    ForEach(detail.manage, id: \.title) { action in
                        manageRow(action)
                    }
                } header: {
                    GrainSectionEyebrow("MANAGE")
                }
            } else {
                // Defensive: the row that leads here is only drawn for a live Vault, but an
                // entitlement can change under an open screen (sign-out, identity switch).
                // Say so rather than rendering an empty page.
                Section {
                    Text("This iPhone isn't connected to a Vault right now.")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                }
            }
        }
        .grainBackground()
        .navigationTitle("Your Vault")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func manageRow(_ action: VaultDetail.Manage) -> some View {
        switch action.kind {
        case .deleteVault:
            // The Apple-required deletion page, where "Delete your hosted Vault" is one of
            // three scopes. Reached from here so the Vault can be managed where it is
            // described, not only from the Account section.
            NavigationLink {
                AccountDeletionView(model: accountDeletion,
                                    idToken: idToken,
                                    onDeleted: onDeleted)
            } label: {
                rowLabel(action)
            }
        case .enterVault:
            Button {
                vaultFunnel.enterVault()
                onLeave()
            } label: {
                rowLabel(action)
            }
            .buttonStyle(.plain)
            .disabled(brains.choice == .foundryCloud)
        case .useThisPhone:
            Button {
                // The way back off the Vault brain, from the page that describes it.
                brains.select(.justMyPhone)
                onLeave()
            } label: {
                rowLabel(action)
            }
            .buttonStyle(.plain)
            .disabled(brains.choice == .justMyPhone)
        }
    }

    private func rowLabel(_ action: VaultDetail.Manage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(action.title).grainTextStyle(.body)
                .foregroundStyle(action.destructive ? GrainColor.dangerRed : GrainColor.ink)
            Text(action.detail).grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// WHICH Vault, in the only terms that are safe to show: the door's host. The bearer
    /// and the full URL never appear on a screen.
    private var vaultHost: String? {
        vaultFunnel.connectedVaultHost
    }
}
