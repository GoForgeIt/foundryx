import SwiftUI
import Grain

// One chat from Kiln's shared library — opened as a CHAT.
//
// This screen used to be a read-only transcript viewer with a "Pick up here" button. It asked
// the door for the whole transcript and built every turn at once (22.8 seconds and a crash on
// the largest real chat), it had no scroll position so it opened at the oldest turn, and it
// rendered turns as eyebrow-and-paragraph rather than as the app's bubbles. Four complaints,
// one cause: it was a second implementation of a chat.
//
// It is now a thin host over `ChatSurface` — the SAME surface the phone's own chats render
// through. What is honestly known about where the chat came from still comes from
// `KilnConversationNotice`; what may be built and what the first send does comes from
// `KilnConversationPresentation`. This view chooses layout and nothing else.

struct KilnConversationView: View {
    let row: LibraryChatRow
    let target: DoorTarget
    /// WHICH BRAIN holds this chat — Mac or Vault — so the loading wait names the
    /// owner's real place instead of hardcoding "your Mac".
    let destination: CaptureDestination
    let log: DoorLog
    let accountBinding: CaptureAccountScope.AccountBinding
    var onDismiss: () -> Void
    /// Fired after the chat has been picked back up so the list can re-read the row.
    var onPickedUp: () -> Void

    private enum Transcript: Equatable {
        case loading
        case opened(KilnConversationPresentation.Opened)
        case unreachable(String)
    }

    @State private var transcript: Transcript = .loading
    @StateObject private var model = ChatViewModel()
    @State private var input = ""
    @State private var streaming = false
    /// What the NEXT turn has to do. Starts from the row's own posture and becomes `.send`
    /// once the chat has been picked back up — a chat is resumed exactly once.
    @State private var plan: KilnConversationPresentation.SendPlan = .send

    private var notice: KilnConversationNotice { KilnConversationNotice.make(row) }
    private var client: DoorClient { DoorClient(target: target, log: log) }

