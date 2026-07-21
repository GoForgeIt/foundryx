// SettingsScreen — the brain picker + Action Button choice (track 20260705T1100,
// Phases 5/6). Spec §5: "Just my phone" (free, default, zero content egress) ·
// "My computer" (desktop Foundry via the door) · "Foundry Cloud — your cell"
// (waitlist until it ships). Switching is ADDITIVE: picking a computer replay-
// seeds it from the local library (Phase 7); leaving it returns to local-only
// with everything still readable.

import SwiftUI
import Grain

struct SettingsScreen: View {
    @ObservedObject var brains: BrainStore
    @ObservedObject var remote: RemoteSession
    // Device management lives here now (Nick 2026-07-14) as a "Devices & connections"
    // page, not a competing bottom tab.
    @ObservedObject var device: DeviceManager
    @ObservedObject var manager: CaptureManager
    @ObservedObject var sources: CaptureSourceRegistry
    /// The Vault activation funnel (track T-IOS-VAULT-ENTRY): the "Your Vault" row below is
    /// the low-collision entry point that launches it. Observed so the row flips to the
    /// connected state the moment the Vault goes live.
    @ObservedObject var vaultFunnel: VaultFunnelModel
    /// The in-app account-deletion model (track T-STOREFRONT) — Apple-required deletion,
    /// three scopes. Drives the "Delete account" affordance in the Account section.
    @ObservedObject var accountDeletion: AccountDeletionModel
    @State private var actionChoice = ActionButtonChoice.current
    @State private var waitlistJoined =
        UserDefaults.standard.bool(forKey: "foundryx.waitlist.joined")
    @State private var ambientEnabled =
        UserDefaults.standard.bool(forKey: AmbientPrefs.enabledKey)
    @State private var agentName =
        UserDefaults.standard.string(forKey: AmbientPrefs.agentNameKey) ?? ""
    @State private var fullContextGrading = AmbientPrefs.fullContextGrading()
    /// Intelligent Action: surface OTHER people's action lines inline (ON) vs
    /// collect them under "Heard from others" (OFF, the owner-first default).
    @State private var othersInline = ActionSurfacePolicy.othersInline()
    /// The in-app performance overlay toggle (track 20260717T0600 T3). DEFAULT OFF;
    /// flipping it takes effect live (the overlay model reads the pref per line).
    @State private var perfOverlayEnabled = DiagPrefs.perfOverlayEnabled()
    @State private var showingTour = false
    @State private var letStraightIn = WelcomePrefs.letStraightIn()
    @State private var persona = PersonaPrefs.persona()
    /// B5 (track 20260714T1800): a tokenless (phone-only) user tapping the
    /// waitlist gets the sign-in sheet first; the POST fires on sign-in success;
    /// a dismissed sign-in leaves the honest "Sign in to join" caption.
    @State private var showingWaitlistSignIn = false
    @State private var waitlistSignInDismissed = false
    /// The sign-in-only Vault entry (track T-STOREFRONT): where the App Store storefront
    /// disallows purchasing, the "Your Vault" row offers sign-in (open an existing Vault),
    /// never the purchase funnel.
    @State private var showingVaultSignIn = false
    /// Signed-out Account affordance: the "Sign in" button presents the sign-in
    /// sheet so a signed-out user can get back in (e.g. to switch accounts).
    @State private var showingAccountSignIn = false

