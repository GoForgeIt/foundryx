// ConversationRecap — a living recap of what the user talked about
// (features/conversation-recaps.feature). The DAILY recap is a narrative +
// insights over the day's conversations, rebuilt each time a new conversation
// finishes processing (so it grows through the day). The WEEKLY recap is the
// same richness across the week, refreshed at end-of-week and on demand
// (week-to-date). A recap exists only for a period that had conversations, and
// is composed from what was ACTUALLY said (titles + summaries) — never invented.
//
// The narrative/insight PROSE is produced by a RecapComposer seam (Apple
// Foundation Models in the app, a deterministic double in tests). Even with no
// model, a genuinely useful recap stands: the deterministic composer threads the
// conversation summaries into a narrative and lifts each conversation's subject
// into an insight — so nothing is fabricated.

import Foundation
import Combine

/// The conversation-finished event (blocker resolution B3): `CaptureManager` posts
/// this at the END of the finalize success path with the finalized captureId, so
/// the Activity recap can rebuild the DAILY recap live — it grows through the day
/// as conversations finish, not only when the screen (re)appears.
public extension Notification.Name {
    static let foundryxConversationFinalized = Notification.Name("foundryxConversationFinalized")
}

/// One typed insight in a recap (blocker resolution B4). The TYPE is a
/// deterministic label from a fixed set (testable, pure heuristic); the TEXT is
/// composer-generated prose (model or deterministic double); the SOURCE is the
/// conversation it was drawn from, so every insight is attributed.
public struct RecapInsight: Equatable, Codable, Sendable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case connection = "Connection"
        case decision   = "Decision"
        case people     = "People"
        case followUp   = "Follow up"
        case trend      = "Trend"
    }
    public let kind: Kind
    /// The insight prose (composer-generated). Asserted only for non-emptiness.
    public let text: String
    /// The title of the conversation this insight was drawn from (provenance).
    public let sourceTitle: String

    public init(kind: Kind, text: String, sourceTitle: String) {
        self.kind = kind
        self.text = text
        self.sourceTitle = sourceTitle
    }

    /// The provenance line shown under an insight — "from <conversation title>".
    public var provenance: String { sourceTitle.isEmpty ? "" : "from \(sourceTitle)" }
}

/// One conversation's contribution to a recap: what the app knows about it.
public struct RecapConversation: Equatable, Sendable {
    public let captureId: String
    public let title: String
    public let summary: String
    /// When it was captured (for day/week bucketing + freshness).
    public let at: Date

    public init(captureId: String, title: String, summary: String, at: Date) {
        self.captureId = captureId
        self.title = title
        self.summary = summary
        self.at = at
    }
}

public enum RecapSpan: Equatable, Sendable {
    case day(Date)          // start-of-day
    case week(Date)         // start-of-week
    /// A mid-week "so far" view: week start through `asOf`.
    case weekToDate(start: Date, asOf: Date)
}

/// A built recap: the narrative + insights over a period's conversations.
public struct ConversationRecap: Equatable, Sendable, Identifiable {
    public let span: RecapSpan
    /// Multi-sentence narrative of the period.
    public let narrative: String
    /// A few TYPED insights (connections, decisions, people, follow-ups, trends)
    /// drawn from the conversations — each carries its type + source conversation.
    public let insights: [RecapInsight]
    /// How many conversations this covers.
    public let conversationCount: Int
    /// The newest conversation's time — drives the "updated after N" freshness line.
    public let updatedAt: Date

    public var id: String {
        switch span {
        case .day(let d): return "day-\(UInt64(d.timeIntervalSince1970))"
        case .week(let d): return "week-\(UInt64(d.timeIntervalSince1970))"
        case .weekToDate(let s, _): return "wtd-\(UInt64(s.timeIntervalSince1970))"
        }
    }

