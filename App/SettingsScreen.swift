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
    @State private var actionChoice = ActionButtonChoice.current
    @State private var waitlistJoined =
        UserDefaults.standard.bool(forKey: "foundryx.waitlist.joined")
    @State private var ambientEnabled =
        UserDefaults.standard.bool(forKey: AmbientPrefs.enabledKey)
    @State private var agentName =
        UserDefaults.standard.string(forKey: AmbientPrefs.agentNameKey) ?? ""
    @State private var fullContextGrading = AmbientPrefs.fullContextGrading()
    @State private var showingTour = false
    @State private var persona = PersonaPrefs.persona()

    var body: some View {
        List {
            Section("Brain") {
                brainRow(.justMyPhone,
                         subtitle: "Free. Recordings, transcripts, and summaries never leave this phone.")
                brainRow(.myComputer,
                         subtitle: remote.relay == nil
                            ? "Pair with the Foundry desktop app (sign in on your Mac first)."
                            : "Connected via your designated host.")
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
                    Button(waitlistJoined ? "On the list ✓" : "Join waitlist") { joinWaitlist() }
                        .disabled(waitlistJoined || remote.idToken == nil)
                }
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

            Section("Action Button") {
                Picker("When pressed", selection: $actionChoice) {
                    ForEach(ActionButtonChoice.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .onChange(of: actionChoice) { c in ActionButtonChoice.current = c }
                Text("Bind “FoundryX Action” to the Action Button, Control Center, or back-tap in iOS Settings; Siri: “Start FoundryX recording”.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }

            Section("Ambient intelligence") {
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
                Button("Replay the full first-run tour") { showingTour = true }
                NavigationLink("Privacy & your data") { PrivacyView() }
            } header: {
                Text("FoundryX")
            } footer: {
                Text("The welcome speaks differently to an expert, a person organizing their life, or a firm. Open it to explore each and pick yours.")
            }

            Section("Account") {
                Text(remote.email ?? "Signed in")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                Button("Sign out") { remote.signOut() }
                    .foregroundStyle(GrainColor.dangerRed)
            }
        }
        .grainBackground()
        .fullScreenCover(isPresented: $showingTour) {
            OnboardingFlowView(baseDir: CaptureWAL.documentsCaptures()) { showingTour = false }
        }
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

    private func joinWaitlist() {
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
