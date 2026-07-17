// PerfTelemetry — the app measures its own performance and ships compact,
// segmentable lines to our diagnostics endpoint (features/perf-telemetry.feature).
//
// Why: until now the only way we learned about a slowdown was a user forwarding
// an Apple .ips hang report. This makes the app report its OWN launch + heavy
// work, and (App-side) adopt MetricKit so the SYSTEM's cross-user hang/launch/
// disk/CPU diagnostics reach us too. Every line is `perf …`-prefixed, carries
// the build + a stable ANONYMOUS install id (never a name/email/token), so the
// flat diag file can be grepped and aggregated per build.
//
// This file is the PURE, testable core (formatters + a span timer + a sink).
// The MetricKit subscriber lives in the App target (PerfMetricsSubscriber.swift)
// because MetricKit is iOS-only and needs the app lifecycle.

import Foundation

/// The stable context every perf line carries: which build, which install.
public struct PerfContext: Sendable, Equatable {
    public let build: String
    /// A stable per-install anonymous id (identifierForVendor's first 8 hex on
    /// device) — segments lines by install WITHOUT identifying the person.
    public let installId: String

    public init(build: String, installId: String) {
        self.build = build
        self.installId = installId
    }
}

/// Pure line formatters — one place, so the wire shape (what server-side grep /
/// aggregation depends on) is pinned by tests.
public enum PerfDiag {
    /// Default "this span is slow enough to notice" threshold (ms).
    public static let slowThreshold = 500

    public static func isSlow(ms: Int, threshold: Int = slowThreshold) -> Bool {
        ms >= threshold
    }

    /// A measured span: `perf build=… dev=… span=<name> ms=<n> [SLOW]`.
    public static func marker(name: String, ms: Int, ctx: PerfContext,
                              slowThreshold: Int = slowThreshold) -> String {
        var s = "\(head(ctx)) span=\(sanitize(name)) ms=\(ms)"
        if isSlow(ms: ms, threshold: slowThreshold) { s += " SLOW" }
        return s
    }

    /// A system hang diagnostic (MetricKit MXHangDiagnostic): `… hang ms=… at=<frame>`.
    public static func hang(ms: Int, blamedFrame: String, ctx: PerfContext) -> String {
        "\(head(ctx)) hang ms=\(ms) at=\(sanitize(blamedFrame))"
    }

    /// A system launch/responsiveness phase: `… launch phase=<phase> ms=<n>`.
    public static func launch(phase: String, ms: Int, ctx: PerfContext) -> String {
        "\(head(ctx)) launch phase=\(sanitize(phase)) ms=\(ms)"
    }

    /// A generic system metric line (CPU/memory/disk aggregate): `… metric <k>=<v>`.
    public static func metric(_ key: String, _ value: String, ctx: PerfContext) -> String {
        "\(head(ctx)) metric \(sanitize(key))=\(sanitize(value))"
    }

    /// The first frame belonging to our own binary in a call stack (the actionable
    /// blame), falling back to the leaf when the stack is all system frames.
    public static func firstOwnFrame(in stack: [String], own: String) -> String {
        for frame in stack where frame.contains(own) {
            // Strip the frame index + module, keep the symbol.
            let parts = frame.split(separator: " ", maxSplits: 2)
            return parts.count == 3 ? String(parts[2]) : frame
        }
        return stack.first.map { line -> String in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : line
        } ?? "unknown"
    }

    /// The shared `perf build=… dev=…` prefix every line carries. Internal so the
    /// hang-stack formatters (PerfHangStack.swift) build lines in the SAME grammar.
    static func head(_ ctx: PerfContext) -> String {
        "perf build=\(ctx.build) dev=\(ctx.installId)"
    }

    /// Keep values single-token + PII-free: no whitespace, no '@', no '\n', and no ';'
    /// (';' is the frame/image separator in the hang-stack lines — an un-stripped ';' in
    /// a binary name or symbol would otherwise split one token into two and corrupt the
    /// line grammar the server re-parses). Internal so PerfHangStack shares ONE sanitizer.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "@", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: ";", with: "_")
    }
}

/// Kit → app perf bridge. The App installs `report` at launch (pointing at its
/// PerfSink); kit code (e.g. CaptureManager hydration) reports a span through it
/// WITHOUT importing UIKit/MetricKit. Set once, read from any thread.
public enum PerfHook {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _report: (@Sendable (String, Int) -> Void)?

    public static func install(_ f: @escaping @Sendable (String, Int) -> Void) {
        lock.lock(); _report = f; lock.unlock()
    }
    /// Report a measured span (no-op until the app installs the bridge).
    public static func span(_ name: String, ms: Int) {
        lock.lock(); let f = _report; lock.unlock()
        f?(name, ms)
    }

