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
// UIKit supplies the device/battery fields of the shipped envelope below. Guarded and
// top-level — nesting it inside the Combine check would tie one framework's availability
// to another's for no reason.
#if canImport(UIKit)
import UIKit
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

    // MARK: - The command side of the split

    /// SOMETHING THE APP DID, as opposed to something it noticed.
    ///
    /// WHY THIS TYPE EXISTS. Everything this log has ever held is a sentence at a level, so
    /// "the app issued a delete" and "the app saw a disconnect" are the same kind of line and
    /// neither can be found without grepping English. The recorder surface is the first place
    /// that has to tell them apart — an errand that ran, an errand that stopped, and a file
    /// taken into custody are the three facts a slow failure is diagnosed from, and two of
    /// them are things the app CHOSE to do.
    ///
    /// Every field is a content-free token or a device-supplied identifier, the same
    /// discipline `FoundryXDiagContext` is held to: `subject` carries the recorder's own name
    /// for a file (`<date>/<timestamp>`), never a title, a transcript or an account.
    public struct Command: Sendable, Equatable {
        public let ts: Date
        /// A dotted name from a closed vocabulary — see `PocketErrandCommand`.
        public let name: String
        /// What the command was about, as a token.
        public let subject: String
        /// How it ended, or `nil` while it is still running. A command with no outcome that
        /// never gains one is itself the finding.
        public let outcome: String?

        public init(ts: Date, name: String, subject: String, outcome: String?) {
            self.ts = ts; self.name = name; self.subject = subject; self.outcome = outcome
        }
    }

    /// THE COMMAND STREAM. Ordered, bounded by the same ring `entries` is, and separate from
    /// the observations so a command can be found by NAME rather than by phrasing.
    @Published public private(set) var commands: [Command] = []

    /// Record a command. Safe from any thread — hops to main for the @Published write, the
    /// same way `log(_:_:)` does.
    ///
    /// IT ALSO WRITES AN ENTRY, and that is not redundancy. `flush()` ships `entries` and
    /// nothing else, so a command that lived only in the new stream would be a line the
    /// on-call reader used to be able to see and now cannot — a diagnostic regression sold as
    /// an improvement. The entry's text is a PINNED wire form for the same reason
    /// `FoundryXDiagContext.wireHeader` is: a server-side grep depends on it.
    public func command(_ name: String, subject: String = "", outcome: String? = nil) {
        let made = Command(ts: Date(), name: name, subject: subject, outcome: outcome)
        if Thread.isMainThread {
            appendCommand(made)
        } else {
            DispatchQueue.main.async { [weak self] in self?.appendCommand(made) }
        }
    }

    /// Every command issued under one name, in order.
    public func commands(named name: String) -> [Command] {
        commands.filter { $0.name == name }
    }

    private func appendCommand(_ made: Command) {
        commands.append(made)
        if commands.count > cap { commands.removeFirst(commands.count - cap) }
        // AN OUTCOME THAT IS NOT THE HAPPY ONE IS FINDABLE ABOVE `info`. `nil` is "still
        // running" and every deliberate success says so in its own word, so the levels stay
        // honest without this file knowing any surface's vocabulary.
        let level: Level = (made.outcome == nil || made.outcome == Self.succeeded) ? .info : .warn
        append(level, Self.wireForm(made))
    }

    /// The outcome token a command uses when it did exactly what it set out to do. A closed
    /// value rather than each caller's adjective, so the level rule above has something to
    /// compare against.
    public static let succeeded = "ok"

    /// ONE PINNED WIRE FORM for a command line: `cmd <name> subject=<subject>[ outcome=<o>]`.
    static func wireForm(_ command: Command) -> String {
        var text = "cmd \(command.name) subject=\(command.subject)"
        if let outcome = command.outcome { text += " outcome=\(outcome)" }
        return text
    }

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

    /// THE PROCESS-WIDE DIAGNOSTIC LOG.
    ///
    /// Nineteen production call sites in `App/` constructed a type that accepts a `DoorLog`
    /// and passed nothing, so everything those types reported was discarded — including
    /// `RecordingDeviceAttachment`, whose entire `RecordingDeviceUnreachableReason` taxonomy
    /// exists to say WHERE A TAP STOPPED, and `FoundryAuth` on the account-deletion screen,
    /// which failed for the owner with nothing left behind to read. Measured against the
    /// live relay afterwards: 27 lines total, and not one `recording device:` line.
    ///
    /// The reason they passed nothing is structural, not careless: most of those views have
    /// no log in scope and never did. Threading one through eight view files would fix the
    /// nineteen and lose the twentieth. A diagnostic log is genuinely process-wide, so this
    /// is the shape that makes "every log reaches the relay" true by default rather than by
    /// vigilance.
    ///
    /// Cheap when unconfigured: with no `setRemoteSink`, `flush` returns immediately and
    /// nothing leaves the device, which is what keeps it inert under test.
    public static let shared = DoorLog()

    /// How the shipped header is built. Overridable so tests can pin the wire shape without
    /// a device, and so a host that already knows its context does not re-read UIKit.
    public nonisolated(unsafe) static var envelope: @Sendable () -> FoundryXDiagContext = {
        FoundryXDiagContext.current()
    }

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
        // ONE HEADER, EVERY BATCH. It used to say "FoundryX device log" and nothing else, so
        // a line on the relay could not be attributed to a build, a device or an install —
        // which made the log readable and not diagnosable. Re-read per flush rather than
        // captured once: battery and free space are the fields most likely to explain what
        // the batch is about, and a value frozen at launch would describe a phone that no
        // longer exists.
        let body = ([Self.envelope().wireHeader] + batch.map {
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

/// THE ONE ENVELOPE EVERY SHIPPED LOG LINE TRAVELS UNDER.
///
/// Before this there were three, and no two agreed:
///
///     DoorLog        "FoundryX device log"                    — nothing at all
///     RemoteSession  "FoundryX 1.2(778840) email=… status=…"  — the only identity, and it was PII
///     PerfTelemetry  "perf build=778840 dev=65b1b58e span=…"  — build + anonymous install
///
/// So a line that reached the relay could not reliably be attributed to a build, a device, or
/// even a person's install, and the one field that DID identify anybody was an email address
/// on an endpoint that serves `GET /diag/log` to anyone who asks.
///
/// This adopts the discipline already written down for the fleet in `foundry-kit-telemetry`
/// (`standard.rs`): PINNED field names so two producers cannot name the same thing
/// differently, and "every value is a content-free safe token or a numeric measure". The
/// identity primitive is the one `PerfTelemetry` already chose and documented — an
/// `identifierForVendor`-derived install id that "segments lines by install WITHOUT
/// identifying the person" — so correlation survives and the person does not appear.
///
/// WHAT IS DELIBERATELY ABSENT: email, account scope, display name, coordinates. Nick asked
/// for "which user" and "location"; on a publicly readable endpoint the honest form of
/// "which user" is a stable anonymous install id, and the honest form of "location" is a
/// locale + timezone (which is what actually explains behaviour) rather than a position.
public struct FoundryXDiagContext: Sendable, Equatable {
    /// Marketing version, e.g. "1.2".
    public let version: String
    /// Build number — the field that answers "is this the fix?", e.g. "778840".
    public let build: String
    /// Stable per-install anonymous id. Same derivation as `PerfTelemetry.installId`, so a
    /// `perf` line and a `door` line from one handset correlate.
    public let installId: String
    /// Hardware identifier, e.g. "iPhone15,2" — a token, not a marketing name.
    public let device: String
    /// OS token, e.g. "iOS-18.2".
    public let os: String
    /// Battery as a percentage 0–100, or -1 when unknown. Numeric measure, per the standard.
    public let batteryPct: Int
    /// Charging state as a closed categorical token: charging | unplugged | full | unknown.
    public let power: String
    /// Locale token, e.g. "en_US".
    public let locale: String
    /// Timezone identifier, e.g. "America/Denver".
    public let timezone: String
    /// Free disk space in MB, or -1 when unknown.
    public let freeMB: Int

    public init(version: String, build: String, installId: String, device: String, os: String,
                batteryPct: Int, power: String, locale: String, timezone: String, freeMB: Int) {
        self.version = version; self.build = build; self.installId = installId
        self.device = device; self.os = os; self.batteryPct = batteryPct; self.power = power
        self.locale = locale; self.timezone = timezone; self.freeMB = freeMB
    }

    /// The wire form. ONE pinned order, `key=value`, space-separated — the shape server-side
    /// grep and any future parser depend on, which is why it is built here and asserted in
    /// tests rather than interpolated at each call site.
    public var wireHeader: String {
        "fx app=foundryx version=\(version) build=\(build) install=\(installId) "
        + "device=\(device) os=\(os) battery=\(batteryPct) power=\(power) "
        + "locale=\(locale) tz=\(timezone) freeMB=\(freeMB)"
    }

    /// Read the live context off this handset. Pure-Foundation fields work everywhere; the
    /// UIKit ones degrade to explicit unknowns rather than being silently omitted, because a
    /// missing field and an unknown field are different facts.
    public static func current(bundle: Bundle = .main) -> FoundryXDiagContext {
        let info = bundle.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"

        var install = "unknown"
        var device = "unknown"
        var os = "unknown"
        var battery = -1
        var power = "unknown"
        #if canImport(UIKit)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            install = String(idfv.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        }
        var sysinfo = utsname(); uname(&sysinfo)
        device = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "unknown" }
        }
        os = "\(UIDevice.current.systemName)-\(UIDevice.current.systemVersion)"
            .replacingOccurrences(of: " ", with: "")
        // Monitoring must be enabled or the level reads -1 forever. Enabling it is cheap and
        // the value is exactly the kind of thing that explains a recorder that stopped.
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? -1 : Int((level * 100).rounded())
        switch UIDevice.current.batteryState {
        case .charging: power = "charging"
        case .full:     power = "full"
        case .unplugged: power = "unplugged"
        default:        power = "unknown"
        }
        #endif

        var freeMB = -1
        if let vals = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = vals.volumeAvailableCapacityForImportantUsage {
            freeMB = Int(bytes / 1_048_576)
        }

        return FoundryXDiagContext(
            version: version, build: build, installId: install, device: device, os: os,
            batteryPct: battery, power: power,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            freeMB: freeMB)
    }
}
