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

    // Remote diagnostics sink (M5 R1b): when set, new entries are shipped (batched,
    // best-effort) to the relay's /diag/log so the phone's BLE/audio/capture/chat
    // behavior is observable SERVER-SIDE — no need to copy logs off the device.
    private var sink: URL?
    private var shipped = 0
    private var flushScheduled = false
    private var heartbeat: Timer?

    /// Periodic backstop flush cadence (seconds). The debounced per-entry flush ships a
    /// burst quickly; this guarantees a steady, low-rate trickle reaches the relay even
    /// during quiet stretches (so `/diag/log` is never silent while the app is live) and
    /// re-tries entries a dropped fire-and-forget POST never delivered. Tunable.
    public nonisolated static let flushInterval: TimeInterval = 15

    public init(cap: Int = 500) { self.cap = cap }

    /// Point the log at the relay diag endpoint (e.g. `…:8788/diag/log`) and start the
    /// periodic backstop flush. Emits a one-line transport marker so the desktop/relay
    /// can confirm the phone→relay diag path is live (grep `diag transport online`).
    public func setRemoteSink(_ url: URL?) {
        sink = url
        heartbeat?.invalidate(); heartbeat = nil
        guard url != nil else { return }
        info("diag transport online — shipping phone log to \(url!.absoluteString)")
        let t = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            // Flush on the main thread (where shipped/entries are mutated).
            if Thread.isMainThread { self?.flush() }
            else { DispatchQueue.main.async { self?.flush() } }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

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
        if entries.count > cap {
            let removed = entries.count - cap
            entries.removeFirst(removed)
            shipped = max(0, shipped - removed)
        }
        scheduleFlush(immediate: level == .error)
    }

    // Coalesced ship: errors flush now; otherwise debounce ~1.5s so a burst of
    // entries goes in one POST. Main-thread only (called from append).
    private func scheduleFlush(immediate: Bool) {
        guard sink != nil else { return }
        if immediate { flush(); return }
        if flushScheduled { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        guard let sink, shipped < entries.count else { return }
        let batch = entries[shipped...]
        shipped = entries.count
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = (["FoundryX device log"] + batch.map {
            "\(fmt.string(from: $0.ts)) [\($0.level.rawValue.uppercased())] \($0.text)"
        }).joined(separator: "\n")
        var req = URLRequest(url: sink)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()  // fire-and-forget
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