    /// The freshness line shown under the recap (prototype "13 Activity" copy). The
    /// daily line advertises that the recap grows through the day; the weekly line
    /// states the end-of-week close, and flips to "updated just now" after an
    /// ad-hoc week-to-date refresh.
    /// - Parameter weekUpdated: true right after the user tapped "Update week to date".
    public func freshnessLine(weekUpdated: Bool = false) -> String {
        let n = conversationCount
        let countPhrase = "\(n) conversation\(n == 1 ? "" : "s")"
        switch span {
        case .day:
            return "Grows after each processed conversation · Updated after \(countPhrase) · \(Self.timeString(updatedAt))"
        case .week:
            return "Week to date · Updated after \(countPhrase). Final weekly recap closes Sunday."
        case .weekToDate:
            return weekUpdated
                ? "Week to date updated just now. Final weekly recap closes Sunday."
                : "Week to date · Updated after \(countPhrase). Final weekly recap closes Sunday."
        }
    }

    private static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

/// Produces the narrative + insights prose from a period's conversations. The
/// app backs this with Apple Foundation Models; tests use a deterministic
/// double. `isAvailable == false` ⇒ the deterministic composition stands.
public protocol RecapComposer: Sendable {
    var isAvailable: Bool { get }
    /// Return (narrative, insights). Composed from the conversations only.
    func compose(_ conversations: [RecapConversation], span: RecapSpan) async -> (narrative: String, insights: [String])?
}

extension CaptureManager {
    /// The conversations the recaps draw on: every browsable capture that has a
    /// title or summary (its content), with its start time. Conversations still
    /// processing (no title/summary yet) don't contribute until they finish —
    /// which is exactly the "rebuilt after each conversation is processed"
    /// behavior (a new finished conversation appears in the pool).
    public func recapConversationPool() -> [RecapConversation] {
        visibleCaptures.compactMap { wal in
            let card = cardMeta(for: wal.captureId)
            let title = (card?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (card?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !summary.isEmpty else { return nil }
            return RecapConversation(captureId: wal.captureId, title: title,
                                     summary: summary, at: conversationStartDate(wal))
        }
    }
}

public enum ConversationRecapEngine {

    /// The conversations that belong to a span, from a pool. Pure bucketing.
    public static func conversations(in span: RecapSpan, from pool: [RecapConversation],
                                     calendar: Calendar = .current) -> [RecapConversation] {
        let range = dateRange(for: span, calendar: calendar)
        return pool.filter { range.contains($0.at) }.sorted { $0.at < $1.at }
    }

    /// Build the recap for a span, or nil when the period had no conversations
    /// (silence is a feature). Uses `composer` when available, else the
    /// deterministic composition — either way `count`/`updatedAt` are real.
    public static func build(span: RecapSpan, from pool: [RecapConversation],
                             composer: RecapComposer? = nil,
                             calendar: Calendar = .current) async -> ConversationRecap? {
        let convos = conversations(in: span, from: pool, calendar: calendar)
        guard !convos.isEmpty else { return nil }

        let composed: (narrative: String, insights: [String])
        if let composer, composer.isAvailable,
           let c = await composer.compose(convos, span: span) {
            composed = c
        } else {
            composed = deterministic(convos, span: span)
        }
        // Wrap the composer's prose insights into TYPED, ATTRIBUTED insights (B4):
        // the label is a deterministic pure heuristic; the prose is the composer's;
        // each is traced back to the real conversation it best matches.
        let typed = typedInsights(from: composed.insights, over: convos, span: span)
        return ConversationRecap(
            span: span,
            narrative: composed.narrative,
            insights: typed,
            conversationCount: convos.count,
            updatedAt: convos.map(\.at).max() ?? Date(timeIntervalSince1970: 0))
    }

    /// Turn composer prose insights into typed, attributed `RecapInsight`s. The
    /// TYPE comes from the deterministic `label` heuristic (testable); the TEXT is
    /// the composer's prose; the SOURCE is the conversation whose title/summary the
    /// insight best matches, so nothing is unattributed.
    public static func typedInsights(from prose: [String], over convos: [RecapConversation],
                                     span: RecapSpan) -> [RecapInsight] {
        prose.compactMap { raw -> RecapInsight? in
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let source = bestSource(for: text, in: convos)
            let kind = label(forText: text, source: source, span: span)
            return RecapInsight(kind: kind, text: text, sourceTitle: source?.title ?? "")
        }
    }

    /// Deterministic insight-type heuristic (pure, testable). Priority order is
    /// deliberate so the prototype's own insight lines classify correctly:
    /// Decision → Trend (weekly) → Follow up → Connection → People, else Connection.
    public static func label(forText text: String, source: RecapConversation?,
                             span: RecapSpan) -> RecapInsight.Kind {
        let haystack = (text + " " + (source?.summary ?? "")).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { haystack.contains($0) } }

        if has(["decide", "decided", "chose", "choose", "agreed", "keep the",
                "approved", "go with", "settled on"]) { return .decision }

        let isWeek: Bool
        switch span { case .day: isWeek = false; default: isWeek = true }
        if isWeek, has(["came up", "more than", "most ", "recurring", "pattern",
                        "trend", "across ", "every day", "than any other"]) { return .trend }

        if has(["send", "review", "due", "resched", "follow up", "follow-up",
                "next week", "tomorrow", "reminder", "remind", "publish", "draft",
                "schedule", "hold thursday", "protect thursday", "add ", "task",
                "finish"]) { return .followUp }

        if has(["same", "both", "answer", "connect", "relates", "shared",
                "need the same"]) { return .connection }

        if has(["owns", "coordinat", "bridge", "between", " with ", "team",
                "client", "call", "meeting", "standup", "sync", "1:1"]) { return .people }

        return .connection
    }

    /// The conversation an insight best belongs to: exact title match wins, else the
    /// conversation whose title/summary shares the most words with the insight, else
    /// the first conversation (so provenance is always real, never invented).
    static func bestSource(for text: String, in convos: [RecapConversation]) -> RecapConversation? {
        guard !convos.isEmpty else { return nil }
        let lowered = text.lowercased()
        if let exact = convos.first(where: { !$0.title.isEmpty && lowered.contains($0.title.lowercased()) }) {
            return exact
        }
        let words = Set(lowered.split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        func overlap(_ c: RecapConversation) -> Int {
            let cw = Set((c.title + " " + c.summary).lowercased()
                .split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
            return words.intersection(cw).count
        }
        let best = convos.max { overlap($0) < overlap($1) }
        if let best, overlap(best) > 0 { return best }
        return convos.first
    }

    /// A genuinely useful recap with NO model: thread the conversation summaries
    /// into a narrative, and lift each conversation's subject into an insight.
    /// Never invents a topic — every sentence traces to a real conversation.
    static func deterministic(_ convos: [RecapConversation], span: RecapSpan)
        -> (narrative: String, insights: [String]) {
        let n = convos.count
        let opener: String
        switch span {
        case .day: opener = n == 1 ? "One conversation today." : "\(n) conversations today."
        case .week, .weekToDate: opener = "\(n) conversation\(n == 1 ? "" : "s") this week."
        }
        // Narrative: opener + each conversation's summary (falling back to title),
        // as sentences. Bounded so it stays readable.
        let sentences = convos.prefix(8).map { c -> String in
            let body = c.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body.hasSuffix(".") ? body : body + "." }
            return t.isEmpty ? "An untitled conversation." : "\(t)."
        }
        let narrative = ([opener] + sentences).joined(separator: " ")
        // Insights: one per conversation subject (title preferred), deduped.
        var seen = Set<String>()
        let insights = convos.compactMap { c -> String? in
            let subject = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = subject.lowercased()
            guard !subject.isEmpty, seen.insert(key).inserted else { return nil }
            return subject
        }
        return (narrative, Array(insights.prefix(6)))
    }

    /// Start-of-today and start-of-this-week spans for "now" — the two recaps the
    /// Activity view shows. Week starts on the calendar's firstWeekday.
    public static func currentSpans(now: Date = Date(), calendar: Calendar = .current)
        -> (day: RecapSpan, week: RecapSpan) {
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        return (.day(dayStart), .week(weekStart))
    }

    /// A stable id for a span (mirrors `ConversationRecap.id`) — the cache key that
    /// pins a persisted recap to the exact day/week it was built for, so a stale
    /// day's recap is never shown as today's.
    public static func spanId(_ span: RecapSpan) -> String {
        switch span {
        case .day(let d): return "day-\(UInt64(max(0, d.timeIntervalSince1970)))"
        case .week(let d): return "week-\(UInt64(max(0, d.timeIntervalSince1970)))"
        case .weekToDate(let s, _): return "wtd-\(UInt64(max(0, s.timeIntervalSince1970)))"
        }
    }

    /// A stable signature of the conversation set feeding a span — the captureId +
    /// time + content of every conversation in the span. Two runs over the SAME set
    /// hash identically (AC4: unchanged set ⇒ no re-run); any add / finalize / edit
    /// changes it (⇒ refresh). Deterministic across launches (FNV-1a, not the
    /// per-process-seeded `Hasher`).
    public static func poolSignature(for span: RecapSpan, from pool: [RecapConversation],
                                     calendar: Calendar = .current) -> String {
        let convos = conversations(in: span, from: pool, calendar: calendar)
        let joined = convos.map {
            "\($0.captureId)|\(Int($0.at.timeIntervalSince1970))|\($0.title)|\($0.summary)"
        }.joined(separator: "\u{1f}")
        return "\(convos.count):\(fnv1a(joined))"
    }

    /// Deterministic 64-bit FNV-1a over UTF-8, hex-encoded. Stable across launches
    /// (unlike Swift's randomized `Hasher`), which the recap cache signature needs.
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The date interval a span covers.
    static func dateRange(for span: RecapSpan, calendar: Calendar) -> Range<Date> {
        switch span {
        case .day(let start):
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return start..<end
        case .week(let start):
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            return start..<end
        case .weekToDate(let start, let asOf):
            // Inclusive of `asOf` (a tick past, so "through now" includes now).
            return start..<asOf.addingTimeInterval(1)
        }
    }
}

// MARK: - Presentation (B1: pure model the Activity view renders from)

/// Everything the Activity recap card renders, computed from a built recap. The
/// SwiftUI view is a thin renderer of this; the brine tests assert on THIS (App
/// views aren't in the SPM package). Mirrors the prototype "13 Activity" card:
/// eyebrow micro-label → serif heading → narrative → typed insights → freshness.
public struct ActivityRecapPresentation: Equatable, Codable, Sendable {
    /// The forge micro-label eyebrow: "Daily recap" / "Weekly recap".
    public let eyebrow: String
    /// The serif heading: "Today" / "This week".
    public let heading: String
    public let narrative: String
    public let insights: [RecapInsight]
    public let freshnessLine: String
    /// Weekly cards carry the ad-hoc "Update week to date" button; daily do not.
    public let showsUpdateWeekToDate: Bool
    public let conversationCount: Int

    public init(eyebrow: String, heading: String, narrative: String,
                insights: [RecapInsight], freshnessLine: String,
                showsUpdateWeekToDate: Bool, conversationCount: Int) {
        self.eyebrow = eyebrow
        self.heading = heading
        self.narrative = narrative
        self.insights = insights
        self.freshnessLine = freshnessLine
        self.showsUpdateWeekToDate = showsUpdateWeekToDate
        self.conversationCount = conversationCount
    }

    /// Build the card presentation from a recap. `weekUpdated` flips the weekly
    /// freshness line to "updated just now" after an ad-hoc week-to-date refresh.
    public static func make(from recap: ConversationRecap, weekUpdated: Bool = false)
        -> ActivityRecapPresentation {
        let isWeek: Bool
        switch recap.span { case .day: isWeek = false; default: isWeek = true }
        return ActivityRecapPresentation(
            eyebrow: isWeek ? "Weekly recap" : "Daily recap",
            heading: isWeek ? "This week" : "Today",
            narrative: recap.narrative,
            insights: recap.insights,
            freshnessLine: recap.freshnessLine(weekUpdated: weekUpdated),
            showsUpdateWeekToDate: isWeek,
            conversationCount: recap.conversationCount)
    }
}

// MARK: - Recap cache (T3 AC3/AC4: instant render + inference only on change)

/// The persisted daily/weekly recap presentations. Re-entering Activity renders
/// the last-built recap synchronously from this cache (AC3 — no visible
/// repopulate), and on-device inference re-runs only when the underlying
/// conversation set changed (AC4). Each entry pins the span it was built for +
/// the pool signature that produced it.
public struct RecapCache: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var spanId: String
        public var signature: String
        public var presentation: ActivityRecapPresentation
        public init(spanId: String, signature: String, presentation: ActivityRecapPresentation) {
            self.spanId = spanId
            self.signature = signature
            self.presentation = presentation
        }
    }
    public var daily: Entry?
    public var weekly: Entry?
    public init(daily: Entry? = nil, weekly: Entry? = nil) {
        self.daily = daily
        self.weekly = weekly
    }
}

/// Reads/writes `recap-cache.json` in the captures/documents dir. Best-effort:
/// a missing/corrupt file just yields an empty cache (the recap rebuilds).
public enum RecapCacheStore {
    public static func fileURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("recap-cache.json")
    }

