import SwiftUI

@main
struct FoundryXApp: App {
    /// CB state-restoration bootstrap: when iOS relaunches us in the background
    /// because the Omi's pending connect completed, the delegate re-adopts the BLE
    /// link + spools audio BEFORE any UI exists (see FoundryXAppDelegate).
    @UIApplicationDelegateAdaptor(FoundryXAppDelegate.self) private var appDelegate

    #if DEBUG
    /// Cold-launch reference instant (≈ process start; App.init runs alongside
    /// PerfTelemetry.markProcessStart). Used ONLY to mirror the first-draw span to the
    /// `-PerfLog` console so the sim-perf harness can read a `perf-span first-draw ms=N`
    /// line — the shipping first-draw span goes to the relay sink, which the simulator
    /// has no endpoint for. DEBUG-only, opt-in by launch arg; never in a Release build.
    static let launchStart = DispatchTime.now()
    #endif

    init() {
        #if DEBUG
        _ = Self.launchStart   // force the reference instant at init (≈ process start)
        #endif
        // Start the cold-launch clock as early as possible, and wire perf
        // telemetry (MetricKit + our own spans) to the diagnostics endpoint so
        // launch/hang data flows across the fleet, not one .ips at a time.
        PerfTelemetry.shared.markProcessStart()
        PerfTelemetry.shared.start(
            endpoint: RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        // The content-free product-usage sink is wired to the Foundry DOOR (bearer-gated)
        // once sign-in resolves the target — see RootView's setUsageTarget call. It is
        // delivered THROUGH Foundry (the door appends it to the local telemetry rollup).
        #if DEBUG || PERF_HARNESS
        DemoSeed.installPerfLogIfRequested()  // `-PerfLog`: mirror perf spans to the unified log
        DemoSeed.seedStressIfRequested()      // `-StressSeed <N>`: large-library perf harness
        BenchModel.runIfRequested()           // `-BenchModel`: on-device model latency bench
        DemoSeed.resetActionStateIfRequested() // `-FreshActionState`: deterministic UI-proof state
        DemoSeed.seedIfRequested()   // `-MainPreview` only: seed demo cards for screen-proof
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Time-to-first-draw: the first real UI on screen.
                .onAppear {
                    PerfTelemetry.shared.markFirstDraw()
                    #if DEBUG
                    // Mirror first-draw to the `-PerfLog` console (sim-perf grep format)
                    // so the large-library launch cost is measurable in the simulator.
                    if ProcessInfo.processInfo.arguments.contains("-PerfLog") {
                        let ns = DispatchTime.now().uptimeNanoseconds &- Self.launchStart.uptimeNanoseconds
                        NSLog("perf-span first-draw ms=%d", Int(ns / 1_000_000))
                    }
                    #endif
                }
        }
    }
}
