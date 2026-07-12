// SettingsScreen — the brain picker + Action Button choice (track 20260705T1100,
// Phases 5/6). Spec §5: "Just my phone" (free, default, zero content egress) ·
// "My computer" (desktop Foundry via the door) · "Foundry Cloud — your cell"
// (waitlist until it ships). Switching is ADDITIVE: picking a computer replay-
// seeds it from the local library (Phase 7); leaving it returns to local-only
// with everything still readable.

import SwiftUI
import Grain

/// Ambient-intelligence preference keys (track 20260710T2030 v3). One place so the
/// lane wiring (RootView), the Settings toggle, and tests agree. DEFAULT OFF —
/// `bool(forKey:)` on a missing key is false, which IS the opt-out state.
enum AmbientPrefs {
    static let enabledKey = "foundryx.ambient.enabled"
    static let agentNameKey = "foundryx.ambient.agentName"

    /// The Tier-1 gate decision log (shared by the lane wiring, the debug readout,
    /// and — later — the Temper scorer). One place so they never disagree.
    static func decisionLogURL() -> URL {
        CaptureWAL.documentsCaptures().appendingPathComponent("ambient-decisions.jsonl")
    }
}

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
                        TextField("e.g. Forge", text: $agentName)
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

                    Button("Preview a notification") { AmbientNotifier.postPreview() }
                    Text("See how a nudge feels before anything real triggers.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

                    NavigationLink("What it's noticing") { AmbientDebugView() }
                }
            }

            Section("Account") {
                Text(remote.email ?? "Signed in")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                Button("Sign out") { remote.signOut() }
                    .foregroundStyle(GrainColor.dangerRed)
            }
        }
        .grainBackground()
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
}
