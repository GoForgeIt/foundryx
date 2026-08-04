import SwiftUI
import Grain

// One chat from Kiln's shared library: its transcript, what is honestly known about where
// it came from, and — when it is foreign history that has never been picked up — the
// resume-in-place action.
//
// EVERY claim on this screen comes from `KilnConversationNotice` (pure, Brine-driven). The
// view chooses layout; it never decides what may be said.

struct KilnConversationView: View {
    let row: LibraryChatRow
    let target: DoorTarget
    let log: DoorLog
    let accountBinding: CaptureAccountScope.AccountBinding
    var onDismiss: () -> Void
    /// Fired after a successful pick-up so the list can re-read the row (it is now live).
    var onPickedUp: () -> Void

    private enum Transcript: Equatable {
        case loading
        case turns([KilnMessage])
        case unreachable(String)
    }

    @State private var transcript: Transcript = .loading
    @State private var pickingUp = false
    @State private var pickUpError: String?
    @State private var pickedUp = false

    private var notice: KilnConversationNotice { KilnConversationNotice.make(row) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: GrainSpacing.x4) {
                    provenance
                    // Ordered deliberately: what is KNOWN about this chat comes before the
                    // action, because both notices below change whether picking it up is
                    // what the reader wants.
                    sourceNotice
                    partialNotice
                    pickUp
                    turns
                }
                .padding(GrainSpacing.x4)
            }
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

    // MARK: - what this chat is

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
    /// needs BEFORE deciding, and hiding it from someone who already acted is worse, not
    /// better. When the state is `.unknown` this renders NOTHING — silence is the honest
    /// rendering of "we do not know", and a reassuring sentence here would have told 2,302
    /// chats their transcript was safely on disk when it was not.
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

    // MARK: - picking it back up

    @ViewBuilder
    private var pickUp: some View {
        if notice.offersPickUp && !pickedUp {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                GrainButton(KilnLibraryCopy.pickUpAction, variant: .filled) {
                    Task { await pickItUp() }
                }
                .disabled(pickingUp)
                .accessibilityIdentifier("kiln-continue")
                // Says resume-in-place out loud. People expect "continue" to mean "make me a
                // copy"; when the same id then shows up on the Mac, that expectation makes a
                // correct behaviour look like a bug.
                Text(KilnLibraryCopy.pickUpBlurb(notice))
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
                if let pickUpError {
                    Text(pickUpError)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.dangerRed)
                        .accessibilityIdentifier("kiln-continue-error")
                }
            }
        } else if pickedUp {
            GrainBanner("Picked up — this chat is live in Kiln now.", variant: .success)
                .accessibilityIdentifier("kiln-continue-done")
        }
    }

    private func pickItUp() async {
        pickingUp = true
        pickUpError = nil
        let binding = accountBinding
        do {
            let result = try await DoorClient(target: target, log: log)
                .kilnContinueChat(chatId: row.id)
            CaptureAccountScope.perform(as: binding) { _ in
                // The client already refuses a reply naming a different id, so reaching here
                // means this same chat is now live.
                _ = result
                pickedUp = true
                pickingUp = false
            }
            onPickedUp()
        } catch {
            CaptureAccountScope.perform(as: binding) { _ in
                pickUpError = failureLine(error)
                pickingUp = false
            }
        }
    }

    // MARK: - the transcript

    @ViewBuilder
    private var turns: some View {
        switch transcript {
        case .loading:
            WaitingExperienceView(
                model: WaitingExperienceModel(kind: .doorFetch, onDevice: false),
                compact: true)
                .accessibilityIdentifier("kiln-transcript-loading")

        case .unreachable(let message):
            // An unreadable transcript is NOT an empty chat, and must not look like one.
            GrainErrorState(
                title: "Couldn't load this chat",
                message: message,
                retry: { Task { await loadTranscript() } })
                .accessibilityIdentifier("kiln-transcript-unreachable")

        case .turns(let messages):
            if messages.isEmpty {
                GrainEmptyState(
                    systemImage: "text.bubble",
                    title: "Nothing was said here yet",
                    message: nil)
                    .accessibilityIdentifier("kiln-transcript-empty")
            } else {
                VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
                            GrainSectionEyebrow(
                                message.role.uppercased(),
                                tint: message.role == "user" ? .forge : .muted)
                            Text(message.text)
                                .grainTextStyle(.body)
                                .foregroundStyle(GrainColor.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .accessibilityIdentifier("kiln-turn")
                    }
                }
            }
        }
    }

    private func loadTranscript() async {
        let binding = accountBinding
        do {
            let messages = try await DoorClient(target: target, log: log)
                .kilnChatMessages(chatId: row.id)
            CaptureAccountScope.perform(as: binding) { _ in transcript = .turns(messages) }
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
