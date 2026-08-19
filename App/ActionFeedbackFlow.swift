// ActionFeedbackFlow — THE one glue layer between an action row and its options
// sheet (track 20260715T1500 EXT1): every surface that renders action rows
// (the conversation detail's Actions face, the Activity page) builds its sheet
// and persists its feedback through here, so there are no divergent copies of
// the act/continue/reject/refine wiring.
//
//   • Continue in chat → routes to the LINKED chat (EXT2) when one is alive.
//   • Act on it in chat → composer prefill via the card broker, carrying the
//     run/link/origin context; gated on a composer actually existing.
//   • Not an action / Refine → the full feedback record into
//     action-feedback.jsonl + the outcome word into ambient-cards.jsonl.

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

@MainActor enum ActionFeedbackFlow {

    /// Build the shared options sheet for one action row. `onChanged` fires
    /// after any persisted change so the surface can reload its rows.
    /// `inOthersGroup` marks a row opened from the collapsed "Heard from
    /// others" group — the sheet then also offers promoting it into the main
    /// list (features/action-speaker-attribution.feature).
    static func sheet(row: ConversationActionsPresentation.Row,
                      captureId: String,
                      destination: CaptureDestination,
                      inOthersGroup: Bool = false,
                      onChanged: @escaping () -> Void) -> ActionOptionsSheet {
        // Act-in-chat exists only where a composer actually exists to prefill:
        // the computer tier always has one; the phone tier hides its composer
        // behind the Apple Intelligence gate — offering the option there would
        // strand the user on the upgrade prompt with an invisible seed.
        let chatCanCompose = destination != .phone || makeSystemChatModel() != nil

        // EXT2: an action already acted on leads back to ITS chat (validated
        // against the live chat store; a dead link is pruned, never routed to).
        var continueChatId: String?
        if let linked = row.linkedChatId {
            if AmbientCardBroker.shared.isChatAlive?(linked) ?? false {
                continueChatId = linked
            } else if let utterance = row.utterance {
                ActionChatLinkStore.removeLinks(toChatId: linked,
                                                baseDir: CaptureWAL.documentsCaptures())
                _ = utterance // link pruned; the row rebuilds without it via onChanged
            }
        }

        return ActionOptionsSheet(
            row: row,
            onContinue: continueChatId.map { chatId in
                { AmbientCardBroker.shared.continueChat(id: chatId) }
            },
            onAct: (chatCanCompose && continueChatId == nil ? row.seed : nil).map { seed in
                {
                    AmbientCardBroker.shared.prefillChat(
                        seed: seed,
                        context: .init(runSeed: row.runSeed,
                                       captureId: captureId,
                                       utterance: row.utterance,
                                       category: categoryName(for: captureId)))
                }
            },
            onReject: row.utterance.map { utterance in
                { comment in record(.rejected, row: row, captureId: captureId,
                                    utterance: utterance, comment: comment,
                                    onChanged: onChanged) }
            },
            onRefine: row.utterance.map { utterance in
                { comment in record(.refined, row: row, captureId: captureId,
                                    utterance: utterance, comment: comment,
                                    onChanged: onChanged) }
            },
            onPromote: (inOthersGroup ? row.utterance : nil).map { utterance in
                {
                    ActionPromotionStore.promote(
                        captureId: captureId, utterance: utterance,
                        baseDir: CaptureWAL.documentsCaptures())
                    // CONTENT-FREE usage: the outcome word only, never the text.
                    UsageHook.action("promoted")
                    onChanged()
                }
            })
    }

    /// The action row for ONE surfaced utterance, rebuilt from the pipeline's
    /// stores — how the Activity page joins a ledger entry back to its action.
    /// Joins by THE shared utterance truncation (like every other pipeline
    /// join), so a >200-char utterance still resolves.
    static func row(forUtterance utterance: String,
                    captureId: String) -> ConversationActionsPresentation.Row? {
        let key = ConversationActions.utteranceKey(utterance)
        return rows(captureId: captureId).first {
            $0.utterance.map(ConversationActions.utteranceKey) == key
        }
    }

