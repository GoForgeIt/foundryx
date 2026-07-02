// TodayRecap — the pure, on-disk loader behind the "Today at the Foundry" recap
// (usefulness slice; plan: deliverables/H_usefulness-implementation-plan.md). THIN
// CLIENT: it only COUNTS + FORMATS what already lives on disk under the capture store —
// it does NO analysis. It reads the same durable sidecars the conversation list +
// ConversationDetailView read (meta.json / card.json / transcript.json), applies the
// timeline's own empty/near-silent + discarded gates, keeps only conversations from the
// same calendar day as `now`, and returns them newest-first with per-conversation
// minutes when (and only when) they're derivable from a closed conversation's duration.
//
// Pure + unit-testable: give it a `baseDir`, `now`, and `calendar` and it's deterministic.

import Foundation

public struct TodayRecap: Equatable, Sendable {
    /// One of today's conversations — the phone's lightweight recap row. `minutes` is nil
    /// when the conversation has no derivable duration (no `ended_at` on disk yet).
    public struct Item: Equatable, Identifiable, Sendable {
        public let id: String          // captureId — deep-links straight into ConversationDetailView
        public let title: String
        public let startedAt: Date
        public let minutes: Int?

        public init(id: String, title: String, startedAt: Date, minutes: Int?) {
            self.id = id; self.title = title; self.startedAt = startedAt; self.minutes = minutes
        }
    }

    public let items: [Item]
    public var conversationCount: Int
    /// Sum of the derivable per-conversation minutes, or nil when NONE of today's
    /// conversations has a duration on disk (honest degradation — no fabricated total).
    public var totalMinutes: Int?

    public init(items: [Item], conversationCount: Int, totalMinutes: Int?) {
        self.items = items
        self.conversationCount = conversationCount
        self.totalMinutes = totalMinutes
    }

    public var isEmpty: Bool { items.isEmpty }
    public static let empty = TodayRecap(items: [], conversationCount: 0, totalMinutes: nil)

    /// Load today's conversations from the capture store on disk. `baseDir` defaults to
    /// the app's capture directory (`CaptureWAL.documentsCaptures()`) so callers just say
    /// `TodayRecap.load()`; tests pass a temp dir. "Today" is the same calendar day as
    /// `now` under `calendar` (device-local, so an evening recording lands on its local
    /// day — matching how the list buckets a capture's UTC-stamped start).
    public static func load(now: Date = Date(),
                            calendar: Calendar = .current,
                            baseDir: URL = CaptureWAL.documentsCaptures()) -> TodayRecap {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return .empty }

        var items: [Item] = []
        for dir in entries {
            let captureId = dir.lastPathComponent
            if captureId.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Discarded junk fragment — never counted (mirrors CaptureManager.loadExisting).
            if fm.fileExists(atPath: dir.appendingPathComponent(".discarded").path) { continue }

            let meta = ConversationMetaStore.load(captureId: captureId, baseDir: baseDir)
            let card = ConversationCardStore.load(captureId: captureId, baseDir: baseDir)
            let cached = TranscriptCacheStore.load(captureId: captureId, baseDir: baseDir)

            // Durable REAL START, same processing-time-proof priority the list uses:
            // meta.json start → card.json start → the capture-id's UTC stamp.
            guard let startSecs = startSeconds(meta: meta, card: card, captureId: captureId) else { continue }
            let startedAt = Date(timeIntervalSince1970: TimeInterval(startSecs))

            // Same calendar day as `now`.
            guard calendar.isDate(startedAt, inSameDayAs: now) else { continue }

            // Substance gate — mirror the timeline's empty/near-silent filter. When we
            // hold judge-able transcript text, require it to be meaningful; with no text
            // yet, require a durable readable tombstone (a card) so bare empty shells
            // aren't counted. Data is never deleted, just not surfaced.
            let text = cached?.transcript ?? card?.provisionalTranscript
            if let text, !text.isEmpty {
                let dur = meta?.durationSeconds.map { TimeInterval($0) }
                guard ConversationContentFilter.isMeaningful(transcript: text, durationSeconds: dur) else { continue }
            } else if card == nil {
                continue
            }

            // Minutes only when derivable — a closed conversation's duration. Same
            // rounding as the capture card's time-range so the two never disagree.
            let minutes = meta?.durationSeconds.map { max(1, Int((Double($0) / 60).rounded())) }
            items.append(Item(id: captureId, title: displayTitle(card: card, cached: cached),
                              startedAt: startedAt, minutes: minutes))
        }

        items.sort { $0.startedAt > $1.startedAt }   // newest first
        let mins = items.compactMap { $0.minutes }
        return TodayRecap(items: items,
                          conversationCount: items.count,
                          totalMinutes: mins.isEmpty ? nil : mins.reduce(0, +))
    }

    private static func startSeconds(meta: ConversationMeta?,
                                     card: ConversationCardMeta?,
                                     captureId: String) -> UInt64? {
        if let s = meta?.startedAt, s > 0 { return s }
        if let s = card?.startedAt, s > 0 { return s }
        if let s = CaptureIdTime.startedAt(fromCaptureId: captureId), s > 0 { return s }
        return nil
    }

    /// The conversation's NAME: the durable card title (Kiln or provisional), else the
    /// cached transcript's title, else a calm "Conversation" placeholder.
    private static func displayTitle(card: ConversationCardMeta?, cached: CachedTranscript?) -> String {
        if let t = card?.title, !t.isEmpty { return t }
        if let t = cached?.title, !t.isEmpty { return t }
        return "Conversation"
    }
}

public extension TodayRecap {
    /// Sample recap for headless screenshots / previews (Kevin-flavored). NOT shipped
    /// data — the orchestrator injects it via `InsightsView(injectedRecap:)`.
    static var sample: TodayRecap {
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }
        let items = [
            Item(id: "omi-sample-1", title: "Lantis kickoff call", startedAt: at(10, 41), minutes: 32),
            Item(id: "omi-sample-2", title: "Standup", startedAt: at(9, 15), minutes: 8),
            Item(id: "omi-sample-3", title: "Call with Mom", startedAt: at(8, 2), minutes: 7),
        ]
        return TodayRecap(items: items, conversationCount: items.count, totalMinutes: 47)
    }
}
