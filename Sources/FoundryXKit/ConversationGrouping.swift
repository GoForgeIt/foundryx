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
        let sorted = items.sorted { date($0) > date($1) }
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
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.dateFormat = "EEEE"          // "Monday"
        return f.string(from: date)
    }

    private static func monthName(of date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"   // "June" / "May 2025"
        return f.string(from: date)
    }
}
