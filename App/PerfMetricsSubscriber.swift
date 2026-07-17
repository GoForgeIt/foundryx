// PerfMetricsSubscriber — adopts MetricKit so the SYSTEM's on-device
// performance diagnostics reach our diagnostics endpoint for EVERY user, not
// just when someone forwards an Apple .ips report (features/perf-telemetry.feature).
//
// MetricKit (iOS 13+/14+) hands the app, on a daily cadence, aggregated metrics
// (launch time, app responsiveness/hang time, CPU, memory, disk) AND — the
// crown jewel — hang / CPU-exception / disk-write diagnostics WITH CALL STACKS.
// We format each into a compact `perf …` line (PerfDiag) and ship it via
// PerfSink to `/diag/log`, tagged with build + anonymous install id, so a
// regression is greppable/aggregatable per build across the fleet.
//
// PerfTelemetry.shared owns the sink + subscriber for the app's lifetime,
// initialized once at launch (before sign-in) so launch/hang telemetry flows
// even on the sign-in screen.

import Foundation
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#endif
// FoundryXKit types are same-module (the App target compiles Sources/FoundryXKit).

/// App-lifetime owner of performance telemetry. `start()` once at launch.
final class PerfTelemetry: NSObject, @unchecked Sendable {
    static let shared = PerfTelemetry()

    private(set) var sink: PerfSink?
    /// The content-free PRODUCT-USAGE sink — a sibling of `sink`, shipping to the
    /// door's `telemetry/usage` endpoint (usage-telemetry.feature). Independent wire.
    private(set) var usageSink: UsageSink?
    private var launchSpan: PerfSpan?
    private var flushTimer: Timer?

    /// Cold-launch marker start — set as early as possible (app init).
    func markProcessStart() {
        if launchSpan == nil { launchSpan = PerfSpan(name: "cold-launch") }
    }

