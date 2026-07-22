// ConversationGrouping — the time-bucketing that turns the flat newest-first
// conversation list into dated sections (track 20260628). Pure + unit-tested so the
// bucketing is verifiable without any UI:
//
//   • DAY    for days in the current week        → "Today", "Yesterday", "Monday"…
//   • WEEK   for the weeks in the prior ~month    → "Last week", "2 weeks ago"…
//   • MONTH  for anything earlier                 → "June", "May", "May 2025"…
//
// Newest first. Each title maps to a CONTIGUOUS date range, so grouping a
// date-descending list by title yields correctly-ordered, non-repeating sections.

import Foundation

/// One section of the grouped conversation list: a header title + its items
/// (already in newest-first order).
public struct ConversationSection<Item>: Sendable where Item: Sendable {
    public let title: String
    public let items: [Item]
    public init(title: String, items: [Item]) {
        self.title = title
        self.items = items
    }
}

public enum ConversationGrouping {
    /// The section header a conversation `date` falls into, relative to `now`.
    ///
    /// Buckets, newest → oldest:
    ///  - `Today` / `Yesterday` — by calendar day.
    ///  - a weekday name (`Monday`) — earlier this calendar week.
    ///  - `Last week` / `N weeks ago` — the ~4 weeks before this one (the prior month).
    ///  - a month name (`June`, or `May 2025` across a year boundary) — anything earlier.
    public static func sectionTitle(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let startOfNowDay = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startOfDate, to: startOfNowDay).day ?? 0

        if dayDiff == 0 { return "Today" }
        if dayDiff == 1 { return "Yesterday" }

        // Whole-week distance between the week containing `date` and the week containing
        // `now` (respecting the calendar's firstWeekday).
        let weeks = weekDistance(from: date, to: now, calendar: calendar)
        if weeks == 0 {
            // Earlier this week (≥2 days ago) → weekday name.
            return weekdayName(of: date, calendar: calendar)
        }
        if weeks == 1 { return "Last week" }
        if weeks <= 4 { return "\(weeks) weeks ago" }   // the prior ~month, by week

