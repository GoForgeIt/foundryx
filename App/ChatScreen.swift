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
    /// The capture→chat bridge — delivers an "Ask in chat" seed from a transcript.
    @ObservedObject var bridge: ChatBridge
    /// PREVIEW SEAM: inject the empty-state recall chips instead of scanning the on-disk
    /// capture store (so the simulator can screenshot them without real captures). nil ⇒
    /// scan disk on appear. Set from RootView's FOUNDRYX_UI_PREVIEW switch. (A `var` with a
    /// default so it stays in the memberwise init — a `let` with a default would be dropped.)
    var injectedRecallChips: [RecallChip]? = nil

    @State private var input = ""
    @State private var sessionId = ""
    @State private var streaming = false
    @State private var showingChats = false
    @State private var models: [ModelOption] = []
    /// The conversation currently hydrated into `model` — guards against reloading the
    /// live view mid-stream when nothing actually switched.
    @State private var loadedId = ""
    /// Recall chips shown in the empty state (recent captures + the static "agreed today").
    @State private var recallChips: [RecallChip] = []
    /// The recall chip currently fetching its seed (drives its inline spinner).
    @State private var loadingChip: String?

    private var client: DoorClient { DoorClient(target: target, log: log) }

    /// Whether the active conversation is set to Private (Kiln keeps the turn on
    /// compliant / on-device targets). The core brand promise, surfaced per-chat.
    private var isPrivate: Bool { store.active?.sensitivity == ChatConversationStore.Sensitivity.private }

    // Auto/model-label/menu derivation lives in `ModelPickerMenu` (below) so the picker is an
    // isolated Equatable subview — this screen's frequent re-renders don't reset its scroll.

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if model.messages.isEmpty {
                    // First-run / empty chat: a warm, branded prompt instead of a blank
                    // screen — and it reflects the current privacy posture. Below it,
                    // recall chips let a tap reopen a recent conversation as chat context.
                    VStack(spacing: GrainSpacing.x6) {
                        GrainEmptyState(
                            systemImage: isPrivate ? "lock.fill" : "sparkles",
                            title: "Your Foundry is ready",
                            message: isPrivate
                                ? "Ask anything — this chat stays on your Mac."
                                : "Ask anything. Switch to Private anytime to keep a chat on your Mac."
                        )
                        recallChipsSection
                    }
                    .padding(GrainSpacing.x4)
                    .padding(.top, GrainSpacing.x12)
                } else {
                    ChatView(model: model,
                             onApproveOnce: { answer($0, decision: "once") },
                             onApproveAlways: { answer($0, decision: "always") },
                             onReject: { answer($0, decision: "reject") },
                             onRetry: { retryLastTurn() })
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
            GrainComposer("Message your Foundry…", text: $input, isSending: streaming, onSend: send)
        }
        .grainBackground()
        .onAppear { hydrateActive(); consumePendingSeed(); loadRecallChips(); Task { await loadModels() } }
        .onChange(of: store.activeId) { _ in hydrateActive() }
        .onChange(of: bridge.pendingPrompt) { _ in consumePendingSeed() }
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

            // Model picker — extracted into an Equatable subview so the per-token / elapsed-timer
            // re-renders of this screen do NOT re-evaluate the open menu (which resets its scroll
            // to the top). Re-renders ONLY when the list / selection / privacy posture changes.
            // Carries isPrivate so Private still restricts routing to Auto (badge can't lie).
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

    // MARK: recall chips (empty-state) — reopen a recent conversation as chat context

    @ViewBuilder private var recallChipsSection: some View {
        if !recallChips.isEmpty {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                Text("Pick up where you left off")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(recallChips) { chip in
                    Button { tapRecallChip(chip) } label: {
                        HStack(spacing: GrainSpacing.x2) {
                            if loadingChip == chip.id {
                                GrainSpinner(size: 14)
                            } else {
                                Image(systemName: chip.captureId == nil
                                      ? "checkmark.seal" : "bubble.left.and.text.bubble.right.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(GrainColor.forgeBlue)
                            }
                            Text(chip.displayLabel)
                                .grainTextStyle(.body)
                                .foregroundStyle(GrainColor.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, GrainSpacing.x2)
                        .padding(.horizontal, GrainSpacing.x3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                                .fill(GrainColor.backgroundSunken)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous)
                                .strokeBorder(GrainColor.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingChip != nil)
                    .accessibilityIdentifier("recall-chip")
                }
            }
        }
    }

    /// Populate the recall chips: injected sample (preview) or a scan of the on-disk
    /// capture store (newest-named-conversations first) + the static "agreed today" chip.
    private func loadRecallChips() {
        if let injected = injectedRecallChips {
            recallChips = injected
            return
        }
        Task {
            // Off the main actor — the scan touches disk (and may skip many untitled dirs).
            let recent = await Task.detached(priority: .utility) {
                Self.scanRecentCaptures(limit: 3)
            }.value
            recallChips = recent + [Self.agreedTodayChip]
        }
    }

    /// The static chip: a plain, contextless "what did I commit to" recall.
    static let agreedTodayChip = RecallChip(id: "agreed-today", captureId: nil,
                                            title: "What did I agree to today?", startedAt: nil)

    /// Scan the on-disk capture store for the most recent NAMED conversations → recall
    /// chips (newest first; skips discarded fragments + untitled/provisional placeholders).
    /// A pure local read that mirrors the capture timeline's launch hydration — no
    /// on-device analysis, no network (thin client). `nonisolated` so it can run detached.
    nonisolated static func scanRecentCaptures(limit: Int) -> [RecallChip] {
        let base = CaptureWAL.documentsCaptures()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        let names = entries.map { $0.lastPathComponent }
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)   // ids are timestamp-prefixed → newest first
        var chips: [RecallChip] = []
        for name in names {
            if chips.count >= limit { break }
            let dir = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: dir.appendingPathComponent(".discarded").path) { continue }
            guard let card = ConversationCardStore.load(captureId: name, baseDir: base),
                  let title = card.title, !title.isEmpty, title != ProvisionalTitle.placeholder else { continue }
            // Prefer the durable real start; fall back to the id's UTC timestamp.
            let started = (card.startedAt ?? CaptureIdTime.startedAt(fromCaptureId: name))
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            chips.append(RecallChip(id: name, captureId: name, title: title, startedAt: started))
        }
        return chips
    }

    /// Tap a recall chip: show a brief spinner, build its chat seed (from door content,
    /// cached transcript, or title only), then hand it to the bridge — which opens a fresh
    /// chat seeded with that context on the Chat tab.
    private func tapRecallChip(_ chip: RecallChip) {
        guard loadingChip == nil else { return }
        loadingChip = chip.id
        Task {
            let seed = await buildRecallSeed(chip)
            loadingChip = nil
            bridge.askAbout(seed)
        }
    }

    /// Build the seed for a recall chip. Graceful fallbacks: live door content (speaker
    /// turns when diarized) → locally cached transcript → title-only. The static chip
    /// (no captureId) seeds a plain prompt.
    private func buildRecallSeed(_ chip: RecallChip) async -> String {
        guard let captureId = chip.captureId else { return "What did I agree to today?" }
        let timeRange = Self.recallTimeRange(chip.startedAt)
        if let content = try? await client.captureContent(captureId: captureId), content.found {
            return SpeakerSeedFormatter.seed(from: content, title: chip.title, timeRange: timeRange)
        }
        let base = CaptureWAL.documentsCaptures()
        if let cached = TranscriptCacheStore.load(captureId: captureId, baseDir: base), !cached.transcript.isEmpty {
            return SpeakerSeedFormatter.seed(title: chip.title, timeRange: timeRange, transcript: cached.transcript)
        }
        return SpeakerSeedFormatter.titleOnlySeed(title: chip.title, timeRange: timeRange)
    }

    /// Format a recall chip's start into the seed's time range (empty when unknown). A
    /// local formatter — recall taps are occasional, so per-call cost is negligible and
    /// we avoid a shared non-Sendable static.
    private static func recallTimeRange(_ startedAt: Date?) -> String {
        guard let d = startedAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: d)
    }

    // MARK: actions

    private func setModel(_ id: String?) {
        guard let active = store.active else { return }
        store.setModel(id, for: active.id)
    }

    /// Capture→chat bridge: when "Ask in chat" sets a pending prompt, open a fresh chat
    /// and drop the seed into the composer (ready to send / edit). Cleared once consumed.
    private func consumePendingSeed() {
        guard let prompt = bridge.pendingPrompt else { return }
        bridge.pendingPrompt = nil
        _ = store.newConversation()
        input = prompt
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

    /// Send the composed message (clears the composer, then streams the turn).
    private func send() {
        let text = input
        input = ""
        sendText(text)
    }

    /// Re-send the failed turn's user text (the "tap to retry" chip). No-op when there's
    /// nothing to retry.
    private func retryLastTurn() {
        guard let text = model.takeRetryText() else { return }
        sendText(text)
    }

    /// Stream one turn of `text` in the active conversation. On any stream/transport
    /// failure the turn is marked `.failed` (humane copy in the UI, raw detail to the log)
    /// and NOT persisted — the retry chip re-sends it live instead.
    private func sendText(_ text: String) {
        guard let active = store.active,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        streaming = true
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
                    await MainActor.run {
                        model.setConnection(.idle)
                        model.failTurn(reason: "Your Foundry didn’t reply — tap to retry")
                    }
                }
            } catch {
                // Humane copy to the UI; the raw detail is for the log only.
                let detail = Self.errorDetail(error)
                log.error("turn failed: \(detail)")
                await MainActor.run {
                    model.setConnection(.idle)
                    model.failTurn(reason: Self.humaneError(error))
                }
            }
            // Snapshot the settled turn back into the durable store — but NOT a failed one
            // (the message "didn't send", so we don't record it; retry re-sends it live).
            // Only persist while we're still on the same conversation.
            await MainActor.run {
                if store.activeId == chatId, !model.didTurnFail {
                    store.setMessages(model.snapshot(), for: chatId)
                }
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

    /// Raw failure detail for the LOG only (never shown to the user).
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

    /// Humane, user-facing copy for a turn failure (the raw detail goes to the log only).
    private static func humaneError(_ error: Error) -> String {
        if let de = error as? DoorError {
            switch de {
            case .unauthorized: return "Signed out — sign in again to continue"
            case .http(let code): return "Your Foundry hit a snag (HTTP \(code))"
            case .transport: return "Can’t reach your Foundry — check your connection"
            }
        }
        // Offline / timeouts read as a connection problem, not a mystery.
        if (error as NSError).domain == NSURLErrorDomain {
            return "Can’t reach your Foundry — check your connection"
        }
        return "Something went wrong"
    }

    /// Relay a gate decision to the door — NOT fire-and-forget. Shows an honest "Sending…"
    /// state while retrying with backoff; on final failure the buttons come back with an
    /// inline "Couldn't send — try again". On success the door's resumed SSE stream advances
    /// the turn (hiding the card), so we hold "Sending…" until then.
    private func answer(_ callId: String, decision: String) {
        model.setApprovalDelivery(.sending)
        Task {
            let ok = await sendApproval(callId: callId, decision: decision)
            if !ok { model.setApprovalDelivery(.failed); return }
            // Watchdog: a "successful" POST can still fail to reach kiln-session (e.g. a
            // gateway that answers 2xx without delivering — see the answerApproval relay
            // gap filed with the DoorClient owner). If the door's resumed stream hasn't
            // advanced the turn within 12s, surface a recoverable failure instead of
            // wedging in "Sending…" forever. Harmless if the card already advanced
            // (it only renders while awaiting approval).
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if model.approvalDelivery == .sending { model.setApprovalDelivery(.failed) }
        }
    }

    /// Deliver an approval decision with 2 retries + backoff (3 attempts total). Returns
    /// whether it landed; the raw failure detail is logged, never shown.
    private func sendApproval(callId: String, decision: String) async -> Bool {
        let backoff: [UInt64] = [400_000_000, 1_200_000_000]   // between attempts: 0.4s, 1.2s
        for attempt in 0...2 {
            do {
                try await client.answerApproval(sessionId: sessionId, callId: callId, decision: decision)
                return true
            } catch {
                log.warn("approval '\(decision)' send failed (attempt \(attempt + 1)/3): \(Self.errorDetail(error))")
                if attempt < 2 { try? await Task.sleep(nanoseconds: backoff[attempt]) }
            }
        }
        return false
    }
}