    /// Wire the perf sink to the diagnostics endpoint and subscribe to MetricKit; the
    /// SIBLING usage sink is constructed here too but points at the bearer-gated FOUNDRY
    /// DOOR (`POST /foundryx/telemetry/usage`, capture base) — its `DoorTarget` is set
    /// later via `setUsageTarget` once sign-in resolves it. Idempotent. The `perfEndpoint`
    /// resolves from the same RemoteConfig the DoorLog uses.
    func start(endpoint perfEndpoint: URL?) {
        guard sink == nil else { return }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let installId = Self.anonymousInstallId()
        let ctx = PerfContext(build: build, installId: installId)
        let sink = PerfSink(endpoint: perfEndpoint, ctx: ctx)
        self.sink = sink

        // The usage sink is a SIBLING: same build + anonymous install id, but the FOUNDRY
        // DOOR (bearer-gated capture base) and a content-free JSON wire. Content-free by
        // construction (UsageHook's typed emitters + UsageDiag.token never let free text
        // out). No target until sign-in — set via setUsageTarget.
        let usageSink = UsageSink(ctx: UsageContext(build: build, installId: installId))
        self.usageSink = usageSink

        // A low-rate backstop flush so batched (non-slow) spans + usage events trickle out.
        let t = Timer(timeInterval: 20, repeats: true) { _ in sink.flush(); usageSink.flush() }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
        // Flush on background so nothing is stranded when the app is suspended.
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif

        // Let kit code (CaptureManager hydration, drain) report spans through us
        // without importing MetricKit/UIKit.
        //
        // The `sink?.span(...)` call is the emission path and is UNCHANGED (byte-for-byte
        // the same span shipped to /diag/log). AFTER it, the same span is forwarded
        // READ-ONLY to the opt-in in-app overlay (track 20260717T0600 T3). The overlay
        // gate lives in the model (dropped unless the Settings toggle is on) and it never
        // touches the sink — emission is completely independent of the toggle.
        PerfHook.install { [weak sink] name, ms in
            sink?.span(name, ms: ms)
            Self.forwardToOverlay(label: name, ms: ms)
        }
        // …and let kit code (CaptureManager, ChatViewModel, AmbientLane, …) report
        // content-free usage events through the SAME kind of bridge.
        UsageHook.install { [weak usageSink] kind, cats, nums in
            usageSink?.emit(kind, cats: cats, nums: nums)
        }

        #if DEBUG
        // Screen-proof seam (`-PerfOverlayDemo`): turn the overlay on and inject a few
        // demo pills so the gated overlay can be screenshot in the simulator without a
        // real hang. DEBUG-only, opt-in by launch arg — never in a shipped build.
        Self.installOverlayDemoIfRequested()
        #endif

        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

    /// Point the usage sink at the resolved door (post sign-in) so content-free product
    /// usage reaches `POST /foundryx/telemetry/usage`. Re-callable when the bearer refreshes.
    func setUsageTarget(_ target: DoorTarget?) { usageSink?.setTarget(target) }

    /// Report time-to-first-draw once the first real UI is on screen.
    func markFirstDraw() {
        guard let span = launchSpan, let sink else { return }
        sink.launch(phase: "first-draw", ms: span.elapsedMs())
        launchSpan = nil   // once
    }

    /// A one-shot span helper for hot paths (`PerfTelemetry.shared.time("hydrate") { … }`).
    @discardableResult
    func time<T>(_ name: String, _ work: () -> T) -> T {
        let span = PerfSpan(name: name)
        let r = work()
        sink?.span(name, ms: span.elapsedMs())
        return r
    }

    /// Record an already-measured span (for async work timed by the caller).
    func record(_ name: String, ms: Int) { sink?.span(name, ms: ms) }

    @objc private func onBackground() { sink?.flush(); usageSink?.flush() }

    /// Forward an already-shipped span/hang to the in-app overlay READ-ONLY (track
    /// 20260717T0600 T3). Hops to the main actor (the model is @MainActor); the model
    /// drops the line unless the Settings toggle is on. This has NO effect on the sink —
    /// telemetry emission is byte-identical whether or not this runs.
    static func forwardToOverlay(label: String, ms: Int) {
        Task { @MainActor in PerfOverlayModel.shared.record(label: label, ms: ms) }
    }

    #if DEBUG
    /// `-PerfOverlayDemo`: DEBUG-only screenshot seam. Lights the overlay for THIS
    /// SESSION ONLY (in-memory override — the persisted Settings pref is untouched,
    /// review P3-1) and keeps a few demo pills present (re-injected on a cadence so
    /// they outlive their TTL for a screenshot). Never compiled into Release/TestFlight.
    static func installOverlayDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-PerfOverlayDemo") else { return }
        Task { @MainActor in PerfOverlayModel.shared.sessionOverrideEnabled = true }
        let demo: [(String, Int)] = [
            ("capture-hydrate", 820), ("lore-drain", 1240), ("cold-launch", 1820),
        ]
        Task { @MainActor in
            while !Task.isCancelled {
                for (name, ms) in demo { PerfOverlayModel.shared.record(label: name, ms: ms) }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
    }
    #endif

    /// A stable per-install anonymous id (identifierForVendor's first 8 hex).
    /// Not PII: rotates on full uninstall, never identifies the person.
    private static func anonymousInstallId() -> String {
        #if canImport(UIKit)
        let raw = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-0000"
        #else
        let raw = "sim-00000000"
        #endif
        return String(raw.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

#if canImport(MetricKit)
extension PerfTelemetry: MXMetricManagerSubscriber {

    /// Daily aggregate metrics: launch time, responsiveness (hang time), CPU,
    /// memory, disk. We ship the headline numbers as `metric …` lines.
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let sink else { return }
        for p in payloads {
            if let launch = p.applicationLaunchMetrics {
                let ttl = launch.histogrammedTimeToFirstDraw.averageMs()
                if ttl > 0 { sink.launch(phase: "ttfd-avg", ms: ttl) }
                let resume = launch.histogrammedApplicationResumeTime.averageMs()
                if resume > 0 { sink.launch(phase: "resume-avg", ms: resume) }
            }
            if let resp = p.applicationResponsivenessMetrics {
                let hang = resp.histogrammedApplicationHangTime.averageMs()
                if hang > 0 { sink.metric("hang-time-avg-ms", "\(hang)") }
            }
            if let mem = p.memoryMetrics {
                sink.metric("peak-mem-mb",
                            "\(Int(mem.peakMemoryUsage.converted(to: .megabytes).value))")
            }
            if let disk = p.diskIOMetrics {
                sink.metric("disk-writes-mb",
                            "\(Int(disk.cumulativeLogicalWrites.converted(to: .megabytes).value))")
            }
        }
    }

    /// Diagnostics WITH CALL STACKS — the signal that would have caught our
    /// getxattr hangs across the fleet. Hangs, CPU exceptions, disk-write
    /// exceptions: we ship a hang line naming the first FoundryX frame.
    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let sink else { return }
        for p in payloads {
            for hang in p.hangDiagnostics ?? [] {
                let ms = Int(hang.hangDuration.converted(to: .milliseconds).value)
                // Keep the existing single-frame blame line EXACTLY (dashboards grep it).
                sink.hang(ms: ms, blamedFrame: Self.blamedFrame(hang.callStackTree))
                // Read-only overlay forward (unchanged emission above; see start()).
                Self.forwardToOverlay(label: "hang", ms: ms)
                // THEN ship the FULL call tree (track 20260717T0448): every frame as
                // binary@uuid8+0xoffset + a full-UUID image table, size-capped, so both
                // the recurring 650ms hang and the 48s hang become atos-able off-line.
                // Serialized through the pure kit core (no MetricKit types leak into it).
                let parse = PerfHangStack.parse(fromTreeJSON: hang.callStackTree.jsonRepresentation())
                for line in PerfDiag.hangStackLines(ms: ms, frames: parse.frames,
                                                    truncated: parse.truncated, ctx: sink.context) {
                    sink.emit(line, flush: true)
                }
            }
            for cpu in p.cpuExceptionDiagnostics ?? [] {
                sink.hang(ms: Int(cpu.totalCPUTime.converted(to: .milliseconds).value),
                          blamedFrame: "cpu:" + Self.blamedFrame(cpu.callStackTree))
            }
            for dw in p.diskWriteExceptionDiagnostics ?? [] {
                sink.hang(ms: Int(dw.totalWritesCaused.converted(to: .megabytes).value),
                          blamedFrame: "diskwrite:" + Self.blamedFrame(dw.callStackTree))
            }
        }
    }

    /// Walk the MetricKit call-stack-tree JSON to the first frame in our own
    /// binary — the actionable blame — via the shared PerfDiag.firstOwnFrame.
    private static func blamedFrame(_ tree: MXCallStackTree) -> String {
        guard let obj = try? JSONSerialization.jsonObject(
                with: tree.jsonRepresentation()) as? [String: Any],
              let stacks = obj["callStacks"] as? [[String: Any]] else { return "unknown" }
        var flat: [String] = []
        func walk(_ frame: [String: Any]) {
            let bin = frame["binaryName"] as? String ?? "?"
            let sym = frame["symbolName"] as? String ?? Self.slidBlame(frame)
            flat.append("0 \(bin) \(sym)")
            for sub in (frame["subFrames"] as? [[String: Any]]) ?? [] { walk(sub) }
        }
        for stack in stacks {
            for root in (stack["callStackRootFrames"] as? [[String: Any]]) ?? [] { walk(root) }
        }
        return PerfDiag.firstOwnFrame(in: flat, own: "FoundryX")
    }

    /// The blame token for an UN-symbolicated frame. A raw slid `address` is useless
    /// off-device (it depends on ASLR), but MetricKit also gives us the STABLE
    /// `offsetIntoBinaryTextSegment` + the frame's `binaryUUID` — from which we can
    /// symbolicate later with the matching dSYM. Emit `at=<first8ofUUID>+0x<offset>`
    /// when both are present; fall back to the raw address only when they're missing.
    private static func slidBlame(_ frame: [String: Any]) -> String {
        if let offset = frame["offsetIntoBinaryTextSegment"] as? Int,
           let uuid = frame["binaryUUID"] as? String, !uuid.isEmpty {
            let short = uuid.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            return "\(short)+0x\(String(offset, radix: 16))"
        }
        if let address = frame["address"] as? Int { return "0x\(String(address, radix: 16))" }
        return "?"
    }
}

/// Average of a MetricKit histogram in milliseconds (bucket-count weighted),
/// 0 when empty.
private extension MXHistogram where UnitType == UnitDuration {
    func averageMs() -> Int {
        var total = 0.0, n = 0.0
        let e = bucketEnumerator
        while let b = e.nextObject() as? MXHistogramBucket<UnitDuration> {
            let mid = (b.bucketStart.converted(to: .milliseconds).value
                       + b.bucketEnd.converted(to: .milliseconds).value) / 2
            total += mid * Double(b.bucketCount); n += Double(b.bucketCount)
        }
        return n > 0 ? Int(total / n) : 0
    }
}
#endif