    var body: some View {
        NavigationStack {
            content
                .grainBackground()
                .navigationTitle(KilnLibrary.chatTitle(row))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDismiss)
                            .accessibilityIdentifier("kiln-chat-done")
                    }
                }
        }
        .task { await loadTranscript() }
    }

    @ViewBuilder
    private var content: some View {
        switch transcript {
        case .loading:
            WaitingExperienceView(
                model: WaitingExperienceModel(kind: .doorFetch, destination: destination))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("kiln-transcript-loading")

        case .unreachable(let message):
            // A chat we could not fetch is NOT a chat where nothing was said, and must not
            // look like one.
            GrainErrorState(
                title: KilnChatCopy.unreadableTitle,
                message: message,
                retry: { Task { await loadTranscript() } })
                .accessibilityIdentifier("kiln-transcript-unreachable")

        case .opened(let opened):
            VStack(spacing: 0) {
                header
                ChatSurface(
                    model: model,
                    input: $input,
                    placeholder: KilnChatCopy.composerPlaceholder,
                    isSending: streaming,
                    // Older turns are held back rather than built. Tapping builds one more
                    // page; nothing is re-fetched, because the door hands the whole thing
                    // over in one go and has no way to be asked for less.
                    earlier: opened.hasOlder
                        ? ChatSurface.Earlier(
                            label: KilnChatCopy.earlierTurns(opened.olderCount),
                            action: { showOlder(opened) })
                        : nil,
                    onSend: send)
            }
        }
    }

    // MARK: - what this chat is

    /// Provenance and the two notices, above the surface. Ordered deliberately: what is KNOWN
    /// about this chat comes first, because both notices change how a reader reads what
    /// follows.
    private var header: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            provenance
            sourceNotice
            partialNotice
            resumeInPlaceNote
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
    }

    private var provenance: some View {
        let tag = KilnLibrary.sourceTag(notice.originLabel)
        return HStack(spacing: GrainSpacing.x2) {
            GrainBadge(tag.short, variant: notice.imported ? .secondary : .info)
            Text(tag.label)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
            // Provenance is PERMANENT — a picked-up chat still wears its harness badge.
            if notice.imported && notice.resumed {
                GrainChip("Picked up", systemImage: "checkmark", variant: .sage)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("kiln-chat-provenance")
    }

    /// The source-transcript notice.
    ///
    /// Rendered WHETHER OR NOT this chat has been picked up: it is the one fact a reader
    /// needs, and hiding it from someone who already acted is worse, not better. When the
    /// state is `.unknown` this renders NOTHING — silence is the honest rendering of "we do
    /// not know", and a reassuring sentence here would have told 2,302 chats their source
    /// file was safely on disk when it was not.
    @ViewBuilder
    private var sourceNotice: some View {
        if case .gone(let headline, let reassurance, let noticedAt, let evidence) = notice.sourcePresence {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                GrainBanner(headline, variant: .warning)
                Text(reassurance)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                if let noticedAt {
                    Text(noticedAt)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                }
                if let evidence {
                    // The engine's own words, verbatim — not ours to summarise or reword.
                    Text(evidence)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("kiln-source-gone")
        }
    }

    /// A lossy import is ALWAYS marked. Silence here would render a partial import as if it
    /// were complete.
    @ViewBuilder
    private var partialNotice: some View {
        if let marker = notice.partialMarker {
            GrainBanner(marker, variant: .info)
                .accessibilityIdentifier("kiln-partial-marker")
        }
    }

    /// RESUME-IN-PLACE, said out loud — the sentence that used to sit beside the pick-up
    /// button. Removing the button must not remove the fact: people expect "carry on" to mean
    /// "make me a copy", and when the same id then shows up on the Mac that expectation makes
    /// correct behaviour look like a bug. It stops being shown once the chat is live, because
    /// by then it is answering a question nobody is asking.
    @ViewBuilder
    private var resumeInPlaceNote: some View {
        if plan == .resumeInPlaceThenSend {
            Text(KilnLibraryCopy.pickUpBlurb(notice))
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("kiln-resume-in-place-note")
        }
    }

    // MARK: - carrying on

    /// Build one more page of the turns held above the window.
    private func showOlder(_ opened: KilnConversationPresentation.Opened) {
        let wider = KilnConversationPresentation.showOlder(opened)
        transcript = .opened(wider)
        model.load(from: wider.stored)
    }

    /// Send what was typed. On a chat brought over from another tool this ALSO picks it back
    /// up, in place — the reader never had to ask for that separately, and the button that
    /// used to ask left them on a screen they could not type into.
    private func send() {
        guard case .opened = transcript else { return }
        let text = input
        input = ""
        streaming = true
        // iOS quirk: a vertical-axis TextField can keep its rendered glyphs when the bound
        // string is reset within the same submit cycle. Re-clear on the next runloop tick.
        DispatchQueue.main.async { self.input = "" }
        let binding = accountBinding
        let sending = plan
        model.beginUserTurn(text)
        model.setConnection(.connecting)
        var sawEvent = false
        Task {
            do {
                let next = try await KilnRemoteTurn.send(
                    text: text, row: row, plan: sending, client: client,
                    onResumed: {
                        // Live from here on, whatever the turn itself does next.
                        CaptureAccountScope.perform(as: binding) { _ in plan = .send }
                        onPickedUp()
                    },
                    onEvent: { event in
                        _ = CaptureAccountScope.perform(as: binding) { _ in
                            if !sawEvent {
                                sawEvent = true
                                model.setConnection(.streaming)
                            }
                            if case .done(let reason) = event {
                                model.setConnection(.completed(reason: reason))
                            }
                            model.apply(event)
                        }
                    })
                CaptureAccountScope.perform(as: binding) { _ in
                    plan = next
                    streaming = false
                }
                if !sawEvent {
                    log.warn(ChatSendFailure.emptyReplyLogDetail)
                    CaptureAccountScope.perform(as: binding) { _ in
                        model.setConnection(.error(detail: ChatSendFailure.emptyReply))
                        model.apply(.error(code: "", reason: ChatSendFailure.emptyReply))
                    }
                }
            } catch {
                // Calm human copy in the thread; the code/domain detail is DoorLog-only.
                let calm = failureLine(error)
                log.error("mac chat turn failed: \(ChatSendFailure.logDetail(for: error))")
                CaptureAccountScope.perform(as: binding) { _ in
                    model.setConnection(.error(detail: calm))
                    model.apply(.error(code: "", reason: calm))
                    streaming = false
                }
            }
        }
    }

    private func loadTranscript() async {
        let binding = accountBinding
        do {
            let turns = try await client.kilnChatMessages(chatId: row.id)
            let opened = KilnConversationPresentation.open(row, turns: turns)
            CaptureAccountScope.perform(as: binding) { _ in
                transcript = .opened(opened)
                plan = opened.sendPlan
                // The SAME loader a chat that started on this phone goes through.
                model.load(from: opened.stored)
            }
        } catch {
            CaptureAccountScope.perform(as: binding) { _ in
                transcript = .unreachable(failureLine(error))
            }
        }
    }

    /// User-facing failure copy ALWAYS comes from `DoorFailureMessage` — never
    /// `localizedDescription`, which is where "Could not connect to the server" came from and
    /// cost hours chasing a phantom connectivity bug on a phone whose network was fine.
    private func failureLine(_ error: Error) -> String {
        if let e = error as? KilnLibraryError {
            return DoorFailureMessage.make(kilnLibraryFailure: e).line
        }
        return DoorFailureMessage.make(doorTransportFailure: error).line
    }
}
