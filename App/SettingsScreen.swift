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
