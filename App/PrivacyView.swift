// PrivacyView — "Privacy & your data", the plain-language map of where every kind
// of data lives and travels, PER BRAIN. Honesty is the feature: this screen says
// exactly what leaves the phone and when (including the desktop brain's cloud STT
// call), because trust built on vagueness doesn't survive the first question.
// Linked from Settings; the welcome tour carries the one-line version.

import SwiftUI
import Grain

struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("FoundryX is built so your voice notes belong to you. Here is exactly where things live — no fine print.")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
            }

            Section("On “Just my phone”") {
                row("Voice notes & transcripts", "Stay on this phone. Nothing leaves.")
                row("Titles & summaries", "Made by Apple's on-device model. Nothing leaves.")
                row("Ambient intelligence", "Runs on this phone. Nothing leaves unless you accept a suggestion.")
                row("Your voice key", "Stored on this phone only.")
            }

            Section("On “My computer”") {
                row("Voice notes", "Travel end-to-end encrypted to YOUR computer — never our servers.")
                row("Transcription", "Your computer uses one cloud speech service (Deepgram) to transcribe. Audio is sent for that purpose only.")
                row("Memory & answers", "Live in Lore on your computer. Questions are answered from your own machine.")
                row("Titles & summaries", "Made by local models on your computer.")
            }

            Section("Always") {
                row("Sign-in", "Your email identifies you; it is never linked to voice note content.")
                row("Off means off", "Ambient off = zero live analysis. Deleting a voice note deletes it.")
                row("Your agent", "Never acts without your confirmation, and answers only to your voice.")
            }
        }
        .navigationTitle("Privacy & your data")
        .grainBackground()
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
            Text(detail).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
        }
    }
}
