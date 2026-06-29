import SwiftUI
import Grain
#if canImport(UIKit)
import UIKit
#endif

// Session-based chat: a list of resumable conversations (each its own kiln-session
// chat_id), a "new chat" affordance, and a per-chat model picker (default = Kiln
// router). The active conversation renders through ChatViewModel; its history is
// snapshotted back into the durable ChatConversationStore at end-of-turn.
struct ChatScreen: View {
    /// The resolved remote door target (relay tunnel + id_token bearer).
    let target: DoorTarget
    /// The durable conversation list — owned by MainTabs so it survives tab switches.
    @ObservedObject var store: ChatConversationStore
    @StateObject private var model = ChatViewModel()
    @ObservedObject var log: DoorLog

    @State private var input = ""
    @State private var sessionId = ""
    @State private var streaming = false
    @State private var showingChats = false
    @State private var models: [ModelOption] = []
    /// The conversation currently hydrated into `model` — guards against reloading the
    /// live view mid-stream when nothing actually switched.
    @State private var loadedId = ""

    private var client: DoorClient { DoorClient(target: target, log: log) }

    /// Whether the active conversation uses the Auto router (the secure default) rather than a
    /// pinned model.
    private var isAuto: Bool { store.active?.modelTargetId == nil }

    /// Whether the active conversation is set to Private (Kiln keeps the turn on
    /// compliant / on-device targets). The core brand promise, surfaced per-chat.
    private var isPrivate: Bool { store.active?.sensitivity == ChatConversationStore.Sensitivity.private }

    /// The door's models, grouped by provider with friendly labels + the secure Auto default.
    /// Pure + data-driven (the door owns the list); see `ModelCatalog`.
    private var menuData: ModelMenu { ModelCatalog.menu(from: models) }

    /// The friendly label for the active conversation's pinned model (only used when not Auto).
    private var selectedModelLabel: String {
        guard let id = store.active?.modelTargetId else { return "Auto" }
        return models.first(where: { $0.id == id }).map(ModelCatalog.displayName(for:)) ?? id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if model.messages.isEmpty {
                    // First-run / empty chat: a warm, branded prompt instead of a blank
                    // screen — and it reflects the current privacy posture.
                    GrainEmptyState(
                        systemImage: isPrivate ? "lock.fill" : "sparkles",
                        title: "Your Foundry is ready",
                        message: isPrivate
                            ? "Ask anything — this chat stays on your Mac."
                            : "Ask anything. Switch to Private anytime to keep a chat on your Mac."
                    )
                    .padding(GrainSpacing.x4)
                    .padding(.top, GrainSpacing.x12)
                } else {
                    ChatView(model: model,
                             onApprove: { answer($0, "always") },
                             onReject: { answer($0, "reject") })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
            GrainComposer("Message your Foundry…", text: $input, isSending: streaming, onSend: send)
        }
        .grainBackground()
        .onAppear { hydrateActive(); Task { await loadModels() } }
        .onChange(of: store.activeId) { _ in hydrateActive() }
        .sheet(isPresented: $showingChats) {
            ChatListSheet(store: store) { showingChats = false }
        }
    }

    // MARK: header — chats drawer · model picker · new chat