    /// A glanceable one-line status for the Devices row (the deeper page has the detail).
    private var deviceStatusSubtitle: String {
        if case .connected = device.connectionState { return "Omi connected" }
        return "Omi, phone mic, and your computer"
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DeviceScreen(device: device, manager: manager, sources: sources, remote: remote)
                        .navigationTitle("Devices")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack(spacing: GrainSpacing.x2) {
                        Image(systemName: "earbuds")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Devices & connections").grainTextStyle(.body)
                            Text(deviceStatusSubtitle)
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                        }
                    }
                }
            }
            Section {
                brainRow(.justMyPhone,
                         subtitle: "Free. Recordings, transcripts, and summaries never leave this phone.")
                // LIVE connection info in-app (track 20260715T1502, Nick 2026-07-16:
                // status lives on the welcome or in the app — this is the in-app home,
                // what a straight-in user glances instead of any gate).
                brainRow(.myComputer, subtitle: computerBrainSubtitle)
                // The hosted cell's consumer entrypoint (proposal
                // 20260630T0458_secure_web_hosted_foundry) — waitlist until it ships.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Foundry Cloud — your cell").grainTextStyle(.body)
                            .foregroundStyle(GrainColor.textMuted)
                        Text("Coming soon. Speakers, memory, and bigger models — from anywhere.")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        // Never disabled for a tokenless user (B5) — tapping
                        // routes through sign-in instead of silently no-opping.
                        Button(waitlistJoined ? "On the list ✓" : "Join waitlist") { joinWaitlist() }
                            .disabled(waitlistJoined)
                        if !waitlistJoined, waitlistSignInDismissed, remote.idToken == nil {
                            Text(WaitlistJoin.signInCaption)
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                        }
                    }
                }
            } header: {
                GrainSectionEyebrow("BRAIN")
            }

            // The Vault activation entry (track T-IOS-VAULT-ENTRY): the low-collision launch
            // point for the funnel. Off ⇒ "Turn on your Vault" taps into the funnel intro;
            // live ⇒ the row reflects the connected Vault.
            Section {
                vaultEntryRow
            } header: {
                GrainSectionEyebrow("YOUR VAULT")
            }

            Section {
                HStack {
                    Text("Appearance").grainTextStyle(.body)
                    Spacer()
                    Text("Follows your device")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                }
            } footer: {
                Text("Light by day, Night Shift when your device switches to dark. One design, two renditions.")
            }

            Section {
                Picker("When pressed", selection: $actionChoice) {
                    ForEach(ActionButtonChoice.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .onChange(of: actionChoice) { c in ActionButtonChoice.current = c }
                Text("Bind “FoundryX Action” to the Action Button, Control Center, or back-tap in iOS Settings; Siri: “Start FoundryX recording”.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            } header: {
                GrainSectionEyebrow("ACTION BUTTON")
            }

            Section {
                Toggle("Act on conversations", isOn: $ambientEnabled)
                    .onChange(of: ambientEnabled) { on in
                        UserDefaults.standard.set(on, forKey: AmbientPrefs.enabledKey)
                    }
                Text(ambientEnabled
                     ? "While recording, your phone privately watches for moments like “I'll have to look that up” and offers to help. Everything stays on this phone until you accept."
                     : "Off. Recordings are captured exactly as before — no live analysis of any kind.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                if ambientEnabled {
                    HStack {
                        Text("Agent name").grainTextStyle(.body)
                        Spacer()
                        TextField("Foundry", text: $agentName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .onChange(of: agentName) { name in
                                let trimmed = name.trimmingCharacters(in: .whitespaces)
                                UserDefaults.standard.set(
                                    trimmed.isEmpty ? nil : trimmed,
                                    forKey: AmbientPrefs.agentNameKey)
                            }
                    }
                    Text("Say this name in a conversation to ask your agent for something. Only offered — nothing runs without your confirmation.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

                    // Owner-first action surfacing (features/
                    // action-speaker-attribution.feature): default OFF = only
                    // what YOU said becomes an action automatically.
                    Toggle("Actions from others", isOn: $othersInline)
                        .onChange(of: othersInline) { on in
                            UserDefaults.standard.set(
                                on, forKey: ActionSurfacePolicy.othersInlineKey)
                        }
                        .accessibilityIdentifier("actions-from-others")
                    Text(othersInline
                         ? "Everyone's action lines surface in your list, each labeled with who said it."
                         : "Off. Only what you say becomes an action automatically. What others say collects under “Heard from others,” where you can promote it.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

                    VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                        Toggle(isOn: Binding(
                            get: { fullContextGrading },
                            set: { on in
                                fullContextGrading = on
                                UserDefaults.standard.set(on, forKey: AmbientPrefs.gradingKey)
                            }
                        )) {
                            Text("Full-context grading")
                                .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        }
                        .tint(GrainColor.forgeBlue)
                        Text("Logs the raw conversation window on this device so the council can grade decisions. On for you; off by default for others.")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    }
                    .onAppear {
                        fullContextGrading = AmbientPrefs.fullContextGrading()
                    }

                    Button("Preview a notification") { AmbientNotifier.postPreview() }
                    Text("See how a nudge feels before anything real triggers.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

                    NavigationLink("What it's noticing") { AmbientDebugView() }
                }

                // Owner voice: the read-aloud key that lets only YOU command your
                // agent. Teachable here any time (also offered at first run).
                NavigationLink {
                    OnboardingVoiceStandalone()
                } label: {
                    HStack {
                        Text("Your voice").grainTextStyle(.body)
                        Spacer()
                        Text(voiceStatusLabel)
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    }
                }
            } header: {
                GrainSectionEyebrow("AMBIENT INTELLIGENCE")
            }

            Section {
                Toggle("Show performance overlay", isOn: $perfOverlayEnabled)
                    .onChange(of: perfOverlayEnabled) { on in
                        DiagPrefs.setPerfOverlayEnabled(on)
                        // Off clears the screen at once; on lets new spans start showing
                        // without an app restart (the model reads the pref per line).
                        if !on { PerfOverlayModel.shared.clearAll() }
                    }
            } header: {
                GrainSectionEyebrow("DIAGNOSTICS")
            } footer: {
                Text("Shows spans and hangs as pills at the top of the screen.")
            }

            Section {
                // Explore the welcome for ANY persona: flip "What brings you
                // here?" live to see expert / individual / firm, and the choice
                // sticks (features/persona-welcome.feature). This is where you
                // "see the pages for the other user types."
                NavigationLink {
                    PersonaWelcomeExplorer()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome & who it's for").grainTextStyle(.body)
                        Text(personaSubtitle)
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    }
                }
                Toggle(isOn: Binding(
                    get: { letStraightIn },
                    set: { on in letStraightIn = on; WelcomePrefs.setLetStraightIn(on) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open straight to the app").grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        Text("Skip the welcome and take me in the moment I open the app — even before connecting.")
                            .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    }
                }
                .tint(GrainColor.forgeBlue)
                Button("Replay the full first-run tour") { showingTour = true }
                NavigationLink("Privacy & your data") { PrivacyView() }
            } header: {
                Text("FoundryX")
            } footer: {
                Text("The welcome speaks differently to an expert, a person organizing their life, or a firm. Open it to explore each and pick yours.")
            }

            Section("Account") {
                let account = remote.accountPresentation
                if account.isSignedIn {
                    // WHO is signed in, right above Sign out (Nick 2026-07-21).
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.primary)
                            .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        if let secondary = account.secondary {
                            Text(secondary)
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        }
                        if let providerLine = account.providerLine {
                            Text(providerLine)
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("account-identity")
                    // Sign out has VISIBLE effect: the row above flips to "Not signed
                    // in / Sign in" the instant the session clears (Nick: the button
                    // "isn't working" — it cleared silently with no on-screen change).
                    Button("Sign out") { remote.signOut() }
                        .foregroundStyle(GrainColor.dangerRed)
                        .accessibilityIdentifier("sign-out")
                    // Apple-required in-app account deletion (track T-STOREFRONT): three scopes,
                    // each behind a destructive confirmation.
                    NavigationLink {
                        AccountDeletionView(
                            model: accountDeletion,
                            idToken: { remote.idToken },
                            onDeleted: { scope in
                                if scope != .hostedVault { remote.signOut() }
                            })
                    } label: {
                        Text("Delete account").foregroundStyle(GrainColor.dangerRed)
                    }
                } else {
                    Text(account.primary)   // "Not signed in"
                        .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                        .accessibilityIdentifier("account-identity")
                    Button("Sign in") { showingAccountSignIn = true }
                        .accessibilityIdentifier("sign-in")
                }
            }
        }
        .grainBackground()
        // Account section "Sign in" (signed-out state) — get back in / switch accounts.
        .sheet(isPresented: $showingAccountSignIn) {
            SignInView(remote: remote) { showingAccountSignIn = false }
        }
        // Storefront sign-in-only Vault entry: open an existing Vault where purchasing is gated.
        .sheet(isPresented: $showingVaultSignIn) {
            SignInView(remote: remote) { showingVaultSignIn = false }
        }
        .fullScreenCover(isPresented: $showingTour) {
            OnboardingFlowView(baseDir: CaptureWAL.documentsCaptures()) { showingTour = false }
        }
        // B5: the waitlist's sign-in leg. On a successful sign-in the POST fires
        // with the fresh token; a dismissal without a token leaves the caption.
        .sheet(isPresented: $showingWaitlistSignIn, onDismiss: {
            if remote.idToken != nil {
                waitlistSignInDismissed = false
                postWaitlist()
            } else {
                waitlistSignInDismissed = true
            }
        }) {
            SignInView(remote: remote) { showingWaitlistSignIn = false }
        }
    }

    /// The "Your Vault" row. Copy + actionability come from the pure, tested
    /// VaultEntry.presentation(entitlement:); tapping (when off) drives the funnel via
    /// vaultFunnel.activateFromSettings() → RootView's fullScreenCover presents it.
    @ViewBuilder private var vaultEntryRow: some View {
        // Storefront-aware (track T-STOREFRONT): US → the purchase CTA (launches the funnel);
        // non-US / unknown storefront → sign-in only (open an existing Vault), NO purchase CTA.
        let p = VaultEntry.presentation(entitlement: vaultFunnel.entitlement,
                                        purchaseAllowed: vaultFunnel.purchaseAllowed)
        if p.actionable {
            Button {
                if p.showsPurchaseCTA {
                    vaultFunnel.activateFromSettings()   // → the purchase funnel (plans/checkout)
                } else {
                    showingVaultSignIn = true            // sign-in only — no purchase path here
                }
            } label: {
                HStack(spacing: GrainSpacing.x2) {
                    Image(systemName: "key.fill").foregroundStyle(GrainColor.forgeBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                        Text(p.subtitle).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12)).foregroundStyle(GrainColor.textFaint)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: GrainSpacing.x2) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(GrainColor.sage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    Text(p.subtitle).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
                Spacer()
                Text("On").grainTextStyle(.caption).foregroundStyle(GrainColor.sage)
            }
        }
    }

    /// The "My computer" row's LIVE status line, from the same tested mapping the
    /// welcome connect pill uses (WelcomeFrontDoor.connectStatus) — one source of
    /// truth for "how is my door/hub connection doing", now visible in-app.
    private var computerBrainSubtitle: String {
        if let status = WelcomeFrontDoor.connectStatus(remote.status, email: remote.email) {
            return status.text
        }
        return "Pair with the Foundry desktop app (sign in on your Mac first)."
    }

    private func brainRow(_ c: BrainChoice, subtitle: String) -> some View {
        Button {
            brains.select(c)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.label).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    Text(subtitle).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
                Spacer()
                if brains.choice == c {
                    Image(systemName: "checkmark").foregroundStyle(GrainColor.forgeBlue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var voiceStatusLabel: String {
        switch OwnerVoiceStore.state(baseDir: CaptureWAL.documentsCaptures()) {
        case .none: return "Not taught"
        case .recorded: return "Captured"
        case .enrolled: return "Enrolled"
        }
    }

    /// B5: the tap routes by the tested WaitlistJoin rule — tokenless users get
    /// the sign-in sheet first, never a silent no-op.
    private func joinWaitlist() {
        switch WaitlistJoin.step(joined: waitlistJoined, hasIdToken: remote.idToken != nil) {
        case .alreadyJoined:
            return
        case .signInFirst:
            showingWaitlistSignIn = true
        case .post:
            postWaitlist()
        }
    }

    private func postWaitlist() {
        guard let token = remote.idToken,
              let base = RemoteConfig.fromBundle()?.gatewayHTTPURL else { return }
        Task {
            if await AccountClient(baseURL: base).postWaitlist(idToken: token) {
                waitlistJoined = true
                UserDefaults.standard.set(true, forKey: "foundryx.waitlist.joined")
            }
        }
    }

    /// The current persona, shown on the row so it reads at a glance.
    private var personaSubtitle: String {
        switch persona {
        case .expert: return "Speaking to: an independent expert"
        case .individual: return "Speaking to: a person organizing their life"
        case .firm: return "Speaking to: a firm"
        }
    }
}

/// Explore the persona welcome from Settings: the real welcome screen, its
/// "What brings you here?" chooser flipping expert / individual / firm live
/// (each choice persists). Both actions just dismiss — this is exploration, not
/// the first-run flow, so it never advances into voice/ambient.
private struct PersonaWelcomeExplorer: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PersonaWelcomeStep(onStart: { dismiss() }, onSkip: { dismiss() })
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
    }
}
