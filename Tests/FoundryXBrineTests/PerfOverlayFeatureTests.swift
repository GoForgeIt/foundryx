import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Drives the whole `features/perf-telemetry.feature` — the original emission scenarios
/// AND the track-20260717T0600 T3 in-app performance-overlay scenarios — against the
/// REAL pure cores: `PerfDiag` (the shipped line formatters) and `PerfOverlayState` /
/// `DiagPrefs` (the gated overlay). Hermetic: no network, no clock, no UI. The overlay
/// steps prove the toggle gates rendering (default OFF, drop-when-off, live-on) while the
/// emission steps prove `PerfDiag` output is byte-identical regardless of the overlay —
/// the adversarial "emission is unaffected" claim, pinned as an executable scenario.
final class PerfOverlayFeatureTests: XCTestCase {

    func testPerfTelemetryAndOverlayFeature() async throws {
        let world = PerfWorld()
        try await BrineFeatureRunner.run("perf-telemetry",
                                         registry: StepRegistry(PerfSteps.make(world: world)))
    }

    // The observable @MainActor wrapper itself: gate is read per-line, OFF drops.
    @MainActor
    func testModelDropsWhenToggleOff() {
        let model = PerfOverlayModel(isEnabled: { false }, now: { Date() })
        model.record(label: "capture-hydrate", ms: 820)
        XCTAssertTrue(model.pills.isEmpty, "no pill accumulates while the toggle is off")
    }

    @MainActor
    func testModelShowsNewestFirstWhenOn() {
        let model = PerfOverlayModel(isEnabled: { true }, now: { Date() }, maxPills: 4, ttl: 4)
        model.record(label: "a", ms: 100)
        model.record(label: "b", ms: 200)
        XCTAssertEqual(model.pills.first?.text, "b 200 ms", "newest pill renders first")
        XCTAssertEqual(model.pills.count, 2)
    }

    @MainActor
    func testModelClearAllEmptiesTheScreen() {
        let model = PerfOverlayModel(isEnabled: { true }, now: { Date() })
        model.record(label: "a", ms: 100)
        model.clearAll()
        XCTAssertTrue(model.pills.isEmpty, "turning the toggle off clears the overlay at once")
    }

    // The pref honors an explicit choice; default is OFF (unset ≠ false-by-accident).
    func testDiagPrefDefaultsOff() {
        let d = UserDefaults(suiteName: "diag-\(UUID().uuidString)")!
        XCTAssertFalse(DiagPrefs.perfOverlayEnabled(defaults: d), "default OFF")
        DiagPrefs.setPerfOverlayEnabled(true, defaults: d)
        XCTAssertTrue(DiagPrefs.perfOverlayEnabled(defaults: d))
        DiagPrefs.setPerfOverlayEnabled(false, defaults: d)
        XCTAssertFalse(DiagPrefs.perfOverlayEnabled(defaults: d))
    }

    // Review P3-1: the DEBUG demo seam lights the overlay via an in-memory session
    // override — recording flows while the PERSISTED pref stays untouched (OFF).
    @MainActor
    func testSessionOverrideEnablesWithoutTouchingThePref() {
        final class Reads: @unchecked Sendable { var n = 0 }
        let reads = Reads()
        let model = PerfOverlayModel(isEnabled: { reads.n += 1; return false })
        model.record(label: "dropped", ms: 100)
        XCTAssertTrue(model.pills.isEmpty, "pref OFF, no override: dropped")
        XCTAssertEqual(reads.n, 1)

        model.sessionOverrideEnabled = true
        model.record(label: "shown", ms: 200)
        XCTAssertEqual(model.pills.map(\.text), ["shown 200 ms"], "override shows without the pref")
        XCTAssertEqual(reads.n, 1, "override never consults (or writes) the pref")

        model.sessionOverrideEnabled = nil
        model.record(label: "dropped-again", ms: 300)
        XCTAssertEqual(model.pills.count, 1, "back to deferring to the (OFF) pref")
    }