    /// Time an async operation and report it as a span — on BOTH the success and
    /// the error path (a door timeout or a slow fetch is exactly what we need to
    /// see, and those surface as thrown errors). Failures report as `<name>-err`.
    @discardableResult
    public static func timed<T>(
        _ name: String,
        isolation: isolated (any Actor)? = #isolation,
        _ op: () async throws -> T
    ) async rethrows -> T {
        let span = PerfSpan(name: name)
        do {
            let r = try await op()
            PerfHook.span(name, ms: span.elapsedMs())
            return r
        } catch {
            PerfHook.span("\(name)-err", ms: span.elapsedMs())
            throw error
        }
    }
}

/// Thrown when a `withPerfTimeout` op outruns its budget — bounds a hang (e.g. a
/// wedged on-device model turn, a stale-port door round-trip) so it surfaces as a
/// clean, reportable error instead of an indefinite spinner. (A hard SIGTRAP in a
/// framework can't be caught by this — that's mitigated separately — but a HANG is.)
public struct PerfTimeout: Error, Sendable {
    public let name: String
    public let ms: Int
    public init(name: String, ms: Int) { self.name = name; self.ms = ms }
}

/// Race `op` against a deadline. Returns op's result if it finishes first; throws
/// `PerfTimeout` (and cancels op) if the deadline wins. Also reports a `<name>-timeout`
/// span so the timeout is visible in the perf stream.
public func withPerfTimeout<T: Sendable>(
    _ name: String, ms: Int,
    _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            PerfHook.span("\(name)-timeout", ms: ms)
            throw PerfTimeout(name: name, ms: ms)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw PerfTimeout(name: name, ms: ms)
        }
        return result
    }
}

/// A wall-clock span timer. Injectable monotonic clock so tests are deterministic;
/// production uses the monotonic system uptime (never wall-clock — immune to
/// clock changes).
public struct PerfSpan {
    public let name: String
    private let start: UInt64
    private let clock: () -> UInt64

    public init(name: String, clock: @escaping () -> UInt64 = PerfSpan.monotonicNanos) {
        self.name = name
        self.clock = clock
        self.start = clock()
    }

    public func elapsedMs() -> Int {
        Int((clock() &- start) / 1_000_000)
    }

    /// Monotonic nanoseconds (DispatchTime is a monotonic clock).
    public static func monotonicNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// Ships perf lines to the diagnostics endpoint, batched + best-effort, on its
/// own cadence — independent of the post-sign-in DoorLog, because launch/hang
/// telemetry must flow before sign-in and from a stable owner. Thread-safe.
public final class PerfSink: @unchecked Sendable {
    private let endpoint: URL?
    private let ctx: PerfContext
    private let lock = NSLock()
    private var pending: [String] = []
    private let session: URLSession

    public init(endpoint: URL?, ctx: PerfContext, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.ctx = ctx
        self.session = session
    }

    public var context: PerfContext { ctx }

    /// Record + ship a line. Slow spans and hangs flush immediately; everything
    /// else rides the next batch.
    public func emit(_ line: String, flush: Bool = false) {
        lock.lock(); pending.append(line); let batch = pending; if flush { pending = [] }
        lock.unlock()
        if flush { ship(batch) }
    }

    /// Ship whatever has accumulated (call on a timer + at background).
    public func flush() {
        lock.lock(); let batch = pending; pending = []; lock.unlock()
        guard !batch.isEmpty else { return }
        ship(batch)
    }

    private func ship(_ batch: [String]) {
        guard let endpoint, !batch.isEmpty else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = (batch.joined(separator: "\n") + "\n").data(using: .utf8)
        session.dataTask(with: req).resume()   // fire-and-forget, like DoorLog
    }

    // Convenience emitters (production call sites).
    public func span(_ name: String, ms: Int) {
        emit(PerfDiag.marker(name: name, ms: ms, ctx: ctx),
             flush: PerfDiag.isSlow(ms: ms))
    }
    public func hang(ms: Int, blamedFrame: String) {
        emit(PerfDiag.hang(ms: ms, blamedFrame: blamedFrame, ctx: ctx), flush: true)
    }
    public func launch(phase: String, ms: Int) {
        emit(PerfDiag.launch(phase: phase, ms: ms, ctx: ctx), flush: true)
    }
    public func metric(_ key: String, _ value: String) {
        emit(PerfDiag.metric(key, value, ctx: ctx))
    }
}
