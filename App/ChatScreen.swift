import SwiftUI
import Grain
#if canImport(UIKit)
import UIKit
#endif

// Session-based chat: a list of resumable conversations (each its own kiln-session
// chat_id), a "new chat" affordance, and a read-only route line (privacy + the
// resolved model — Auto by default; setting either is Settings' job, T-PHONE-CHATLAW
// / ia-brief.md §5.3). The active conversation renders through ChatViewModel; its
// history is snapshotted back into the durable ChatConversationStore at end-of-turn.
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
    /// THE chat list — every chat, one list: the ones this phone started and the ones
    /// resident on the Mac (Kiln's own, and every imported Claude Code / Codex transcript),
    /// merged and ordered by recency with the SOURCE as a facet on each row. A SHEET off
    /// this tab, deliberately not a fifth tab: `app-shell.feature` asserts exactly four, and
    /// there is a recorded product decision against adding one.
    ///
    /// Owned by the SHELL rather than this screen so it is part of the durable place: an
    /// open sheet is somewhere you were, and coming back should not close it
    /// (features/app-place-restore.feature).
    @Binding var showingChatList: Bool

    init(target: DoorTarget,
         store: ChatConversationStore,
         accountBinding: CaptureAccountScope.AccountBinding,
         log: DoorLog,
         showingChatList: Binding<Bool> = .constant(false)) {
        self.target = target
        self.store = store
        self.accountBinding = accountBinding
        self.log = log
        _showingChatList = showingChatList
    }
    /// A run artifact the user tapped to view (sheet with the in-app viewers).
    @State private var viewingArtifact: ChatViewModel.RunArtifact?
    // Seeded synchronously from the warm cache so the route line's resolved model name
    // paints instantly (track 20260715T1501 origin). `loadModels()` still runs on appear
    // and refreshes this in the background — a changed live list replaces the cache. The
    // picker that once wrote INTO this array is gone (T-PHONE-CHATLAW); `models` now only
    // resolves an id to a display name for the read-only route line.
    @State private var models: [ModelOption] = ModelCache.load()
    /// The conversation currently hydrated into `model` — guards against reloading the
    /// live view mid-stream when nothing actually switched.
    @State private var loadedId = ""

    private var client: DoorClient { DoorClient(target: target, log: log) }

    /// Whether the active conversation is set to Private (Kiln keeps the turn on
    /// compliant / on-device targets). The core brand promise, surfaced per-chat.
    private var isPrivate: Bool { store.active?.sensitivity == ChatConversationStore.Sensitivity.private }

    var body: some View {
        VStack(spacing: 0) {
            header
            // THE chat surface — the same one a chat from the Mac renders through
            // (`KilnConversationView`). The scroller, the landing-on-the-newest-turn and the
            // composer live in `ChatSurface`; this screen only says what goes in it. There
            // was once a second rendering of a chat for the Mac's chats, and every one of
            // its four defects came from being a second one.
            ChatSurface(
                model: model,
                input: $input,
                placeholder: ChatCopy.composerPlaceholder,
                isSending: streaming,
                onSend: send,
                onApprove: { answer($0, "always") },
                onReject: { answer($0, "reject") },
                // A file the agent wrote this turn — view it in place
                // (fetched from the desktop over the door, track 20260713T1500).
                onOpenArtifact: { viewingArtifact = $0 },
                accessory: {
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
                })
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
        .sheet(isPresented: $showingChatList) {
            // `computerConnected: true` is a fact here, not an assumption: this screen only
            // exists on the door-backed tier — the phone-only tier renders LocalChatScreen
            // instead and never dials a door at all. Whether the Mac ANSWERS is a different
            // question, and the list says so rather than pretending its half is the whole.
            ChatListView(
                chats: store,
                target: target, log: log, accountBinding: accountBinding,
                computerConnected: true,
                onDismiss: { showingChatList = false })
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

    // MARK: header — which chats · route line (read-only) · new chat
    //
    // T-PHONE-CHATLAW (tracks.md): "the header's model picker replaced by a
    // non-interactive route line carrying the privacy truth (five controls become
    // three)" — this header used to carry an interactive Privacy `Menu` AND an
    // interactive `ModelPickerMenu` alongside the chat-list button and "New" (four
    // controls once "Chats"/"All" had already merged into one, five against the
    // original ia-brief.md §5.3 inventory). Both fold into ONE non-interactive route
    // line here — setting privacy or a model is Settings' job now (ia-brief.md §5.3:
    // "the picker moves to Settings"); this line is a receipt, matching the same
    // "choice is a receipt on the run, not a setting you maintain" law already shipped
    // for the desktop (`ia-brief.md:910-913`). Three controls: chat list, route line,
    // New.
    private var header: some View {
        HStack(spacing: GrainSpacing.x2) {
            // ONE way in, because there is one list.
            //
            // This was, in turn: two lookalike text buttons ("Chats" / "All"), and then a
            // menu that named the two PLACES those buttons led to. Naming them made the
            // split legible; it did not remove it, and the split was the defect. A harness
            // is a SOURCE joined into one corpus — Kiln, Claude Code, Codex, and this phone.
            // So there is no scope to choose: the button opens everything, and WHERE a chat
            // came from is a facet on its row.
            Button { showingChatList = true } label: {
                HStack(spacing: GrainSpacing.x1) {
                    Image(systemName: "list.bullet")
                    Text(KilnLibraryCopy.listTitle).grainTextStyle(.caption)
                }
                .foregroundStyle(GrainColor.textMuted)
                .padding(.vertical, GrainSpacing.x1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(ChatListCopy.controlAccessibilityIdentifier)
            .accessibilityLabel(ChatListCopy.controlAccessibilityLabel)
            .accessibilityHint(ChatListCopy.controlAccessibilityHint)

            Spacer(minLength: 0)

            routeLine

            GrainButton("New", variant: .text, size: .sm) { store.newConversation() }
                .accessibilityIdentifier("new-chat")
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
    }

    /// The privacy truth, as a plain (non-interactive — no button/menu wrapper, no tap
    /// target) line: a lock/cloud SF Symbol + "Private · stays on your Mac" or
    /// "Open · <resolved model>". Replaces the old per-message route caption at the same job
    /// (`ChatView.swift`'s former `routeCaption`, dropped here as superseded — the
    /// header now states the route once instead of repeating it under every turn).
    private var routeLine: some View {
        HStack(spacing: GrainSpacing.x1) {
            Image(systemName: isPrivate ? "lock.fill" : "cloud")
            Text(routeLineText).grainTextStyle(.caption)
        }
        .foregroundStyle(isPrivate ? GrainColor.sage : GrainColor.textMuted)
        .padding(.vertical, GrainSpacing.x1)
        .accessibilityIdentifier("route-line")
        .accessibilityLabel("Route")
        .accessibilityValue(routeLineText)
    }

    private var routeLineText: String {
        isPrivate ? "Private · stays on your Mac" : "Open · \(resolvedModelLabel)"
    }

    /// "Auto" unless this conversation carries a pinned `modelTargetId` the door
    /// already reported a friendly label for.
    private var resolvedModelLabel: String {
        guard let id = store.active?.modelTargetId else { return "Auto" }
        return models.first(where: { $0.id == id }).map(ModelCatalog.displayName(for:)) ?? id
    }

    // MARK: actions

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
        log.info("send tapped → \(target.baseURL.absoluteString) chat=\(chatId.prefix(8)) model=\(active.modelTargetId ?? "auto")")
        // `beginUserTurn` / `setConnection(.connecting)` are NOT called here: opening the
        // turn belongs to the turn, and `PhoneChatTurn.run` does it. Doing it in both places
        // appends the user's message to the thread twice.
        // The turn itself — stream, render, and record the finished thread — lives in
        // FoundryXKit so a scenario can drive it (features/chat-turn-always-ends.feature).
        // Every touch of the model and of the durable list is gated on `accountBinding`
        // still being current, inside `PhoneChatTurn`.
        Task {
            await PhoneChatTurn.run(
                text: text, chatId: chatId, store: store, model: model,
                client: client, as: accountBinding, log: log,
                onEvent: { if case .session(let sid) = $0 { sessionId = sid } })
            // The composer comes back UNCONDITIONALLY. It is screen state, not account
            // state: gating it on the account still being current is how a turn whose
            // account moved on used to leave the composer spinning with no way out.
            streaming = false
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

    /// What the run was asked to do — the Finding card's task line.
    private var lastUserMessage: String {
        model.messages.last(where: { $0.role == "user" })?.text ?? "Agent run"
    }

    private func answer(_ callId: String, _ decision: String) {
        Task { try? await client.answerApproval(sessionId: sessionId, callId: callId, decision: decision) }
    }
}

// The interactive `ModelPickerMenu` that used to live here (an Equatable Menu subview
// wrapping `ModelCatalog.menu(from:)`) was deleted under T-PHONE-CHATLAW: the header's
// model picker is retired in favor of the read-only `routeLine` above. `ModelCatalog`
// itself is not dead — it still backs `model-picker.feature` and
// `Tests/FoundryXBrineTests/ModelPickerTests.swift`, and `routeLine`'s
// `resolvedModelLabel` still calls `ModelCatalog.displayName(for:)` to resolve a pinned
// `modelTargetId` to a friendly name.
