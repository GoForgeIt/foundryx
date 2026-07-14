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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Time-to-first-draw: the first real UI on screen.
                .onAppear { PerfTelemetry.shared.markFirstDraw() }
        }
    }
}
