import SwiftUI

@main
struct FoundryXApp: App {
    init() {
        // Start the cold-launch clock as early as possible, and wire perf
        // telemetry (MetricKit + our own spans) to the diagnostics endpoint so
        // launch/hang data flows across the fleet, not one .ips at a time.
        PerfTelemetry.shared.markProcessStart()
        PerfTelemetry.shared.start(
            endpoint: RemoteConfig.fromBundle()?.gatewayHTTPURL.appendingPathComponent("diag/log"))
        // The content-free product-usage sink is wired to the Foundry DOOR (bearer-gated)
        // once sign-in resolves the target — see RootView's setUsageTarget call. It is
        // delivered THROUGH Foundry (the door appends it to the local telemetry rollup).
        #if DEBUG
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
                .onAppear { PerfTelemetry.shared.markFirstDraw() }
        }
    }
}
