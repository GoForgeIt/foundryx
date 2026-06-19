// DoorLog — a small, shared in-app event log for FoundryX so connection/stream
// behavior is observable on-device (we were flying blind when the phone couldn't
// reach the door). A bounded ring buffer of structured entries; `DoorClient`
// writes to it, the chat screen shows status + a "Copy logs" button that dumps
// it as plain text to paste elsewhere.
//
// `@unchecked Sendable`: every mutation is funneled onto the main thread (where
// the @Published fires), so the buffer is safe to hand to the Sendable
// `DoorClient` and write to from its background stream Task.

import Foundation
#if canImport(Combine)
import Combine
#endif

public final class DoorLog: ObservableObject, @unchecked Sendable {
    public enum Level: String, Sendable { case info, warn, error }

    public struct Entry: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let ts: Date
        public let level: Level
        public let text: String
    }

    @Published public private(set) var entries: [Entry] = []
    private let cap: Int

    public init(cap: Int = 500) { self.cap = cap }

    /// Append an entry. Safe from any thread — hops to main for the @Published write.
    public func log(_ level: Level, _ text: String) {
        if Thread.isMainThread {
            append(level, text)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(level, text) }
        }
    }

    public func info(_ t: String) { log(.info, t) }
    public func warn(_ t: String) { log(.warn, t) }
    public func error(_ t: String) { log(.error, t) }

    public func clear() {
        if Thread.isMainThread { entries.removeAll() }
        else { DispatchQueue.main.async { [weak self] in self?.entries.removeAll() } }
    }

    private func append(_ level: Level, _ text: String) {
        entries.append(Entry(ts: Date(), level: level, text: text))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    /// All entries as copyable plain text — one line each: `ISO8601 [LEVEL] text`.
    public func dump() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if entries.isEmpty { return "(no FoundryX log entries this session)" }
        return entries
            .map { "\(fmt.string(from: $0.ts)) [\($0.level.rawValue.uppercased())] \($0.text)" }
            .joined(separator: "\n")
    }
}
