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
    nonisolated(unsafe) private static var _emitLines: (@Sendable ([String]) -> Void)?

    public static func install(_ f: @escaping @Sendable (String, Int) -> Void) {
        lock.lock(); _report = f; lock.unlock()
    }
    /// Report a measured span (no-op until the app installs the bridge).
    public static func span(_ name: String, ms: Int) {
        lock.lock(); let f = _report; lock.unlock()
        f?(name, ms)
    }

    /// Install the pre-formatted-lines bridge. The App points this at its PerfSink (each
    /// line shipped flush:true) so kit code — e.g. the live stall-stack sampler — can ship
    /// multi-line `stallstack`/`stallimg` payloads WITHOUT importing UIKit/MetricKit or
    /// holding a sink. Content-free by construction: only frame tokens, never free text.
    public static func installLines(_ f: @escaping @Sendable ([String]) -> Void) {
        lock.lock(); _emitLines = f; lock.unlock()
    }
    /// Ship already-formatted perf lines (no-op until the app installs the bridge).
    public static func emitLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock(); let f = _emitLines; lock.unlock()
        f?(lines)
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

/// The single-resume guard shared between `withPerfTimeout`'s op task, its deadline task,
/// and the caller's continuation. The FIRST finisher resumes the caller exactly once; the
/// loser is cancelled (best-effort). A non-cooperative op that finishes AFTER the deadline
/// already unblocked the caller learns it LOST (`resume` → false) and emits an orphan span.
private final class PerfTimeoutGuard<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var opTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    func attach(op: Task<Void, Never>, deadline: Task<Void, Never>) {
        lock.lock(); opTask = op; deadlineTask = deadline; lock.unlock()
    }

    /// Resume the caller exactly once. Returns true iff THIS call won the race (resumed the
    /// continuation); false means another finisher already resumed it — the caller is the
    /// orphan (the op finishing after the deadline had unblocked the caller). Cancels the
    /// loser task best-effort; a non-cooperative op ignores that (hence the orphan span).
    func resume(_ result: sending Result<T, Error>, _ cont: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if resumed { lock.unlock(); return false }
        resumed = true
        let op = opTask, dl = deadlineTask
        lock.unlock()
        cont.resume(with: result)
        dl?.cancel(); op?.cancel()
        return true
    }
}

/// Race `op` against a deadline. Returns op's result if it finishes first; throws
/// `PerfTimeout` if the deadline wins. Also reports a `<name>-timeout` span so the timeout
/// is visible in the perf stream.
///
/// CRITICAL (2026-07-17, WS-B): the caller resumes AT the deadline even when `op` does NOT
/// cooperate with cancellation. The old implementation raced op-vs-deadline inside a
/// `withThrowingTaskGroup`, which cannot RETURN until every child completes — so a wedged,
/// non-cancellable `LanguageModelSession.respond` turn (FoundationModels) kept the caller
/// blocked until it actually finished (~86s measured; fm-title-timeout fired at ms=20000 but
/// fm-title-err landed at 86136/88706). Implicated in sustained CPU burn (that 86s stall ×
/// up to 12 SummaryBackfill calls). Now `op` runs in a DETACHED task and the caller is
/// resumed by whichever finisher wins via a single-resume guard; the wedged op is left to
/// finish on its own and, when it does, emits `<name>-orphan-done ms=` so the real wedge
/// duration stays visible in telemetry.
public func withPerfTimeout<T: Sendable>(
    _ name: String, ms: Int,
    _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    let guardState = PerfTimeoutGuard<T>()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        // The op, DETACHED so a non-cooperative op can never hold the caller past the
        // deadline. It measures its OWN span so an orphan (a turn that outran the deadline)
        // reports the true wedge duration when it finally completes.
        let opTask = Task.detached(priority: .userInitiated) {
            let span = PerfSpan(name: name)
            let outcome: Result<T, Error>
            do { outcome = .success(try await op()) } catch { outcome = .failure(error) }
            if !guardState.resume(outcome, cont) {
                // The deadline already unblocked the caller — this op is the orphan. Record
                // its real wedge duration so a non-cooperative hang stays measurable.
                PerfHook.span("\(name)-orphan-done", ms: span.elapsedMs())
            }
        }
        // The deadline. If it wins, resume the caller with PerfTimeout NOW (no waiting on the
        // wedged op) and emit the `-timeout` span. If the op already won, the sleep is
        // cancelled and this no-ops.
        let deadlineTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            if Task.isCancelled { return }
            if guardState.resume(.failure(PerfTimeout(name: name, ms: ms)), cont) {
                PerfHook.span("\(name)-timeout", ms: ms)
            }
        }
        guardState.attach(op: opTask, deadline: deadlineTask)
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

    /// THE FOURTH DIAGNOSTIC SENDER, and it went through the choke point last.
    ///
    /// This POSTs to the relay's `/diag/log` — the same endpoint `DoorLog`, `RemoteSession` and
    /// `DeletionRecorder` use, resolved from the same `RemoteConfig.fromBundle()` and wired in
    /// `App/FoundryXApp.swift`'s `init`. That `init` runs inside the app-hosted scenario bundle
    /// exactly as it runs on a handset, because the bundle is injected into the REAL
    /// application process — so when the other three were withheld under test and this one was
    /// not, `cmd errand.*` stopped arriving from the simulator suite and `perf …` carried on.
    /// Same instrument, same envelope, same install id: half a fix reads on the relay as a
    /// whole one.
    private func ship(_ batch: [String]) {
        guard let endpoint, !batch.isEmpty else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = (batch.joined(separator: "\n") + "\n").data(using: .utf8)
        FoundryXDiagShipping.send(req, using: session)   // fire-and-forget, like DoorLog
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