// MARK: - Recall chip model

/// One recall chip in the chat empty state: a captured conversation to reopen ("Ask
/// about …"), or the static "What did I agree to today?" prompt (captureId == nil).
struct RecallChip: Identifiable, Equatable, Sendable {
    let id: String
    /// The capture to seed from; nil ⇒ the static "agreed today" prompt.
    let captureId: String?
    /// The conversation title (or the static prompt text).
    let title: String
    /// The conversation's real start, for the seed's time range (nil ⇒ omitted / static).
    let startedAt: Date?

    /// The chip's user-facing label.
    var displayLabel: String {
        captureId == nil ? title : "Ask about “\(title)”"
    }
}

// MARK: - Chat list drawer (recent conversations · search)

private struct ChatListSheet: View {
    @ObservedObject var store: ChatConversationStore
    var onDismiss: () -> Void

    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    conversationRows
                } else {
                    searchRows
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .accessibilityIdentifier("chat-search")
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

    // MARK: recent conversations (no query)

    @ViewBuilder private var conversationRows: some View {
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

    // MARK: search results (non-empty query)

    @ViewBuilder private var searchRows: some View {
        // Agent 1's search core: case-insensitive substring over title + message texts,
        // most-recently-updated first (see ChatConversationStore.search).
        let hits = ChatConversationStore.search(trimmedQuery, in: store.conversations)
        if hits.isEmpty {
            Text("No chats match “\(trimmedQuery)”")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
        } else {
            ForEach(hits, id: \.conversationId) { hit in
                Button {
                    store.select(hit.conversationId)
                    onDismiss()
                } label: {
                    VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                        Text(Self.title(for: hit.conversationId, in: store))
                            .grainTextStyle(.body)
                            .foregroundStyle(GrainColor.ink)
                            .lineLimit(1)
                        Text(hit.snippet)
                            .grainTextStyle(.caption)
                            .foregroundStyle(GrainColor.textFaint)
                            .lineLimit(2)
                    }
                }
                .accessibilityIdentifier("chat-search-result")
            }
        }
    }

    private static func title(for id: String, in store: ChatConversationStore) -> String {
        let t = store.conversation(id)?.title ?? ""
        return t.isEmpty ? "New chat" : t
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
    /// Private restricts routing to Auto/on-device — cloud entries are hidden so the
    /// "Private" badge can never contradict the actual route (badge-never-lies).
    let isPrivate: Bool
    let onSelect: (String?) -> Void

    nonisolated static func == (lhs: ModelPickerMenu, rhs: ModelPickerMenu) -> Bool {
        lhs.models == rhs.models && lhs.selectedId == rhs.selectedId && lhs.isPrivate == rhs.isPrivate
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
                // Auto = router (wand); a pinned model = a chip (cpu). No lock/shield here —
                // the lock belongs solely to the Privacy control.
                Image(systemName: isAuto ? "wand.and.stars" : "cpu")
                Text(isAuto ? "Auto" : selectedLabel).grainTextStyle(.caption)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(GrainColor.textMuted)
        }
        .accessibilityIdentifier("model-picker")
    }
}