    private var header: some View {
        HStack(spacing: GrainSpacing.x2) {
            GrainButton("Chats", variant: .text, size: .sm) { showingChats = true }
                .accessibilityIdentifier("open-chats")

            Spacer(minLength: 0)

            // Privacy control — the single source of truth for where this chat's data goes.
            // "Private" ⇒ sensitivity=confidential ⇒ Kiln keeps the turn on-device, AND we
            // restrict the model picker to on-device routing (below) + clear any cloud pin, so
            // the badge can never contradict the actual route. "Open" ⇒ sensitivity omitted ⇒
            // the router may use a faster cloud model.
            Menu {
                Button { setPrivacy(true) } label: {
                    Label("Private · stays on your Mac",
                          systemImage: isPrivate ? "checkmark" : "lock.fill")
                }
                Button { setPrivacy(false) } label: {
                    Label("Open · may use cloud for speed",
                          systemImage: isPrivate ? "cloud" : "checkmark")
                }
            } label: {
                HStack(spacing: GrainSpacing.x1) {
                    Image(systemName: isPrivate ? "lock.fill" : "cloud")
                    Text(isPrivate ? "Private" : "Open").grainTextStyle(.caption)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(isPrivate ? GrainColor.sage : GrainColor.textMuted)
                .padding(.vertical, GrainSpacing.x1)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("privacy-picker")
            .accessibilityLabel("Privacy")
            .accessibilityValue(isPrivate ? "Private, stays on your Mac" : "Open, may use cloud")
            .accessibilityHint("Changes whether this chat stays on your Mac")

            // Model picker — Auto (router) is the secure, recommended default; below it the
            // door's models grouped by provider (Anthropic / OpenAI / Local) with friendly names.
            Menu {
                Section {
                    Button { setModel(nil) } label: {
                        Label(menuData.auto.title,
                              systemImage: isAuto ? "checkmark" : "wand.and.stars")
                    }
                } header: {
                    Text(menuData.auto.recommended
                         ? "Recommended — \(menuData.auto.caption)"
                         : menuData.auto.caption)
                }
                // In Private, only on-device routing (Auto) is offered — cloud models are
                // hidden so the "Private" badge can never contradict the actual route.
                if isPrivate {
                    Text("Private uses on-device routing")
                } else {
                    ForEach(menuData.groups) { group in
                        Section(group.title) {
                            ForEach(group.options) { m in
                                Button { setModel(m.id) } label: {
                                    Label(ModelCatalog.displayName(for: m),
                                          systemImage: store.active?.modelTargetId == m.id ? "checkmark" : "")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: GrainSpacing.x1) {
                    // Auto = router (wand); a pinned model = a chip (cpu). No lock/shield here —
                    // the lock belongs solely to the Privacy control.
                    Image(systemName: isAuto ? "wand.and.stars" : "cpu")
                    Text(isAuto ? "Auto" : selectedModelLabel).grainTextStyle(.caption)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(GrainColor.textMuted)
            }
            .accessibilityIdentifier("model-picker")

            GrainButton("New", variant: .text, size: .sm) { store.newConversation() }
                .accessibilityIdentifier("new-chat")
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
    }

    // MARK: actions

    private func setModel(_ id: String?) {
        guard let active = store.active else { return }
        store.setModel(id, for: active.id)
    }

    private func setPrivacy(_ on: Bool) {
        guard let active = store.active else { return }
        store.setSensitivity(on ? ChatConversationStore.Sensitivity.private : nil, for: active.id)
        // Private restricts routing to on-device — clear any pinned cloud model so the badge
        // can never contradict the actual route (the model menu also hides cloud while Private).
        if on { store.setModel(nil, for: active.id) }
    }

    /// Load the active conversation's persisted history into the live view (on first
    /// appearance + every switch). No-op if it's already loaded (avoids clobbering a
    /// live stream).
    private func hydrateActive() {
        guard store.activeId != loadedId, let active = store.active else { return }
        model.load(from: active.messages)
        loadedId = active.id
    }

    private func send() {
        guard let active = store.active else { return }
        let text = input; input = ""; streaming = true
        let chatId = active.id
        model.beginUserTurn(text)
        model.setConnection(.connecting)
        log.info("send tapped → \(target.baseURL.absoluteString) chat=\(chatId.prefix(8)) model=\(active.modelTargetId ?? "auto")")
        let req = store.chatRequest(text: text, for: chatId)
        Task {
            var sawEvent = false
            do {
                for try await ev in client.events(for: req) {
                    if !sawEvent { sawEvent = true; await MainActor.run { model.setConnection(.streaming) } }
                    if case .session(let sid) = ev { sessionId = sid }
                    if case .done(let reason) = ev { await MainActor.run { model.setConnection(.completed(reason: reason)) } }
                    await MainActor.run { model.apply(ev) }
                }
                if !sawEvent {
                    log.warn("stream ended with 0 events (door closed before any reply)")
                    await MainActor.run { model.setConnection(.error(detail: "no response from door (0 events)")) }
                }
            } catch {
                let detail = Self.errorDetail(error)
                log.error("turn failed: \(detail)")
                await MainActor.run {
                    model.setConnection(.error(detail: detail))
                    model.apply(.boundary(label: "error: \(detail)"))
                }
            }
            // Snapshot the rendered turn back into the durable store (only if we're still
            // on the same conversation — the user may have switched away mid-stream).
            await MainActor.run {
                if store.activeId == chatId { store.setMessages(model.snapshot(), for: chatId) }
                streaming = false
            }
        }
    }

    private func loadModels() async {
        do {
            let fetched = try await client.models()
            await MainActor.run { models = fetched }
        } catch {
            log.warn("model list fetch failed: \(error.localizedDescription)")
        }
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private static func errorDetail(_ error: Error) -> String {
        if let de = error as? DoorError {
            switch de {
            case .unauthorized: return "401 unauthorized (bad token)"
            case .http(let code): return "HTTP \(code)"
            case .transport(let msg): return msg
            }
        }
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    private func answer(_ callId: String, _ decision: String) {
        Task { try? await client.answerApproval(sessionId: sessionId, callId: callId, decision: decision) }
    }
}

// MARK: - Chat list drawer (recent conversations)

private struct ChatListSheet: View {
    @ObservedObject var store: ChatConversationStore
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.conversations) { convo in
                    Button {
                        store.select(convo.id)
                        onDismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                                Text(convo.title.isEmpty ? "New chat" : convo.title)
                                    .grainTextStyle(.body)
                                    .foregroundStyle(GrainColor.ink)
                                    .lineLimit(1)
                                Text(Self.subtitle(convo))
                                    .grainTextStyle(.caption)
                                    .foregroundStyle(GrainColor.textFaint)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if convo.id == store.activeId {
                                Image(systemName: "checkmark").foregroundStyle(GrainColor.sage)
                            }
                        }
                    }
                    .accessibilityIdentifier("chat-row")
                }
                .onDelete { idx in
                    idx.map { store.conversations[$0].id }.forEach { store.delete($0) }
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("New") { store.newConversation(); onDismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private static func subtitle(_ convo: ChatConversationStore.Conversation) -> String {
        let last = convo.messages.last?.text ?? ""
        if last.isEmpty { return "No messages yet" }
        return last
    }
}
