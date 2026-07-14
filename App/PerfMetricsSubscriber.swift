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
    private var launchSpan: PerfSpan?
    private var flushTimer: Timer?

    /// Cold-launch marker start — set as early as possible (app init).
    func markProcessStart() {
        if launchSpan == nil { launchSpan = PerfSpan(name: "cold-launch") }
    }

    /// Wire the sink to the diagnostics endpoint and subscribe to MetricKit.
    /// Idempotent. Endpoint resolves from the same RemoteConfig the DoorLog uses.
    func start(endpoint: URL?) {
        guard sink == nil else { return }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let installId = Self.anonymousInstallId()
        let ctx = PerfContext(build: build, installId: installId)
        let sink = PerfSink(endpoint: endpoint, ctx: ctx)
        self.sink = sink

        // A low-rate backstop flush so batched (non-slow) spans still trickle out.
        let t = Timer(timeInterval: 20, repeats: true) { _ in sink.flush() }
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
        PerfHook.install { [weak sink] name, ms in sink?.span(name, ms: ms) }

        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

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

    @objc private func onBackground() { sink?.flush() }

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
                sink.hang(ms: ms, blamedFrame: Self.blamedFrame(hang.callStackTree))
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
            let sym = frame["symbolName"] as? String
                ?? (frame["address"] as? Int).map { "0x\(String($0, radix: 16))" } ?? "?"
            flat.append("0 \(bin) \(sym)")
            for sub in (frame["subFrames"] as? [[String: Any]]) ?? [] { walk(sub) }
        }
        for stack in stacks {
            for root in (stack["callStackRootFrames"] as? [[String: Any]]) ?? [] { walk(root) }
        }
        return PerfDiag.firstOwnFrame(in: flat, own: "FoundryX")
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