    /// The full Actions-face presentation for a capture, joined across all the
    /// stores (decisions, outcomes, answers, user actions, feedback, chat
    /// links) and attributed against the LOCALLY CACHED diarized transcript —
    /// so the moment diarization lands (any surface caches /content), a rebuild
    /// re-files others-uttered actions into the collapsed group. THE one
    /// builder call every action surface shares.
    /// `transcript` overrides the disk cache when the caller already holds a
    /// FRESHER diarized transcript in memory (the open detail view mid-fetch).
    static func presentation(captureId: String,
                             transcript: SpeakerTranscript? = nil)
    -> ConversationActionsPresentation {
        let base = CaptureWAL.documentsCaptures()
        let decisionLog = AmbientPrefs.decisionLogURL()
        let transcript: SpeakerTranscript? = transcript ?? {
            guard let cached = TranscriptCacheStore.load(captureId: captureId,
                                                         baseDir: base),
                  !cached.segments.isEmpty else { return nil }
            return SpeakerTranscript(speakers: cached.speakers,
                                     segments: cached.segments)
        }()
        return ConversationActionsPresentation.build(
            captureId: captureId,
            decisions: AmbientLane.readDecisions(at: decisionLog),
            outcomes: ConversationActions.readOutcomes(
                at: ActivityStore.cardsLogURL(besides: decisionLog)),
            answers: ConversationAnswerLog.answers(
                at: ActivityStore.answersLogURL(besides: decisionLog), captureId: captureId),
            userActions: UserActionStore.load(captureId: captureId, baseDir: base),
            feedback: ActionFeedbackStore.load(captureId: captureId, baseDir: base),
            chatLinks: ActionChatLinkStore.links(captureId: captureId, baseDir: base),
            transcript: transcript,
            othersInline: ActionSurfacePolicy.othersInline(),
            promotions: ActionPromotionStore.promoted(baseDir: base)
        )
    }

    /// Every action row for a capture — main list AND the "Heard from others"
    /// group — for surfaces that JOIN by utterance (the Activity ledger).
    static func rows(captureId: String) -> [ConversationActionsPresentation.Row] {
        let p = presentation(captureId: captureId)
        return p.rows + p.othersRows
    }

    /// The source conversation's category NAME right now (chat provenance).
    static func categoryName(for captureId: String) -> String? {
        ConversationCategoryStore(baseDir: CaptureWAL.documentsCaptures())
            .category(for: captureId)?.name
    }

    /// Persist one piece of action feedback: the full record (utterance +
    /// comment) into the on-phone `action-feedback.jsonl` the spotter's
    /// training loop reads, and the outcome WORD into `ambient-cards.jsonl` so
    /// the row's state resolves and the label ships over the redacted
    /// ambient-signal channel (comments never leave the phone).
    private static func record(_ kind: ActionFeedbackRecord.Kind,
                               row: ConversationActionsPresentation.Row,
                               captureId: String,
                               utterance: String, comment: String,
                               onChanged: @escaping () -> Void) {
        ActionFeedbackStore.append(
            ActionFeedbackRecord(captureId: captureId, utterance: utterance,
                                 summary: row.label, kind: kind, comment: comment,
                                 speaker: row.attribution?.wire,
                                 speakerName: row.attribution?.speakerName),
            baseDir: CaptureWAL.documentsCaptures())
        switch kind {
        case .rejected: AmbientCardBroker.rejected(seed: utterance)
        case .refined: AmbientCardBroker.refined(seed: utterance)
        }
        // CONTENT-FREE usage: ship ONLY the feedback KIND token. The utterance + the
        // free-text comment stay on-phone (they must NEVER leave the device).
        UsageHook.action(kind.rawValue)
        onChanged()
    }
}
