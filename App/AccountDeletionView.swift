import SwiftUI
import Grain
// NOTE: no `import FoundryXKit` — the app target compiles Sources/FoundryXKit directly into
// this same module, so AccountDeletionScope / AccountDeletionModel are already in scope.

// AccountDeletionView — the in-app account-deletion affordance (track T-STOREFRONT). Apple
// Guideline 5.1.1(v) requires an app that creates accounts to let the user DELETE the account
// from within the app. FoundryX offers the three scopes from the pure AccountDeletionScope
// (erase this phone / delete hosted Vault / delete everywhere), each behind a destructive
// confirmation. The model routes each scope to the right seam (LiveAccountDeletionService);
// this screen is presentation + confirmation only.
struct AccountDeletionView: View {
    @ObservedObject var model: AccountDeletionModel
    /// The current sign-in id_token for the hosted/everywhere paths (nil for a phone-only user,
    /// who can still erase this phone). RootView keeps it fresh.
    var idToken: () -> String?
    /// Called after a successful deletion so the app can return to a clean signed-out state.
    var onDeleted: (AccountDeletionScope) -> Void

    @State private var confirming: AccountDeletionScope?

    var body: some View {
        List {
            Section {
                Text("Delete what you choose — only the current account's local data, its hosted Vault, or the account everywhere. Other accounts and this phone's device setup are preserved.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            ForEach(AccountDeletionScope.allCases, id: \.self) { scope in
                Section {
                    Button(role: .destructive) { confirming = scope } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.title).grainTextStyle(.body)
                                .foregroundStyle(GrainColor.dangerRed)
                            Text(scope.subtitle)
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(isBusy)
                }
            }
            if case .failed(let scope) = model.phase {
                Section {
                    Text("Couldn't complete “\(scope.title).” Check your connection and try again.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.dangerRed)
                }
            }
            if case .blocked(let scope) = model.phase {
                Section {
                    Text("Deletion is pending. This account stays closed until cleanup finishes.")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                    Button("Retry deletion") {
                        Task { await run(scope) }
                    }
                    .disabled(isBusy)
                }
            }
        }
        .grainBackground()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isBusy { ProgressView().scaleEffect(1.3) } }
        .confirmationDialog(
            confirming.map(\.title) ?? "",
            isPresented: Binding(get: { confirming != nil },
                                 set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let scope = confirming {
                Button(scope.confirmLabel, role: .destructive) {
                    confirming = nil
                    Task { await run(scope) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        } message: {
            if let scope = confirming { Text(scope.subtitle) }
        }
    }

    private var isBusy: Bool {
        if case .deleting = model.phase { return true }
        return false
    }

    private func run(_ scope: AccountDeletionScope) async {
        await model.delete(scope: scope, idToken: idToken())
        if case .done(let s) = model.phase { onDeleted(s) }
    }
}

extension AccountDeletionModel {
    /// The production deletion model: wipes the on-device library locally, and calls the relay
    /// control plane (AccountClient → /account/delete) for the hosted-Vault / everywhere scopes.
    @MainActor static func live() -> AccountDeletionModel {
        let auth = FoundryAuth()
        let localDeletion = CurrentOwnerSelectiveDeletionRunner(
            containerProvider: { CaptureAccountScope.container() },
            defaults: .standard,
            secretStore: SystemPairingSecretStore(),
            pairingServices: (
                cell: "com.goforgeit.foundryx.cell",
                door: DoorConfigStore.service),
            exposureCoordinator: .process,
            identityProvider: { auth.signedInIdentity })
        let service = LiveAccountDeletionService(
            eraseLocal: {
                try await localDeletion.eraseVerifiedCurrentOwner()
            },
            deleteRemote: { scope, idToken in
                guard let token = idToken,
                      let base = RemoteConfig.fromBundle()?.gatewayHTTPURL else {
                    throw AccountDeletionError.server   // fail loud — no silent no-op
                }
                try await AccountClient(baseURL: base).deleteAccount(scope: scope, idToken: token)
            })
        return AccountDeletionModel(service: service)
    }
}
