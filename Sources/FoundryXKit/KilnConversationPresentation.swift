import Foundation

// Opening — and continuing — a chat that lives on the Mac.
//
// WHAT THIS EXISTS TO PREVENT
// ---------------------------
// The phone's first version of this screen was its own read-only transcript viewer: it asked
// the door for the WHOLE transcript, built a view for every turn eagerly, offered a button
// where a composer belongs, and — having no notion of where a reader wants to land — opened
// at the oldest turn in the file.
//
// Measured against the real library on 2026-08-05, through the live door:
//
//   largest chat        42,311 turns / 44.4 MB
//   fetch + decode         122 ms          ← under 1% of the cost
//   build EVERY turn    22,831 ms, then SIGSEGV
//   build newest 40         69 ms
//
// The cost was never the network. It was building turns nobody had scrolled to. So the
// window below is the fix, and it is a fix on the RENDER side because that is where the
// measurement said the time went.
//
// LIMITATION, STATED RATHER THAN WORKED AROUND: `GET /foundryx/chats/<id>/messages` takes no
// paging parameters at all. Probed live against every plausible spelling — `limit`, `offset`,
// `order`, `tail`, `before_seq`, `direction`, `from_end` — each returned the identical full
// 42,311-turn body. Tail paging over the wire needs a kiln-side change; until then the phone
// pages what it BUILDS, which is where the 22.8 seconds were.

/// How a chat that lives on the Mac is opened, paged and continued on the phone.
///
/// Pure and synchronous — the view chooses layout, this decides what may be built, where the
/// reader lands, and what has to happen before their first turn goes out.
public enum KilnConversationPresentation {

    /// How many turns are built at a time, newest first.
    ///
    /// 40 is a screenful and change on the largest phone. It is not a guess about
    /// prettiness: it is the difference between 69 ms and 22.8 seconds on the real corpus.
    public static let pageSize = 40

    /// What has to happen when the reader sends into this chat.
    ///
    /// TYPING IS THE ASK. A chat brought over from Claude Code or Codex has history but no
    /// live session behind it yet, so its first turn has to resume it. The reader never asks
    /// for that separately — they type, and the resume happens on the way out. It is
    /// RESUME-IN-PLACE: the same id, the same history, no fork and no copy.
    public enum SendPlan: Equatable, Sendable {
        /// Already live in Kiln — the turn goes straight out.
        case send
        /// Brought-over history that has never been picked up: resume it in place, then send.
        case resumeInPlaceThenSend
    }

    /// A chat from the Mac, opened: everything the door returned, plus how much of it may be
    /// built and where the reader lands.
    public struct Opened: Equatable, Sendable {

        /// Every turn the door returned, oldest → newest. Held, not built.
        public let turns: [KilnMessage]
        /// How many turns from the TAIL are built. Never the whole array on first open.
        public let shown: Int
        public let sendPlan: SendPlan

        public init(turns: [KilnMessage], shown: Int, sendPlan: SendPlan) {
            self.turns = turns
            self.shown = shown
            self.sendPlan = sendPlan
        }

        /// The turns that are actually built — the NEWEST `shown`, in reading order.
        public var visible: [KilnMessage] { Array(turns.suffix(shown)) }

        /// Turns older than the window. Held, unbuilt, one tap away.
        public var olderCount: Int { max(0, turns.count - shown) }
        public var hasOlder: Bool { olderCount > 0 }

        /// The turn the surface OPENS ON — the newest one, the way every chat app opens.
        /// `nil` only when there is nothing to land on.
        public var openAt: String? { visible.last?.id }

        /// The built turns in the exact shape `ChatViewModel.load(from:)` takes for a chat
        /// that started on this phone. Same type, same loader, same bubbles — which is the
        /// point: there is one chat surface, and this is how a Mac chat reaches it.
        public var stored: [ChatConversationStore.StoredMessage] {
            visible.map { ChatConversationStore.StoredMessage(role: $0.role, text: $0.text) }
        }
    }

    /// Open a chat from the Mac: hold every turn, build the newest page, and decide what its
    /// first outgoing turn has to do.
    public static func open(_ row: LibraryChatRow, turns: [KilnMessage],
                            pageSize: Int = pageSize) -> Opened {
        let page = max(1, pageSize)
        return Opened(
            turns: turns,
            shown: min(turns.count, page),
            // `offersPickUp` is the SAME predicate the library row uses — brought-over origin
            // and not yet resumed. It decided whether to show a button; now it decides what
            // the first send does. Nobody has to press anything either way.
            sendPlan: KilnConversationNotice.make(row).offersPickUp
                ? .resumeInPlaceThenSend
                : .send)
    }

    /// Build one more page of older turns. Idempotent at the top: once everything is built,
    /// this returns the same thing.
    public static func showOlder(_ opened: Opened, pageSize: Int = pageSize) -> Opened {
        Opened(turns: opened.turns,
               shown: min(opened.turns.count, opened.shown + max(1, pageSize)),
               sendPlan: opened.sendPlan)
    }

    /// The plan for the NEXT turn, once a turn has gone out under `plan`.
    ///
    /// A chat is picked back up exactly ONCE. Sending again into a chat that was resumed on
    /// the previous turn must not resume it a second time.
    public static func planAfterSending(_ plan: SendPlan) -> SendPlan { .send }

    /// The outgoing turn for a chat that lives on the Mac.
    ///
    /// Carries the Mac chat's OWN id, org and sensitivity — kiln-session open-or-resumes by
    /// (platform, chat_id, org), so this is what makes the turn land in the chat the reader
    /// is reading rather than in a new one beside it.
    public static func request(_ row: LibraryChatRow, text: String,
                               platform: String = "foundryx") -> ChatRequest {
        ChatRequest(message: text,
                    platform: platform,
                    chatId: row.id,
                    org: row.org,
                    sensitivity: row.sensitivity)
    }
}

/// The words this surface uses. Beside the logic that decides when each is shown, so a
/// scenario can assert the sentence and not just a boolean.
public enum KilnChatCopy {

    /// The composer's placeholder. It says what typing DOES, because on a chat brought over
    /// from another tool typing is also what picks it back up.
    public static let composerPlaceholder = "Reply here to carry on"

    /// The affordance for the turns held back above the window.
    public static func earlierTurns(_ count: Int) -> String {
        count == 1 ? "Show 1 earlier turn" : "Show \(count) earlier turns"
    }

    /// The chat could not be read. DELIBERATELY not the empty-chat words: a chat we could not
    /// fetch is not a chat where nothing was said, and saying so to someone whose Mac is
    /// asleep is the worst available answer.
    public static let unreadableTitle = "Couldn't load this chat"
    /// The genuinely-empty words, kept here so the two can be asserted to differ.
    public static let emptyTitle = "Nothing was said here yet"
}
