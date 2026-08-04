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
    /// Identity generation that created this chat surface. Every streamed completion
    /// must still match it before touching UI or durable ledgers.
    let accountBinding: CaptureAccountScope.AccountBinding
    @StateObject private var model = ChatViewModel()
    @ObservedObject var log: DoorLog

    @State private var input = ""
    /// The pending Actions-face prefill: which conversation it seeded, the
    /// outcome-log seed to record as a `run` when (and only when) the user
    /// actually sends that turn IN that conversation, and the link keys for
    /// the action↔chat association (EXT2). Nil runSeed rows (answer/user
    /// actions) never log a `run` and never link.
    @State private var prefillRun: (chatId: String, runSeed: String,
                                    captureId: String?, utterance: String?)?
    @State private var sessionId = ""
    @State private var streaming = false
    @State private var showingChats = false
    /// Kiln's SHARED library — every chat on the Mac, including ones this phone never
    /// created. A SHEET off this tab, deliberately not a fifth tab: `app-shell.feature`
    /// asserts exactly four, and there is a recorded product decision against adding one.
    @State private var showingKilnLibrary = false
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
    // Only the privacy posture is derived here, because the privacy CONTROL lives on this
    // screen and the picker is told about it rather than deriving it twice.

    /// Whether the active conversation is set to Private (Kiln keeps the turn on
    /// compliant / on-device targets). The core brand promise, surfaced per-chat.
    private var isPrivate: Bool { store.active?.sensitivity == ChatConversationStore.Sensitivity.private }

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
            consumeAmbientSeed(); consumeAmbientPrefill(); consumeOpenChat()
            // A completed tool-using turn is an agent run — remember it in the
            // activity ledger (features/ambient-answer-loop.feature).
            model.onRunCompleted = { activities in
                let steps = activities.count
                let first = activities.first?.name ?? "tools"
                let detail = "Ran \(steps) step\(steps == 1 ? "" : "s") · \(first)"
                let line = (try? JSONSerialization.data(withJSONObject: [
                    "ts": Int(Date().timeIntervalSince1970),
                    "kind": "agent_run",
                    "answer": detail,
                ])) ?? Data()
                guard !line.isEmpty else { return }
                var out = line
                out.append(UInt8(ascii: "\n"))
                CaptureAccountScope.perform(as: accountBinding) { binding in
                    let url = binding.root.appendingPathComponent(
                        "ambient-answers.jsonl")
                    if let h = try? FileHandle(forWritingTo: url) {
                        defer { try? h.close() }
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: out)
                    } else {
                        try? out.write(to: url)
                    }
                }
            }
        }
        .onChange(of: store.activeId) { _ in hydrateActive() }
        // An accepted ambient card ([Run]) — also fires when already on the chat tab.
        .onReceive(AmbientCardBroker.shared.$pendingSeed) { _ in consumeAmbientSeed() }
        // An Actions-face "Act on it in chat" — prefills the composer, no auto-send.
        .onReceive(AmbientCardBroker.shared.$pendingPrefill) { _ in consumeAmbientPrefill() }
        // An already-acted action's "Continue in chat →" (EXT2).
        .onReceive(AmbientCardBroker.shared.$pendingOpenChatId) { _ in consumeOpenChat() }
        .sheet(isPresented: $showingChats) {
            ChatListSheet(store: store) { showingChats = false }
        }
        .sheet(isPresented: $showingKilnLibrary) {
            // `computerConnected: true` is a fact here, not an assumption: this screen only
            // exists on the door-backed tier — the phone-only tier renders LocalChatScreen
            // instead and never dials a door at all.
            KilnLibraryView(
                target: target, log: log, accountBinding: accountBinding,
                computerConnected: true,
                onDismiss: { showingKilnLibrary = false })
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
        // An accepted card's chat is conversation-born (EXT3): action origin,
        // with the source capture + its category when the call site knew it.
        let captureId = AmbientCardBroker.shared.pendingSeedCaptureId
        AmbientCardBroker.shared.pendingSeedCaptureId = nil
        let convo = store.newConversation(origin: .action(
            captureId: captureId,
            category: captureId.flatMap { ActionFeedbackFlow.categoryName(for: $0) }))
        store.select(convo.id)
        hydrateActive()
        input = seed
        send()
    }

    /// Pre-fill the composer with an Actions-face seed WITHOUT sending — the
    /// user acts on it conversationally (edit, then send). The `run` outcome +
    /// action↔chat link land only when the seeded turn actually goes out (see
    /// `send()`). The minted conversation carries its provenance (EXT3).
    private func consumeAmbientPrefill() {
        guard !streaming, let seed = AmbientCardBroker.shared.pendingPrefill else { return }
        AmbientCardBroker.shared.pendingPrefill = nil
        let ctx = AmbientCardBroker.shared.pendingPrefillContext
        AmbientCardBroker.shared.pendingPrefillContext = nil
        let convo = store.newConversation(origin: .action(
            captureId: ctx?.captureId, actionKey: ctx?.utterance,
            category: ctx?.category))
        store.select(convo.id)
        hydrateActive()
        input = seed
        prefillRun = ctx?.runSeed.map {
            (chatId: convo.id, runSeed: $0,
             captureId: ctx?.captureId, utterance: ctx?.utterance)
        }
    }

    /// EXT2 — "Continue in chat →" on an already-acted action: select ITS chat.
    private func consumeOpenChat() {
        guard let id = AmbientCardBroker.shared.pendingOpenChatId else { return }
        AmbientCardBroker.shared.pendingOpenChatId = nil
        store.select(id)
        hydrateActive()
    }

    // MARK: header — chats drawer · model picker · new chat

    private var header: some View {
        HStack(spacing: GrainSpacing.x2) {
            GrainButton("Chats", variant: .text, size: .sm) { showingChats = true }
                .accessibilityIdentifier("open-chats")

            // The way in to everything on the Mac — Kiln's own chats and every imported
            // Claude Code / Codex transcript, not just what this phone started.
            GrainButton("All", variant: .text, size: .sm) { showingKilnLibrary = true }
                .accessibilityIdentifier("open-kiln-library")

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

            // Model picker — extracted into an Equatable subview so the per-token / elapsed-timer
            // re-renders of this screen do NOT re-evaluate the open menu (which resets its scroll
            // to the top — you couldn't stay scrolled down to pick a model). It re-renders ONLY when
            // the model list or the pinned selection actually changes.
            // `isPrivate` is passed IN rather than re-derived: the restriction has to hold
            // inside the picker itself (cloud models hidden), or the Private badge would be
            // a label over a picker that still offers cloud — the exact contradiction the
            // privacy control exists to prevent.
            ModelPickerMenu(models: models,
                            selectedId: store.active?.modelTargetId,
                            isPrivate: isPrivate,
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

    private func setPrivacy(_ on: Bool) {
        guard let active = store.active else { return }
        // The store clears any pinned model when going Private (a pin is a route, and a
        // cloud pin under a "Private" badge would be a lie). The menu also hides cloud
        // models while Private, so the two agree.
        store.setSensitivity(on ? ChatConversationStore.Sensitivity.private : nil, for: active.id)
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
        // in another chat is not acting on the action). The same moment writes
        // the durable action↔chat link (EXT2) so the action leads back here.
        if let run = prefillRun {
            if run.chatId == active.id {
                AmbientCardBroker.prefillSent(
                    seed: run.runSeed, binding: accountBinding)
                UsageHook.action("run")   // content-free: acted on a surfaced action (no seed text)
                if let captureId = run.captureId, let utterance = run.utterance {
                    ActionChatLinkStore.link(captureId: captureId, utterance: utterance,
                                             chatId: run.chatId,
                                             baseDir: accountBinding.root)
                }
            }
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
                    guard CaptureAccountScope.perform(
                        as: accountBinding,
                        { _ in
                            if !sawEvent {
                                sawEvent = true
                                model.setConnection(.streaming)
                            }
                            if case .session(let sid) = ev { sessionId = sid }
                            if case .done(let reason) = ev {
                                model.setConnection(.completed(reason: reason))
                            }
                            model.apply(ev)
                            return true
                        }) == true else { return }
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
                CaptureAccountScope.perform(as: accountBinding) { _ in
                    if store.activeId == chatId {
                        store.setMessages(model.snapshot(), for: chatId)
                    }
                    streaming = false
                }
            }
        }
    }

    private func loadModels() async {
        do {
            let fetched = try await client.models()
            // Refresh the live picker and rewrite the warm cache so the next open paints
            // this list instantly (AC1/AC3). First-launch caches its first fetch too (AC2).
            await MainActor.run { models = fetched }
            _ = ModelCache.save(
                fetched,
                generation: accountBinding.generation)
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

    /// EXT3 — provenance + category pills (the capture list's chip idiom) and,
    /// under "From voice notes", grouping by source note. All the
    /// filter/group logic is ChatListOrganizer (kit, tested); this renders it.
    @State private var provenance: ChatListOrganizer.Provenance = .all
    @State private var categoryFilter: String?

    private var filtered: [ChatConversationStore.Conversation] {
        ChatListOrganizer.filter(store.conversations,
                                 provenance: provenance, category: categoryFilter)
    }

    var body: some View {
        NavigationStack {
            List {
                if provenance == .fromConversations {
                    ForEach(Array(ChatListOrganizer.groupedBySource(filtered).enumerated()),
                            id: \.offset) { _, group in
                        Section {
                            ForEach(group.conversations) { convo in chatRow(convo) }
                                .onDelete { idx in
                                    delete(idx.map { group.conversations[$0].id })
                                }
                        } header: {
                            Text(Self.sourceHeader(group.captureId))
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.textFaint)
                        }
                    }
                } else {
                    ForEach(filtered) { convo in chatRow(convo) }
                        .onDelete { idx in delete(idx.map { filtered[$0].id }) }
                }
            }
            .navigationTitle("Chats")
            .safeAreaInset(edge: .top) { filterBar }
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

    // MARK: rows

    private func chatRow(_ convo: ChatConversationStore.Conversation) -> some View {
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
                    HStack(spacing: GrainSpacing.x1) {
                        if convo.isFromConversation {
                            Text("From a voice note" +
                                 (convo.origin?.category.map { " · \($0)" } ?? ""))
                                .grainTextStyle(.caption)
                                .foregroundStyle(GrainColor.forgeBlue)
                        }
                        Text(Self.subtitle(convo))
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if convo.id == store.activeId {
                    Image(systemName: "checkmark").foregroundStyle(GrainColor.sage)
                }
            }
        }
        .accessibilityIdentifier("chat-row")
    }

    private func delete(_ ids: [String]) {
        for id in ids {
            store.delete(id)
            // A deleted chat must never be routed back to (EXT2 honesty).
            ActionChatLinkStore.removeLinks(toChatId: id,
                                            baseDir: CaptureWAL.documentsCaptures())
        }
    }

    // MARK: filter pills

    /// Provenance pills always; category pills only when any chat carries one.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GrainSpacing.x2) {
                ForEach(ChatListOrganizer.Provenance.allCases, id: \.self) { p in
                    pill(p.rawValue, selected: provenance == p) {
                        provenance = p
                    }
                }
                let categories = ChatListOrganizer.categories(of: store.conversations)
                if !categories.isEmpty {
                    Rectangle().fill(GrainColor.borderHairline)
                        .frame(width: 1, height: 16)
                    ForEach(categories, id: \.self) { name in
                        pill(name, selected: categoryFilter == name) {
                            categoryFilter = categoryFilter == name ? nil : name
                        }
                    }
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.vertical, GrainSpacing.x2)
        }
        .background(.bar)
        .accessibilityIdentifier("chat-filter-bar")
    }

    private func pill(_ label: String, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .grainTextStyle(.caption)
                .foregroundStyle(selected ? GrainColor.surface : GrainColor.textMuted)
                .padding(.horizontal, GrainSpacing.x3)
                .padding(.vertical, GrainSpacing.x1)
                .background(Capsule().fill(selected ? GrainColor.forgeBlue : GrainColor.surfaceElevated))
                .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-filter-\(label)")
    }

    /// The section header for a source group: the conversation's title when the
    /// card store still has it; chats whose source is unknown (accepted cards
    /// mid-recording) share one honest header.
    private static func sourceHeader(_ captureId: String?) -> String {
        guard let captureId else { return "From a voice note" }
        let title = ConversationCardStore.load(
            captureId: captureId, baseDir: CaptureWAL.documentsCaptures())?.title
        return title?.isEmpty == false ? title! : "A voice note"
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
    /// Private ⇒ on-device routing only. Cloud groups are hidden entirely rather than
    /// shown-and-disabled, so nothing in the menu can contradict the Private badge.
    let isPrivate: Bool
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
            if isPrivate {
                Text("Private uses on-device routing")
            } else {
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
