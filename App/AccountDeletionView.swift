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
    /// Presented for `.everywhere` INSTEAD of a straight confirmation: that scope is
    /// the only one with a billing dimension, so it is the only one that asks.
    @State private var choosingOutcome = false
    /// The erase-progress page. Presented for anything that erases THIS phone,
    /// which is the operation that takes real time and can refuse mid-way.
    @State private var showingProgress = false
    /// What to re-run when the progress page offers "Try again".
    @State private var lastScope: AccountDeletionScope?
    @State private var lastChoice: DeletionOutcomeChoice?

    var body: some View {
        List {
            Section {
                Text("Delete what you choose — the current account's local data, its hosted Vault, or the account everywhere. Other accounts stay intact. Immediate account deletion also clears shared device pairings and capture shortcuts so they cannot cross accounts.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            ForEach(AccountDeletionScope.allCases, id: \.self) { scope in
                Section {
                    // ONLY the title is tappable. The explanation used to sit INSIDE this
                    // destructive button, making the whole five-line card a tap target for
                    // an irreversible action — you could fire it while reading the sentence
                    // telling you what it does. Guidance belongs in the footer; the hint
                    // keeps it on the button for VoiceOver, which reads label then hint.
                    Button(role: .destructive) {
                        // "Everywhere" is the only scope with a subscription to decide
                        // about, so it asks instead of assuming "destroy it all today".
                        if scope == .everywhere { choosingOutcome = true } else { confirming = scope }
                    } label: {
                        Text(scope.title).grainTextStyle(.body)
                            .foregroundStyle(GrainColor.dangerRed)
                    }
                    .disabled(isBusy)
                    .accessibilityHint(scope.subtitle)
                } footer: {
                    Text(scope.subtitle)
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .scheduled(let when) = model.phase {
                Section {
                    Text("Your subscription won't renew, and everything you've written will be deleted on \(Self.dayFormatter.string(from: when)). Nothing has been deleted yet.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
            }
            if case .subscriptionCancelled = model.phase {
                Section {
                    Text("Your subscription is cancelled. Every note you've written is still here, and you can start paying again whenever you want.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
            }
            if case .failed(let scope) = model.phase {
                Section {
                    Text("Couldn't complete “\(scope.title).” Check your connection and try again.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.dangerRed)
                }
            }
            // An auth failure is NOT a connection failure. Both used to render the
            // sentence above, which sent the user to fix the one thing that was working.
            // A 404 is not a connection failure. The route exists server-side now,
            // so this means the app is pointed somewhere that isn't serving it —
            // still not something the person can fix by retrying.
            if case .routeMissing(let scope) = model.phase {
                Section {
                    Text("Couldn't complete “\(scope.title).” The server isn't offering deletion at the address this app is using, so retrying won't help and your connection is fine. Nothing was deleted. “Erase this account's local data” still works and clears everything on this iPhone.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.dangerRed)
                }
            }
            if case .signInExpired(let scope) = model.phase {
                Section {
                    Text("Couldn't complete “\(scope.title).” Your sign-in expired — sign out and back in, then try again. Nothing was deleted.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.dangerRed)
                }
            }
            // BOTH retries below finish the LOCAL erase and never re-run the
            // server leg. The account is already gone server-side by the time
            // either phase is reachable, so re-running the remote call meant a
            // 404 → "route missing" → the local erase was never reached, and the
            // only button offered for a pending cleanup could never clear it.
            if case .blocked(let scope) = model.phase {
                Section {
                    Text("Deletion is pending. This account stays closed until cleanup finishes. Your account is already deleted on our servers — only this iPhone is left to erase.")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                    Button("Finish erasing this iPhone") {
                        Task { await retryLocal(scope) }
                    }
                    .disabled(isBusy)
                }
            }
            if case .incomplete(let scope, let stage, let reason) = model.phase {
                Section {
                    Text("Deletion is incomplete at \(stage): \(reason). This account stays closed until every erase step finishes. Your account is already deleted on our servers — only this iPhone is left to erase.")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                    Button("Finish erasing this iPhone") {
                        Task { await retryLocal(scope) }
                    }
                    .disabled(isBusy)
                }
            }
        }
        .grainBackground()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        // The bare spinner survives ONLY for the operations with no local steps
        // to show (the hosted Vault, a scheduled deletion, a cancellation) — a
        // short server round trip, not a multi-minute destructive walk.
        .overlay { if isBusy && !showingProgress { ProgressView().scaleEffect(1.3) } }
        // NO bare spinner for the erase. Erasing an account walks thirteen named steps and can
        // refuse at any of them; a `ProgressView()` over the whole screen said
        // nothing about what had already been destroyed, and a refusal collapsed
        // into one line naming a step that does not exist.
        .sheet(isPresented: $showingProgress) {
            NavigationStack {
                AccountDeletionProgressView(
                    model: model.progress,
                    onRetry: { Task { await retryLast() } },
                    onClose: { showingProgress = false })
            }
            .interactiveDismissDisabled(model.progress.presentation.isRunning)
        }
        .sheet(isPresented: $choosingOutcome) {
            DeletionOutcomeChoiceView(
                onPick: { choice in
                    choosingOutcome = false
                    Task { await runChoice(choice) }
                },
                onCancel: { choosingOutcome = false })
        }
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

    /// Day-precision because the person is being told a DATE, not an instant.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private func runChoice(_ choice: DeletionOutcomeChoice) async {
        lastChoice = choice
        lastScope = nil
        // The progress page is for the erase. A scheduled deletion or a plain
        // cancellation destroys nothing today, so it gets no erase page.
        if choice == .deleteNow { showingProgress = true }
        await model.delete(scope: .everywhere, choice: choice, idToken: idToken())
        // ONLY an immediate deletion signs the person out — after a schedule or a
        // cancel their account still exists and their notes are still here.
        if case .done(let s) = model.phase { onDeleted(s) }
    }

    private func run(_ scope: AccountDeletionScope) async {
        lastScope = scope
        lastChoice = nil
        // The hosted Vault lives on the server; nothing on this phone is erased,
        // so there are no local steps to show.
        showingProgress = scope != .hostedVault
        await model.delete(scope: scope, idToken: idToken())
        if case .done(let s) = model.phase { onDeleted(s) }
    }

    /// Finish a deletion whose server side is already gone. The remote leg is
    /// deliberately NOT re-run — see `AccountDeletionModel.awaitsLocalRetryOnly`.
    private func retryLocal(_ scope: AccountDeletionScope) async {
        lastScope = scope
        lastChoice = nil
        showingProgress = true
        await model.retryLocalErase(scope: scope)
        if case .done(let s) = model.phase { onDeleted(s) }
    }

    /// "Try again" from the progress page re-runs exactly what is still left to
    /// do — which, once the erase has stopped locally, is the local erase ONLY.
    private func retryLast() async {
        if model.awaitsLocalRetryOnly {
            await retryLocal(lastScope ?? .everywhere)
        } else if let choice = lastChoice {
            await runChoice(choice)
        } else if let scope = lastScope {
            await run(scope)
        }
    }
}

/// The deployed foundry-signup service — the owner of tenants, cells and Stripe,
/// and so of deletion. File-level rather than a member of the main-actor-isolated
/// model, so the `deleteRemote` closure can read it off the main actor.
private let signupServiceBase =
    URL(string: "https://foundry-signup-449450484577.us-central1.run.app")!

extension AccountDeletionModel {

    /// The production deletion model: wipes the on-device library locally, and calls the relay
    /// control plane (AccountClient → /account/delete) for the hosted-Vault / everywhere scopes.
    /// `record` receives every deletion attempt and outcome. Wired to the DoorLog
    /// (which ships to the relay's /diag/log → Cloud Logging) so the record LEAVES
    /// the device — the local store is exactly what a deletion destroys, so a record
    /// kept there would vanish with the thing it documents.
    ///
    /// The success case is also recorded SERVER-side before anything is destroyed
    /// (fail-closed audit), so what this covers is the attempts that never reach the
    /// server at all: an expired sign-in, a missing route, a dead network. Those are
    /// exactly the cases where nothing is erased and the 15s diag flush still runs.
    @MainActor static func live(record: @escaping @Sendable (String, String) -> Void = { _, _ in }) -> AccountDeletionModel {
        let auth = FoundryAuth()
        // The lifecycle already announces every step by name. Handing that stream
        // to the progress model is the whole of the "what is it doing right now?"
        // screen — nothing here re-derives or guesses at a step.
        let progress = AccountDeletionProgressModel()
        let localDeletion = CurrentOwnerSelectiveDeletionRunner(
            containerProvider: { CaptureAccountScope.container() },
            defaults: .standard,
            secretStore: SystemPairingSecretStore(),
            pairingServices: (
                cell: "com.goforgeit.foundryx.cell",
                door: DoorConfigStore.service),
            exposureCoordinator: .process,
            identityProvider: { auth.signedInIdentity },
            progress: { event in progress.report(event) })
        let service = LiveAccountDeletionService(
            eraseLocal: {
                try await localDeletion.eraseVerifiedCurrentOwner()
            },
            deleteRemote: { scope, idToken in
                // The SIGNUP service, not the relay: it owns the tenants, cells and
                // Stripe that deletion destroys. It is also a compiled-in constant
                // rather than bundle config, so a missing RemoteConfig no longer
                // makes deletion impossible.
                let base = signupServiceBase
                // REFRESH at request time. `idToken` here is `remote.idToken`, a snapshot
                // taken at the last session resolve — nil whenever that refresh failed,
                // and stale after an hour. Deleting an account is a rare, deliberate act
                // that can easily happen long after the last resolve, so signing it with
                // the snapshot meant the request never left the phone and the user was
                // told to check a connection that was fine.
                let token = (try? await FoundryAuth().currentIdToken()) ?? idToken
                guard let token, !token.isEmpty else {
                    throw AccountDeletionError.signInExpired
                }
                try await AccountClient(baseURL: base).deleteAccount(scope: scope, idToken: token)
            },
            deleteRemoteChoice: { choice, idToken in
                let token = (try? await FoundryAuth().currentIdToken()) ?? nil
                guard let token, !token.isEmpty else {
                    throw AccountDeletionError.signInExpired
                }
                return try await AccountClient(baseURL: signupServiceBase)
                    .deleteAccount(choice: choice, idToken: token)
            })
        return AccountDeletionModel(
            service: service, record: record, progress: progress)
    }
}

/// The three-way choice for "delete my account everywhere".
///
/// This screen exists because the app used to offer exactly one way to leave —
/// destroy everything today — and someone who wanted to stop paying but keep
/// their notes, or to use the period they'd already paid for, had no way to say
/// so. The irreversibility warning is per-choice: saying "this can't be undone"
/// about cancelling a subscription would simply be false.
struct DeletionOutcomeChoiceView: View {
    var onPick: (DeletionOutcomeChoice) -> Void
    var onCancel: () -> Void

    @State private var confirming: DeletionOutcomeChoice?

    /// Extracted so the type-checker isn't asked to solve the whole List at once.
    @ViewBuilder
    private func choiceButton(_ choice: DeletionOutcomeChoice) -> some View {
        let tint: Color = choice.isIrreversible ? GrainColor.dangerRed : GrainColor.textMain
        Button(role: choice.isIrreversible ? ButtonRole.destructive : nil) {
            confirming = choice
        } label: {
            Text(choice.title)
                .grainTextStyle(.body)
                .foregroundStyle(tint)
        }
        .accessibilityHint(choice.detail)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("What should happen to your subscription and your notes?")
                        .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                }
                ForEach(DeletionOutcomeChoice.allCases, id: \.self) { choice in
                    Section {
                        // Same discipline as the scope list: only the title is the
                        // tap target, so the sentence explaining an irreversible
                        // action can't itself trigger it.
                        choiceButton(choice)
                    } footer: {
                        Text(choice.detail)
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .grainBackground()
            .navigationTitle("Delete your account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .confirmationDialog(
                confirming?.title ?? "",
                isPresented: Binding(get: { confirming != nil },
                                     set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                if let choice = confirming {
                    Button(choice.title, role: choice.isIrreversible ? .destructive : nil) {
                        let picked = choice
                        confirming = nil
                        onPick(picked)
                    }
                    Button("Back", role: .cancel) { confirming = nil }
                }
            } message: {
                if let choice = confirming { Text(choice.detail) }
            }
        }
    }
}