    // The model-level sweep (what the view's 1s tick calls) drops pills past their TTL,
    // pinned with an injected clock so no real time passes.
    @MainActor
    func testModelExpireNowDropsPillsPastTTLByInjectedClock() {
        final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let model = PerfOverlayModel(isEnabled: { true }, now: { clock.date }, ttl: 4)
        model.record(label: "span", ms: 100)
        XCTAssertEqual(model.pills.count, 1)

        clock.date = Date(timeIntervalSince1970: 3)
        model.expireNow()
        XCTAssertEqual(model.pills.count, 1, "inside TTL: stays")

        clock.date = Date(timeIntervalSince1970: 5)
        model.expireNow()
        XCTAssertTrue(model.pills.isEmpty, "past TTL: swept")
    }
}

/// Shared, mutable scenario state (@unchecked Sendable — the Brine steps run serially).
private final class PerfWorld: @unchecked Sendable {
    // Emission side.
    let installId = "a1b2c3d4"
    var spanName = ""
    var spanMs = 0
    var line = ""
    var slowThreshold = PerfDiag.slowThreshold

    // Overlay side.
    let defaults = UserDefaults(suiteName: "perf-overlay-\(UUID().uuidString)")!
    var overlay = PerfOverlayState(maxPills: 4, ttl: 4)
    var clock = Date(timeIntervalSince1970: 1_000_000)

    // Model wedge breaker side (WS-C) — an injected monotonic clock so the cool-down elapses
    // deterministically with no real time passing.
    var breakerClock: TimeInterval = 0
    var breaker: ModelWedgeBreaker!
    static let breakerCooldown: TimeInterval = 600

    func resetBreaker() {
        breakerClock = 0
        breaker = ModelWedgeBreaker(cooldownSeconds: PerfWorld.breakerCooldown,
                                    refusalThrottleSeconds: 60,
                                    clock: { [weak self] in self?.breakerClock ?? 0 })
    }

    // Live stall side (WS-A).
    var stallFrames: [PerfStackFrame] = []
    var stackLines: [String] = []
    var stallThresholdMs = 250
    private let emitLock = NSLock()
    private var _stallEmits: [Int] = []
    func appendStallEmit(_ ms: Int) { emitLock.lock(); _stallEmits.append(ms); emitLock.unlock() }
    var stallEmits: [Int] { emitLock.lock(); defer { emitLock.unlock() }; return _stallEmits }
    // Budget side (injected clock).
    var budget: StallReportBudget?
    var budgetNanos: UInt64 = 0
    var budgetCap = 0
    var admitCount = 0

    var perfCtx: PerfContext { PerfContext(build: "166", installId: installId) }

    /// Record a span into the overlay honoring the CURRENT pref — exactly what the app's
    /// read-only tap does (drop unless the toggle is on).
    func recordOverlay(label: String, ms: Int) {
        overlay.record(label: label, ms: ms,
                       enabled: DiagPrefs.perfOverlayEnabled(defaults: defaults),
                       now: clock)
    }

    func resetOverlay() { overlay = PerfOverlayState(maxPills: 4, ttl: 4) }
}