    public static func load(baseDir: URL) -> RecapCache {
        guard let data = try? Data(contentsOf: fileURL(baseDir: baseDir)),
              let cache = try? JSONDecoder().decode(RecapCache.self, from: data) else {
            return RecapCache()
        }
        return cache
    }

    public static func save(_ cache: RecapCache, baseDir: URL) {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL(baseDir: baseDir), options: .atomic)
    }
}

// MARK: - Live recap model (B3: rebuilds the daily recap on the finished event)

/// The Activity view's recap driver. It owns the daily + weekly presentations and
/// rebuilds the DAILY recap whenever a conversation finishes processing (the
/// `.foundryxConversationFinalized` event `CaptureManager` posts, B3) — so the
/// daily recap grows through the day without leaving the screen. The weekly recap
/// refreshes on demand (ad-hoc "Update week to date") and otherwise reflects the
/// closed week. This lives in FoundryXKit so it is testable (the SwiftUI view is a
/// thin renderer of `daily`/`weekly`).
@MainActor
public final class ActivityRecapModel: ObservableObject {
    public enum Mode: Equatable, Sendable { case day, week }

    @Published public private(set) var daily: ActivityRecapPresentation?
    @Published public private(set) var weekly: ActivityRecapPresentation?
    /// The selected segment — the view shows exactly one card for it.
    @Published public var mode: Mode = .day