        return monthName(of: date, now: now, calendar: calendar)
    }

    /// Group items into ordered, newest-first sections by their time bucket. Items are
    /// sorted by `date` descending; consecutive items sharing a section title fold into
    /// one section (each title is a contiguous date range, so sections never repeat).
    public static func group<Item: Sendable>(_ items: [Item],
                                             now: Date,
                                             calendar: Calendar = .current,
                                             date: (Item) -> Date) -> [ConversationSection<Item>] {
        groupPresorted(items.sorted { date($0) > date($1) },
                       now: now, calendar: calendar, date: date)
    }

    /// The same grouping for a list the caller ALREADY supplies newest-first — the
    /// conversation list's case: `visibleCaptures` is sorted date-descending at every
    /// rebuild, and the search/category filters preserve that order, so re-sorting it on
    /// every body pass was pure redundant work on the main actor (track
    /// `residual_on_main_actor_work`). `group(_:)` keeps the sort for callers that need it;
    /// the RENDER path calls this. Given a date-descending input the two are identical —
    /// `ResidualMainActorWorkTests.testPresortedGroupingIsIdenticalToSortingGrouping` pins
    /// that over a real hydrated, bucket-spanning library.
    ///
    /// PRECONDITION: `sorted` is date-DESCENDING. A real invariant, not a preference: the
    /// section fold below only closes a section when the title CHANGES, so unsorted input
    /// silently emits duplicated section titles and mis-ordered rows — a WRONG LIST rather
    /// than a crash, i.e. exactly the failure a comment alone would let ship. It is checked
    /// in DEBUG, where the check costs one extra `date()` pass over a list the fold below
    /// already calls `date()` on once per item.
    public static func groupPresorted<Item: Sendable>(_ sorted: [Item],
                                                      now: Date,
                                                      calendar: Calendar = .current,
                                                      date: (Item) -> Date) -> [ConversationSection<Item>] {
        #if DEBUG
        var previousDate: Date?
        for item in sorted {
            let d = date(item)
            if let previousDate {
                precondition(d <= previousDate,
                             "ConversationGrouping.groupPresorted requires date-DESCENDING " +
                             "input; got \(d) after \(previousDate). Use group(_:) (which " +
                             "sorts) or fix the caller's ordering — unsorted input silently " +
                             "produces duplicated, mis-ordered sections.")
            }
            previousDate = d
        }
        #endif
        var sections: [ConversationSection<Item>] = []
        var currentTitle: String?
        var bucket: [Item] = []
        for item in sorted {
            let title = sectionTitle(for: date(item), now: now, calendar: calendar)
            if title != currentTitle {
                if let currentTitle, !bucket.isEmpty {
                    sections.append(ConversationSection(title: currentTitle, items: bucket))
                }
                currentTitle = title
                bucket = [item]
            } else {
                bucket.append(item)
            }
        }
        if let currentTitle, !bucket.isEmpty {
            sections.append(ConversationSection(title: currentTitle, items: bucket))
        }
        return sections
    }

    // MARK: helpers

    /// Whole calendar weeks between the start-of-week of `date` and of `now`.
    private static func weekDistance(from date: Date, to now: Date, calendar: Calendar) -> Int {
        guard let nowWeekStart = startOfWeek(now, calendar: calendar),
              let dateWeekStart = startOfWeek(date, calendar: calendar) else { return 0 }
        let comps = calendar.dateComponents([.weekOfYear], from: dateWeekStart, to: nowWeekStart)
        return max(0, comps.weekOfYear ?? 0)
    }

    private static func startOfWeek(_ d: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: d)?.start
    }

    private static func weekdayName(of date: Date, calendar: Calendar) -> String {
        formatter(format: "EEEE", calendar: calendar).string(from: date)   // "Monday"
    }

    private static func monthName(of date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatter(format: sameYear ? "LLLL" : "LLLL yyyy",   // "June" / "May 2025"
                         calendar: calendar).string(from: date)
    }

    // MARK: formatter cache — never allocate a DateFormatter per row or per section

    /// A `DateFormatter` is one of the most expensive objects in Foundation to build
    /// (it drags in ICU), and `sectionTitle` is called ONCE PER ROW on the list's render
    /// path — so allocating one inside it allocated N of them per body pass. They are
    /// cached instead, keyed by everything that changes their output (format + calendar +
    /// locale + time zone), so behaviour is identical and the tests that pass explicit
    /// UTC/locale calendars still get their own instance.
    ///
    /// `DateFormatter` is not thread-safe, so the cache AND the `string(from:)` call that
    /// uses an instance are both under the lock (grouping runs on the main actor in the app,
    /// but the tests and the off-main warm paths must stay safe).
    nonisolated(unsafe) private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    /// Test seam: how many `DateFormatter`s the grouping has EVER built. The acceptance
    /// instrument for "no DateFormatter is allocated per row or per section on a render
    /// path" — grouping N rows must move this by at most the number of distinct
    /// (format, calendar) pairs, never by N.
    static var formatterAllocationsForTests: Int {
        formatterLock.lock(); defer { formatterLock.unlock() }; return formatters.count
    }

    private static func formatter(format: String, calendar: Calendar) -> LockedFormatter {
        let locale = calendar.locale ?? .current
        let key = "\(format)|\(calendar.identifier)|\(locale.identifier)|\(calendar.timeZone.identifier)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let hit = formatters[key] { return LockedFormatter(hit) }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        // NOTE: `timeZone` is deliberately NOT set — the old per-call formatter didn't set
        // it either, so leaving it to the formatter's own calendar/system resolution keeps
        // the output byte-identical. It IS part of the cache key so two calendars that
        // differ only by zone never share an instance.
        f.dateFormat = format
        formatters[key] = f
        return LockedFormatter(f)
    }

    /// A cached formatter handle whose only operation takes the shared lock — so two
    /// threads can never be inside the same (non-thread-safe) `DateFormatter` at once.
    private struct LockedFormatter {
        private let formatter: DateFormatter
        init(_ f: DateFormatter) { formatter = f }
        func string(from date: Date) -> String {
            ConversationGrouping.formatterLock.lock()
            defer { ConversationGrouping.formatterLock.unlock() }
            return formatter.string(from: date)
        }
    }
}