private enum PerfSteps {
    static func make(world w: PerfWorld) -> [StepDefinition] {
        [
            // MARK: emission scenarios (the shipped line formatters — unchanged)
            defineStep("a perf span named {string} that took {int} milliseconds") { ctx, p, _ in
                w.spanName = try p.requireString(0); w.spanMs = try p.requireInt(1); return ctx
            },
            defineStep("it is reported for build {string}") { ctx, p, _ in
                let build = try p.requireString(0)
                w.line = PerfDiag.marker(name: w.spanName, ms: w.spanMs,
                                         ctx: PerfContext(build: build, installId: w.installId))
                return ctx
            },
            defineCheck("the line reads as a perf marker naming the span, its duration, and the build") { _, _, _ in
                guard w.line.contains("span=\(w.spanName)"), w.line.contains("ms=\(w.spanMs)"),
                      w.line.contains("build=166") else {
                    throw BrineStepError("not a well-formed perf marker: \(w.line)")
                }
            },
            defineStep("a system hang diagnostic lasting {int} milliseconds at a known call site") { ctx, p, _ in
                w.spanMs = try p.requireInt(0)
                w.line = PerfDiag.hang(ms: w.spanMs, blamedFrame: "CaptureWAL.computeStatus", ctx: w.perfCtx)
                return ctx
            },
            defineStep("a system launch metric with a time-to-first-draw of {int} milliseconds") { ctx, p, _ in
                w.spanMs = try p.requireInt(0)
                w.line = PerfDiag.launch(phase: "first-draw", ms: w.spanMs, ctx: w.perfCtx)
                return ctx
            },
            defineStep("it is formatted for shipping") { ctx, _, _ in ctx },  // line built in Given
            defineCheck("the line names it a hang, carries the duration, and names the blamed frame") { _, _, _ in
                guard w.line.contains("hang"), w.line.contains("ms=\(w.spanMs)"),
                      w.line.contains("at=CaptureWAL.computeStatus") else {
                    throw BrineStepError("not a well-formed hang line: \(w.line)")
                }
            },
            defineCheck("the line names the launch phase and its duration") { _, _, _ in
                guard w.line.contains("launch"), w.line.contains("phase=first-draw"),
                      w.line.contains("ms=\(w.spanMs)") else {
                    throw BrineStepError("not a well-formed launch line: \(w.line)")
                }
            },
            defineStep("any perf line") { ctx, _, _ in
                w.line = PerfDiag.marker(name: "x", ms: 1, ctx: w.perfCtx); return ctx
            },
            defineCheck("it carries the app build and a stable anonymous install id") { _, _, _ in
                guard w.line.contains("build=166"), w.line.contains("dev=\(w.installId)") else {
                    throw BrineStepError("missing build/install id: \(w.line)")
                }
            },
            defineCheck("it never carries personal data") { _, _, _ in
                guard !w.line.contains("@"), !w.line.localizedCaseInsensitiveContains("token") else {
                    throw BrineStepError("perf line carried PII markers: \(w.line)")
                }
            },
            defineStep("the slow threshold is {int} milliseconds") { ctx, p, _ in
                w.slowThreshold = try p.requireInt(0); return ctx
            },
            defineCheck("a {int} millisecond span is marked slow") { _, p, _ in
                let ms = try p.requireInt(0)
                guard PerfDiag.marker(name: "x", ms: ms, ctx: w.perfCtx,
                                      slowThreshold: w.slowThreshold).contains("SLOW") else {
                    throw BrineStepError("\(ms)ms span was not marked slow")
                }
            },
            defineCheck("a {int} millisecond span is not marked slow") { _, p, _ in
                let ms = try p.requireInt(0)
                guard !PerfDiag.marker(name: "x", ms: ms, ctx: w.perfCtx,
                                       slowThreshold: w.slowThreshold).contains("SLOW") else {
                    throw BrineStepError("\(ms)ms span was wrongly marked slow")
                }
            },

            // MARK: overlay scenarios (track T3 — the gated in-app render)
            defineStep("a fresh install with no diagnostics preference") { ctx, _, _ in
                w.resetOverlay()
                w.defaults.removeObject(forKey: DiagPrefs.perfOverlayKey)
                return ctx
            },
            defineCheck("the performance overlay is off") { _, _, _ in
                guard DiagPrefs.perfOverlayEnabled(defaults: w.defaults) == false else {
                    throw BrineStepError("overlay was on by default")
                }
            },
            defineCheck("recording a perf span shows no pills") { _, _, _ in
                w.recordOverlay(label: "capture-hydrate", ms: 820)
                guard w.overlay.display.isEmpty else {
                    throw BrineStepError("a pill appeared while the overlay was off")
                }
            },
            defineStep("the performance overlay is turned on") { ctx, _, _ in
                w.resetOverlay()
                DiagPrefs.setPerfOverlayEnabled(true, defaults: w.defaults)
                return ctx
            },
            defineStep("the performance overlay is turned off") { ctx, _, _ in
                DiagPrefs.setPerfOverlayEnabled(false, defaults: w.defaults)
                w.overlay.clear()   // the toggle flipping OFF clears the screen at once
                return ctx
            },
            defineStep("a perf span named {string} of {int} milliseconds is recorded") { ctx, p, _ in
                w.recordOverlay(label: try p.requireString(0), ms: try p.requireInt(1)); return ctx
            },
            defineStep("a perf span of {int} milliseconds has been recorded") { ctx, p, _ in
                w.recordOverlay(label: "span", ms: try p.requireInt(0)); return ctx
            },
            defineCheck("the overlay shows a pill reading {string}") { _, p, _ in
                let want = try p.requireString(0)
                guard w.overlay.display.first?.text == want else {
                    throw BrineStepError("front pill was \(w.overlay.display.first?.text ?? "nil"), wanted \(want)")
                }
            },
            defineCheck("a newly recorded perf span shows no pills") { _, _, _ in
                w.recordOverlay(label: "post-off", ms: 900)
                guard w.overlay.display.isEmpty else {
                    throw BrineStepError("a pill appeared after the overlay was turned off")
                }
            },
            defineStep("several seconds pass") { ctx, _, _ in
                w.clock = w.clock.addingTimeInterval(w.overlay.ttl + 1)
                w.overlay.expire(now: w.clock)
                return ctx
            },
            defineCheck("the overlay shows no pills") { _, _, _ in
                guard w.overlay.display.isEmpty else {
                    throw BrineStepError("pills lingered past their lifetime: \(w.overlay.display.map(\.text))")
                }
            },
            defineStep("six perf spans are recorded") { ctx, _, _ in
                for i in 1...6 { w.recordOverlay(label: "s\(i)", ms: i * 100) }
                return ctx
            },
            defineCheck("the overlay shows only the newest four") { _, _, _ in
                guard w.overlay.display.count == 4 else {
                    throw BrineStepError("expected 4 pills, got \(w.overlay.display.count)")
                }
                // The three oldest (s1,s2) fell off; s3…s6 remain.
                guard w.overlay.display.map(\.text) == ["s6 600 ms", "s5 500 ms", "s4 400 ms", "s3 300 ms"] else {
                    throw BrineStepError("wrong window: \(w.overlay.display.map(\.text))")
                }
            },
            defineCheck("the newest pill is first") { _, _, _ in
                guard w.overlay.display.first?.text == "s6 600 ms" else {
                    throw BrineStepError("newest pill was not first: \(w.overlay.display.first?.text ?? "nil")")
                }
            },
            defineCheck("the shipped perf line is byte-identical with the overlay off and on") { _, _, _ in
                let off = PerfDiag.marker(name: w.spanName, ms: w.spanMs, ctx: w.perfCtx)
                // Recording the same span into the overlay must not perturb the formatter.
                var state = PerfOverlayState()
                _ = state.record(label: w.spanName, ms: w.spanMs, enabled: true, now: Date())
                let on = PerfDiag.marker(name: w.spanName, ms: w.spanMs, ctx: w.perfCtx)
                guard off == on else {
                    throw BrineStepError("overlay changed the shipped line:\n off=\(off)\n  on=\(on)")
                }
            },

            // MARK: on-device model wedge breaker (WS-C — the pure ModelWedgeBreaker)
            defineStep("a healthy on-device model breaker") { ctx, _, _ in
                w.resetBreaker(); return ctx
            },
            defineStep("a wedged on-device model breaker") { ctx, _, _ in
                w.resetBreaker(); w.breaker.tripWedge(); return ctx   // OPEN from clock 0
            },
            defineStep("the on-device model wedges") { ctx, _, _ in
                w.breaker.tripWedge(); return ctx
            },
            defineStep("the cool-down elapses") { ctx, _, _ in
                w.breakerClock += PerfWorld.breakerCooldown + 1   // step just past the cool-down edge
                return ctx
            },
            defineStep("the on-device probe wedges again") { ctx, _, _ in
                guard w.breaker.admit() == .probe else {
                    throw BrineStepError("expected the single half-open probe, got a non-probe admission")
                }
                w.breaker.tripWedge()   // the probe wedged too → re-open
                return ctx
            },
            defineStep("the probe turn succeeds") { ctx, _, _ in
                w.breaker.recordSuccess(); return ctx
            },
            defineCheck("the next on-device turn is refused for the cool-down") { _, _, _ in
                guard case .refused(let ms, _) = w.breaker.admit(), ms > 0 else {
                    throw BrineStepError("expected a refusal with a live cool-down, got a proceed/probe")
                }
            },
            defineCheck("exactly one on-device probe is allowed") { _, _, _ in
                guard w.breaker.admit() == .probe else {
                    throw BrineStepError("cool-down elapsed but no probe was allowed")
                }
            },
            defineCheck("a second on-device turn is still refused") { _, _, _ in
                guard case .refused(let ms, _) = w.breaker.admit(), ms == 0 else {
                    throw BrineStepError("a second concurrent turn was not refused while the probe is in flight")
                }
            },
            defineCheck("on-device turns proceed normally") { _, _, _ in
                guard w.breaker.admit() == .proceed else {
                    throw BrineStepError("expected the breaker CLOSED (turns proceed), it refused")
                }
            },

            // MARK: live main-thread stall reporting (WS-A — the real pure types)
            defineStep("the main thread is blocked at a known call site for {int} milliseconds") { ctx, p, _ in
                w.spanMs = try p.requireInt(0)
                // A known-site frame, exactly the shape the sampler produces on-device.
                w.stallFrames = [
                    PerfStackFrame(binaryName: "FoundryX",
                                   binaryUUID: "AABBCCDD-1122-3344-5566-77889900AABB",
                                   offset: 0x1df, symbol: "CaptureManager.rebuild"),
                    PerfStackFrame(binaryName: "libsystem_kernel.dylib",
                                   binaryUUID: "11111111-2222-3333-4444-555555555555",
                                   offset: 0x10, symbol: nil),
                ]
                return ctx
            },
            defineStep("the stall is captured and formatted for shipping") { ctx, _, _ in
                w.stackLines = PerfDiag.hangStackLines(ms: w.spanMs, frames: w.stallFrames,
                                                       truncated: false, ctx: w.perfCtx, kind: "stallstack")
                return ctx
            },
            defineCheck("the line names it a stall stack, carries the duration, and names the blocked frame") { _, _, _ in
                guard w.stackLines.contains(where: { $0.contains(" stallstack ms=\(w.spanMs) ") }),
                      w.stackLines.contains(where: { $0.contains(" stallimg ms=\(w.spanMs) ") }),
                      w.stackLines.contains(where: { $0.contains("FoundryX@aabbccdd+0x1df:CaptureManager.rebuild") })
                else { throw BrineStepError("not a well-formed stall stack: \(w.stackLines)") }
            },
            defineStep("a runaway CPU exception of {int} milliseconds with a full call tree") { ctx, p, _ in
                w.spanMs = try p.requireInt(0)
                w.stallFrames = [
                    PerfStackFrame(binaryName: "FoundryX", binaryUUID: "AABBCCDD-1122-3344-5566-77889900AABB",
                                   offset: 0x100, symbol: "SummaryBackfill.run"),
                    PerfStackFrame(binaryName: "FoundryX", binaryUUID: "AABBCCDD-1122-3344-5566-77889900AABB",
                                   offset: 0x200, symbol: "FoundationModelsTitler.title"),
                    PerfStackFrame(binaryName: "libswift_Concurrency.dylib",
                                   binaryUUID: "22222222-3333-4444-5555-666666666666",
                                   offset: 0x40, symbol: nil),
                ]
                w.stackLines = PerfDiag.hangStackLines(ms: w.spanMs, frames: w.stallFrames,
                                                       truncated: false, ctx: w.perfCtx, kind: "cpustack")
                return ctx
            },
            defineCheck("the line names it a CPU stack and carries every frame with an image table") { _, _, _ in
                guard let stackLine = w.stackLines.first(where: { $0.contains(" cpustack ms=\(w.spanMs) ") }),
                      w.stackLines.contains(where: { $0.contains(" cpuimg ms=\(w.spanMs) ") }) else {
                    throw BrineStepError("not a well-formed cpu stack: \(w.stackLines)")
                }
                let fr = stackLine.range(of: "fr=").map { String(stackLine[$0.upperBound...]) } ?? ""
                guard fr.split(separator: ";").count >= 3 else {
                    throw BrineStepError("cpu stack did not carry the full tree: \(fr)")
                }
            },
            defineStep("the stall threshold is {int} milliseconds") { ctx, p, _ in
                w.stallThresholdMs = try p.requireInt(0); return ctx
            },
            defineStep("the main thread pauses for {int} milliseconds") { ctx, p, _ in
                let pauseMs = try p.requireInt(0)
                // Drive the REAL watchdog against an injected serial queue wedged for pauseMs;
                // a pause under the threshold must not emit a nav-stall.
                let target = DispatchQueue(label: "brine.stall-\(UUID().uuidString)")
                let dog = MainThreadStallWatchdog(thresholdMs: w.stallThresholdMs, pingInterval: 0.03,
                                                  target: target,
                                                  emit: { ms in w.appendStallEmit(ms) })
                dog.start()
                let pauseSecs = Double(pauseMs) / 1000.0
                target.async { usleep(useconds_t(pauseSecs * 1_000_000)) }
                // Wait out the pause plus a settle margin so any (unwanted) emit would land.
                usleep(useconds_t((pauseSecs + 0.3) * 1_000_000))
                dog.stop()
                return ctx
            },
            defineCheck("no stall is reported") { _, _, _ in
                guard w.stallEmits.isEmpty else {
                    throw BrineStepError("a sub-threshold pause was wrongly reported: \(w.stallEmits)")
                }
            },
            defineStep("a stall report budget of at most 1 report every {int} seconds and {int} per session") { ctx, p, _ in
                let interval = TimeInterval(try p.requireInt(0))
                w.budgetCap = try p.requireInt(1)
                w.budgetNanos = 0
                w.admitCount = 0
                w.budget = StallReportBudget(minInterval: interval, maxPerSession: w.budgetCap,
                                             clock: { w.budgetNanos })
                return ctx
            },
            defineStep("{int} stalls happen within the same second") { ctx, p, _ in
                let n = try p.requireInt(0)
                for _ in 0..<n { if w.budget?.admit() == true { w.admitCount += 1 } }  // clock frozen
                return ctx
            },
            defineCheck("only {int} stall is reported") { _, p, _ in
                let want = try p.requireInt(0)
                guard w.admitCount == want else {
                    throw BrineStepError("expected \(want) report(s), got \(w.admitCount)")
                }
            },
            defineCheck("after the session cap is reached further stalls are dropped") { _, _, _ in
                guard let budget = w.budget else { throw BrineStepError("no budget") }
                // Space admits past the interval until the session cap is reached.
                var guardCount = 0
                while budget.consumed < w.budgetCap && guardCount < w.budgetCap * 4 {
                    w.budgetNanos &+= 10_000_000_000   // +10s clears any spacing
                    _ = budget.admit()
                    guardCount += 1
                }
                w.budgetNanos &+= 10_000_000_000
                guard budget.admit() == false else {
                    throw BrineStepError("a report was admitted past the session cap of \(w.budgetCap)")
                }
            },
        ]
    }
}