    private let poolProvider: () -> [RecapConversation]
    private let composer: RecapComposer?
    private let calendar: Calendar
    private var weekUpdated = false
    /// When set, daily/weekly recaps persist to `recap-cache.json` here and are
    /// loaded synchronously on init (AC3), and rebuilds skip inference when the
    /// pool signature is unchanged (AC4). `nil` ⇒ pure in-memory (tests default).
    private let cacheBaseDir: URL?
    /// The span + pool signature the currently-shown daily/weekly recap was built
    /// for — the AC4 gate: an unchanged signature skips the (expensive) rebuild.
    private var dailySpanId: String?
    private var dailySignature: String?
    private var weeklySpanId: String?
    private var weeklySignature: String?
    // Set once on init (main), read once in the nonisolated deinit — unsafe-marked so
    // Swift 6 permits the deinit read of this non-Sendable token.
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private var inFlight: Task<Void, Never>?

    /// - Parameter observesFinalized: subscribe to the finished event (production).
    ///   Tests can drive `rebuildDaily()` directly, or post the notification.
    /// - Parameter cacheBaseDir: where `recap-cache.json` lives (the app's captures
    ///   dir). `nil` disables persistence entirely (the pre-cache behavior).
    public init(poolProvider: @escaping () -> [RecapConversation],
                composer: RecapComposer? = nil,
                calendar: Calendar = .current,
                cacheBaseDir: URL? = nil,
                observesFinalized: Bool = true) {
        self.poolProvider = poolProvider
        self.composer = composer
        self.calendar = calendar
        self.cacheBaseDir = cacheBaseDir
        // AC3: render the last-built recap instantly from disk. Only a cache entry
        // pinned to TODAY's day / THIS week is adopted (a stale day never shows).
        if let cacheBaseDir {
            let cache = RecapCacheStore.load(baseDir: cacheBaseDir)
            let spans = ConversationRecapEngine.currentSpans(calendar: calendar)
            let dayId = ConversationRecapEngine.spanId(spans.day)
            let weekId = ConversationRecapEngine.spanId(spans.week)
            if let d = cache.daily, d.spanId == dayId {
                daily = d.presentation
                dailySpanId = d.spanId
                dailySignature = d.signature
            }
            if let w = cache.weekly, w.spanId == weekId {
                weekly = w.presentation
                weeklySpanId = w.spanId
                weeklySignature = w.signature
            }
        }
        if observesFinalized {
            observer = NotificationCenter.default.addObserver(
                forName: .foundryxConversationFinalized, object: nil, queue: .main) { [weak self] _ in
                    // Delivered on main; hop through the actor + track for tests.
                    MainActor.assumeIsolated { self?.scheduleDailyRebuild() }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Build both recaps (screen appear).
    public func rebuildAll() async {
        await rebuildDaily()
        await rebuildWeekly()
    }

    /// Rebuild TODAY's recap from the current pool — the live, per-conversation path.
    /// AC4: when caching is on and the pool signature is unchanged from what the
    /// shown recap was built for, this returns without re-running inference.
    public func rebuildDaily() async {
        let pool = poolProvider()
        let spans = ConversationRecapEngine.currentSpans(calendar: calendar)
        let spanId = ConversationRecapEngine.spanId(spans.day)
        let signature = ConversationRecapEngine.poolSignature(for: spans.day, from: pool,
                                                              calendar: calendar)
        if cacheBaseDir != nil, daily != nil,
           dailySpanId == spanId, dailySignature == signature {
            return   // unchanged set already rendered — no re-run
        }
        if let recap = await ConversationRecapEngine.build(span: spans.day, from: pool,
                                                           composer: composer, calendar: calendar) {
            daily = .make(from: recap)
        } else {
            daily = nil
        }
        dailySpanId = spanId
        dailySignature = signature
        persist()
    }

    /// Rebuild the WEEK's recap (closed-week view: "Final weekly recap closes Sunday").
    /// Same AC4 signature gate as the daily path.
    public func rebuildWeekly() async {
        weekUpdated = false
        let pool = poolProvider()
        let spans = ConversationRecapEngine.currentSpans(calendar: calendar)
        let spanId = ConversationRecapEngine.spanId(spans.week)
        let signature = ConversationRecapEngine.poolSignature(for: spans.week, from: pool,
                                                              calendar: calendar)
        if cacheBaseDir != nil, weekly != nil,
           weeklySpanId == spanId, weeklySignature == signature {
            return
        }
        if let recap = await ConversationRecapEngine.build(span: spans.week, from: pool,
                                                          composer: composer, calendar: calendar) {
            weekly = .make(from: recap, weekUpdated: false)
        } else {
            weekly = nil
        }
        weeklySpanId = spanId
        weeklySignature = signature
        persist()
    }

    /// Write the current daily/weekly presentations (with their span + signature)
    /// to `recap-cache.json`. No-op when caching is disabled.
    private func persist() {
        guard let cacheBaseDir else { return }
        var cache = RecapCache()
        if let daily, let id = dailySpanId, let sig = dailySignature {
            cache.daily = .init(spanId: id, signature: sig, presentation: daily)
        }
        if let weekly, let id = weeklySpanId, let sig = weeklySignature {
            cache.weekly = .init(spanId: id, signature: sig, presentation: weekly)
        }
        RecapCacheStore.save(cache, baseDir: cacheBaseDir)
    }

    /// Ad-hoc "Update week to date": rebuild the weekly card over week-start→now and
    /// flip its freshness line to "updated just now" — distinct from the week-end close.
    public func updateWeekToDate() async {
        let pool = poolProvider()
        let spans = ConversationRecapEngine.currentSpans(calendar: calendar)
        guard case .week(let start) = spans.week else { return }
        let span = RecapSpan.weekToDate(start: start, asOf: Date())
        if let recap = await ConversationRecapEngine.build(span: span, from: pool,
                                                          composer: composer, calendar: calendar) {
            weekUpdated = true
            weekly = .make(from: recap, weekUpdated: true)
            weeklySpanId = ConversationRecapEngine.spanId(span)
            weeklySignature = ConversationRecapEngine.poolSignature(for: span, from: pool,
                                                                    calendar: calendar)
            persist()
        }
    }

    private func scheduleDailyRebuild() {
        inFlight = Task { [weak self] in await self?.rebuildDaily() }
    }

    /// Await any in-flight rebuild scheduled by the finished event (tests).
    public func settle() async {
        await inFlight?.value
    }
}
