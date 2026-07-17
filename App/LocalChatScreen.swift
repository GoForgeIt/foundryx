// LocalChatScreen — the phone-only chat surface (track 20260705T1100, Phase 4).
// Whole-library on-device chat with the PERSISTENT honesty notice + the one-tap
// "Join the waitlist" button pinned to the surface (locked decision #1). On phones
// without Apple Intelligence this surface IS the upgrade prompt (decision #2).

import SwiftUI
import Grain

struct LocalChatScreen: View {
    /// The library the engine answers over.
    let baseDir: URL
    /// Waitlist tap → one-tap upgrade-intent flag on the signed-in account.
    @ObservedObject var remote: RemoteSession

    @State private var messages: [(role: String, text: String)] = []
    @State private var input = ""
    @State private var thinking = false
    /// The outcome-log seed of a pending Actions-face prefill — logged as a
    /// `run` only when the user actually sends the turn; cleared when the
    /// composer is emptied (an abandoned prefill is not a run). Nil for
    /// prefills that must never log one (answer/user rows).
    @State private var prefillSeed: String?
    @State private var waitlistJoined =
        UserDefaults.standard.bool(forKey: "foundryx.waitlist.joined")

    private var engine: LocalChatEngine? {
        guard let model = makeSystemChatModel() else { return nil }
        return LocalChatEngine(baseDir: baseDir, model: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            honestyBanner
            if engine == nil {
                upgradePrompt
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: GrainSpacing.x3) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                            Text(m.text)
                                .grainTextStyle(.body)
                                .foregroundStyle(m.role == "user" ? GrainColor.textMuted : GrainColor.ink)
                                .frame(maxWidth: .infinity, alignment: m.role == "user" ? .trailing : .leading)
                        }
                        if thinking {
                            Text("Thinking on-device…")
                                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                        }
                    }
                    .padding(GrainSpacing.x4)
                }
                GrainComposer("Ask across your conversations…", text: $input,
                              isSending: thinking, onSend: send)
            }
        }
        .grainBackground()
        // An Actions-face "Act on it in chat" prefill (track 20260715T1500
        // addendum) — fill the composer, never auto-send.
        .onAppear { consumePrefill() }
        .onReceive(AmbientCardBroker.shared.$pendingPrefill) { _ in consumePrefill() }
        // A fully-cleared composer abandons the prefill — a LATER unrelated send
        // must not log a `run` for it. (send() empties input AFTER logging.)
        .onChange(of: input) { text in
            if text.isEmpty { prefillSeed = nil }
        }
    }

    private func consumePrefill() {
        // No engine ⇒ no composer to fill — leave the prefill unconsumed rather
        // than stuffing an invisible field (the Actions face doesn't offer
        // act-in-chat on this tier; this is defense in depth).
        guard engine != nil, let seed = AmbientCardBroker.shared.pendingPrefill else { return }
        AmbientCardBroker.shared.pendingPrefill = nil
        prefillSeed = AmbientCardBroker.shared.pendingPrefillRunSeed
        AmbientCardBroker.shared.pendingPrefillRunSeed = nil
        input = seed
    }

    /// The persistent honesty notice + waitlist button (never dismissible).
    private var honestyBanner: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            Text(LocalChatPresentation.honestyNotice)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
            Button(waitlistJoined ? "On the waitlist ✓" : LocalChatPresentation.waitlistButtonTitle) {
                joinWaitlist()
            }
            .grainTextStyle(.caption)
            .disabled(waitlistJoined)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GrainSpacing.x3)
        .overlay(alignment: .bottom) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
    }

    private var upgradePrompt: some View {
        VStack(spacing: GrainSpacing.x3) {
            Spacer()
            Text(LocalChatPresentation.noAppleIntelligencePrompt)
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, GrainSpacing.x6)
            Spacer()
        }
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let engine, !thinking else { return }
        // A turn that started from an Actions-face prefill is a run once SENT.
        if let seeded = prefillSeed {
            AmbientCardBroker.prefillSent(seed: seeded)
            prefillSeed = nil
        }
        input = ""
        messages.append(("user", q))
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let (text, _) = try await engine.answer(q)
                messages.append(("assistant", text))
            } catch {
                messages.append(("assistant", "Couldn't answer on-device: \(error.localizedDescription)"))
            }
        }
    }

    /// Decision #7: the waitlist is a one-tap flag on the existing account — the
    /// sign-in already captured name + email, so there is no form.
    private func joinWaitlist() {
        guard let token = remote.idToken else { return }
        let base = RemoteConfig.fromBundle()?.gatewayHTTPURL
        guard let base else { return }
        Task {
            if await AccountClient(baseURL: base).postWaitlist(idToken: token) {
                waitlistJoined = true
                UserDefaults.standard.set(true, forKey: "foundryx.waitlist.joined")
            }
        }
    }
}

/// Foundation Models chat conformer + factory (nil below iOS 26 / no Apple
/// Intelligence hardware ⇒ the surface shows the upgrade prompt).
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
final class FoundationModelsChat: LocalChatModel, @unchecked Sendable {
    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    func respond(to prompt: String) async throws -> String {
        try await LanguageModelSession().respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

func makeSystemChatModel() -> LocalChatModel? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
        let m = FoundationModelsChat()
        return m.isAvailable ? m : nil
    }
    #endif
    return nil
}
