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
    /// The pending Actions-face prefill: which conversation it seeded and the
    /// outcome-log seed to record as a `run` when (and only when) the user
    /// actually sends that turn IN that conversation. Nil runSeed rows
    /// (answer/user actions) never set this — they must not log a `run`.
    @State private var prefillRun: (chatId: String, seed: String)?
    @State private var sessionId = ""
    @State private var streaming = false
    @State private var showingChats = false
    /// A run artifact the user tapped to view (sheet with the in-app viewers).
    @State private var viewingArtifact: ChatViewModel.RunArtifact?
    // Seed the picker synchronously from the warm cache so the dropdown paints the full
    // grouped menu instantly on open (track 20260715T1501). `loadModels()` still runs on
    // appear and refreshes this in the background — a changed live list replaces the cache.
    @State private var models: [ModelOption] = ModelCache.load()
    /// The conversation currently hydrated into `model` — guards against reloading the
    /// live view mid-stream when nothing actually switched.
    @State private var loadedId = ""

    private var client: DoorClient { DoorClient(target: target, log: log) }

    // Auto/model-label/menu derivation lives in `ModelPickerMenu` (below) so the picker is an
    // isolated Equatable subview — this screen's frequent re-renders don't reset its scroll.

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                ChatView(model: model,
                         onApprove: { answer($0, "always") },
                         onReject: { answer($0, "reject") },
                         // A file the agent wrote this turn — view it in place
                         // (fetched from the desktop over the door, track 20260713T1500).
                         onOpenArtifact: { viewingArtifact = $0 })
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A FINISHED tool-using turn reads as a Finding card — the run's
                // steps (older ones folded), the finding, and what it consulted —
                // never a bare "DONE" row (track 20260714T1800 §7).
                if AgentRunFinding.make(from: model) != nil {
                    AgentRunCard(model: model,
                                 title: lastUserMessage,
                                 onFollowUp: { text in input = text; send() })
                        .padding(.horizontal, GrainSpacing.x4)
                        .padding(.bottom, GrainSpacing.x2)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
            GrainComposer(ChatCopy.composerPlaceholder, text: $input, isSending: streaming, onSend: send)
        }
        .grainBackground()
        .onAppear {
            hydrateActive(); Task { await loadModels() }
            consumeAmbientSeed(); consumeAmbientPrefill()
            // A completed tool-using turn is an agent run — remember it in the
            // activity ledger (features/ambient-answer-loop.feature).
            model.onRunCompleted = { activities in
                let steps = activities.count
                let first = activities.first?.name ?? "tools"
                let detail = "Ran \(steps) step\(steps == 1 ? "" : "s") · \(first)"
                let url = CaptureWAL.documentsCaptures()
                    .appendingPathComponent("ambient-answers.jsonl")
                let line = (try? JSONSerialization.data(withJSONObject: [
                    "ts": Int(Date().timeIntervalSince1970),
                    "kind": "agent_run",
                    "answer": detail,
                ])) ?? Data()
                guard !line.isEmpty else { return }
                var out = line
                out.append(UInt8(ascii: "\n"))
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: out)
                } else {
                    try? out.write(to: url)
                }
            }
        }
        .onChange(of: store.activeId) { _ in hydrateActive() }
        // An accepted ambient card ([Run]) — also fires when already on the chat tab.
        .onReceive(AmbientCardBroker.shared.$pendingSeed) { _ in consumeAmbientSeed() }
        // An Actions-face "Act on it in chat" — prefills the composer, no auto-send.
        .onReceive(AmbientCardBroker.shared.$pendingPrefill) { _ in consumeAmbientPrefill() }
        .sheet(isPresented: $showingChats) {
            ChatListSheet(store: store) { showingChats = false }
        }
        .sheet(item: $viewingArtifact) { artifact in
            NavigationStack {
                ArtifactPane(
                    path: RunArtifactRoute.path(name: artifact.name),
                    filename: artifact.name,
                    mime: artifact.mime,
                    source: DoorArtifactSource(target: target, log: log)
                )
                .navigationTitle(artifact.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { viewingArtifact = nil }
                }
            }
        }
    }

    /// Start the seeded conversation an accepted ambient card requested: a FRESH
    /// chat (its own context), the moment as the first turn, sent immediately —
    /// the user watches the agent work right here.
    private func consumeAmbientSeed() {
        guard !streaming, let seed = AmbientCardBroker.shared.pendingSeed else { return }
        AmbientCardBroker.shared.pendingSeed = nil
        let convo = store.newConversation()
        store.select(convo.id)
        hydrateActive()
        input = seed
        send()
    }

    /// Pre-fill the composer with an Actions-face seed WITHOUT sending — the
    /// user acts on it conversationally (edit, then send). The `run` outcome is
    /// logged only when the seeded turn actually goes out (see `send()`).
    private func consumeAmbientPrefill() {
        guard !streaming, let seed = AmbientCardBroker.shared.pendingPrefill else { return }
        AmbientCardBroker.shared.pendingPrefill = nil
        let runSeed = AmbientCardBroker.shared.pendingPrefillRunSeed
        AmbientCardBroker.shared.pendingPrefillRunSeed = nil
        let convo = store.newConversation()
        store.select(convo.id)
        hydrateActive()
        input = seed
        prefillRun = runSeed.map { (chatId: convo.id, seed: $0) }
    }

    // MARK: header — chats drawer · model picker · new chat

    private var header: some View {
        HStack(spacing: GrainSpacing.x2) {
            GrainButton("Chats", variant: .text, size: .sm) { showingChats = true }
                .accessibilityIdentifier("open-chats")

            Spacer(minLength: 0)

            // Model picker — extracted into an Equatable subview so the per-token / elapsed-timer
            // re-renders of this screen do NOT re-evaluate the open menu (which resets its scroll
            // to the top — you couldn't stay scrolled down to pick a model). It re-renders ONLY when
            // the model list or the pinned selection actually changes.
            ModelPickerMenu(models: models,
                            selectedId: store.active?.modelTargetId,
                            onSelect: setModel)
                .equatable()

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
        // A turn that started from an Actions-face prefill is a run the moment
        // it's actually SENT (not when it was merely prefilled) — logged with
        // the utterance seed so the join resolves even after edits, and ONLY
        // when the send happens in the conversation the prefill seeded (a send
        // in another chat is not acting on the action).
        if let run = prefillRun {
            if run.chatId == active.id { AmbientCardBroker.prefillSent(seed: run.seed) }
            prefillRun = nil
        }
        let text = input; input = ""; streaming = true
        // iOS quirk: a vertical-axis TextField can keep its rendered glyphs when the
        // bound string is reset within the same tap/return submit cycle, so the message
        // you just sent lingers in the composer. Re-clear on the next runloop tick so
        // the field reliably empties after every send (button OR return key).
        DispatchQueue.main.async { self.input = "" }
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
                    // The thread stays calm; the engineering truth goes to the log.
                    log.warn(ChatSendFailure.emptyReplyLogDetail)
                    await MainActor.run {
                        model.setConnection(.error(detail: ChatSendFailure.emptyReply))
                        model.apply(.error(code: "", reason: ChatSendFailure.emptyReply))
                    }
                }
            } catch {
                // Calm human copy in the thread; the code/domain detail is DoorLog-only.
                let calm = ChatSendFailure.calmMessage(for: error)
                log.error("turn failed: \(ChatSendFailure.logDetail(for: error))")
                await MainActor.run {
                    model.setConnection(.error(detail: calm))
                    model.apply(.error(code: "", reason: calm))
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
            // Refresh the live picker and rewrite the warm cache so the next open paints
            // this list instantly (AC1/AC3). First-launch caches its first fetch too (AC2).
            await MainActor.run { models = fetched }
            ModelCache.save(fetched)
        } catch {
            log.warn("model list fetch failed: \(error.localizedDescription)")
        }
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// What the run was asked to do — the Finding card's task line.
    private var lastUserMessage: String {
        model.messages.last(where: { $0.role == "user" })?.text ?? "Agent run"
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

/// The chat model picker, isolated as an Equatable subview.
///
/// The chat screen re-renders on every streamed token and on the per-second "Thinking…"
/// elapsed timer. When the picker Menu lived inline, each of those re-evaluated the open
/// menu's content and the system menu snapped its scroll back to the top — so you couldn't
/// stay scrolled down to select a model near the bottom of the list. As an `Equatable`
/// subview keyed only on `models` + `selectedId`, SwiftUI skips re-rendering it while a turn
/// streams, so the open menu keeps its scroll position.
private struct ModelPickerMenu: View, Equatable {
    let models: [ModelOption]
    let selectedId: String?
    let onSelect: (String?) -> Void

    nonisolated static func == (lhs: ModelPickerMenu, rhs: ModelPickerMenu) -> Bool {
        lhs.models == rhs.models && lhs.selectedId == rhs.selectedId
    }

    private var menuData: ModelMenu { ModelCatalog.menu(from: models) }
    private var isAuto: Bool { selectedId == nil }
    private var selectedLabel: String {
        guard let id = selectedId else { return "Auto" }
        return models.first(where: { $0.id == id }).map(ModelCatalog.displayName(for:)) ?? id
    }

    var body: some View {
        Menu {
            Section {
                Button { onSelect(nil) } label: {
                    Label(menuData.auto.title,
                          systemImage: isAuto ? "checkmark.shield.fill" : "lock.shield")
                }
            } header: {
                Text(menuData.auto.recommended
                     ? "Recommended — \(menuData.auto.caption)"
                     : menuData.auto.caption)
            }
            ForEach(menuData.groups) { group in
                Section(group.title) {
                    ForEach(group.options) { m in
                        Button { onSelect(m.id) } label: {
                            Label(ModelCatalog.displayName(for: m),
                                  systemImage: selectedId == m.id ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: GrainSpacing.x1) {
                Image(systemName: isAuto ? "lock.shield.fill" : "cpu")
                Text(isAuto ? "Auto · Secure" : selectedLabel).grainTextStyle(.caption)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(isAuto ? GrainColor.sage : GrainColor.textMuted)
        }
        .accessibilityIdentifier("model-picker")
    }
}
