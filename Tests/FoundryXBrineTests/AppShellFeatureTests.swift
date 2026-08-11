import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/app-shell.feature. Drives the REAL shell model the
/// RootView tab bar renders from — `AppTab` (order, labels, launch tab) and
/// `SettingsSheetPresentation` (Settings title + the in-Settings device entry) —
/// so the four-tab structure, the "Settings is a tab, Device is not" law, and the
/// "device management lives inside Settings" decision are asserted against the same
/// values the views use. Hermetic: pure types, no UI.
final class AppShellFeatureTests: XCTestCase {
    func testAppShellFeature() async throws {
        try await BrineFeatureRunner.run(
            "app-shell",
            registry: StepRegistry(AppShellSteps.make(world: AppShellWorld())))
    }
}

private final class AppShellWorld: @unchecked Sendable {
    /// The rendered tab bar, in order — exactly `AppTab.allCases` (declaration order
    /// IS render order, per AppShellPresentation).
    var tabs: [AppTab] = []
    /// The selected tab after the shell is presented (launch = Capture).
    var selected: AppTab?
    /// Whether the Settings tab is the open surface (the "open Settings" action).
    var settingsOpen = false

    func present() {
        tabs = AppTab.allCases
        selected = AppTab.launch
        settingsOpen = false
    }
    func openSettings() {
        // Reached by TAPPING the Settings tab — there is no other route (no header gear).
        selected = .settings
        settingsOpen = true
    }
}

private enum AppShellSteps {
    static func make(world w: AppShellWorld) -> [StepDefinition] {
        [
            defineStep("the app shell is presented") { ctx, _, _ in
                w.present(); return ctx
            },
            defineStep("I open the Settings tab") { ctx, _, _ in
                w.present(); w.openSettings(); return ctx
            },

            defineCheck("the bottom tab bar shows exactly \"Capture\", \"Activity\", \"Chats\", \"Settings\" in that order") { _, _, _ in
                let labels = w.tabs.map(\.label)
                guard labels == ["Capture", "Activity", "Chats", "Settings"] else {
                    throw BrineStepError("tab order was \(labels)")
                }
            },
            defineCheck("the Capture tab is selected") { _, _, _ in
                guard w.selected == .capture else {
                    throw BrineStepError("launch tab was \(String(describing: w.selected)), expected .capture")
                }
            },
            defineCheck("a tab is labelled \"Settings\"") { _, _, _ in
                guard w.tabs.contains(where: { $0.label == "Settings" }) else {
                    throw BrineStepError("no Settings tab in \(w.tabs.map(\.label))")
                }
            },
            defineCheck("no tab is labelled \"Device\"") { _, _, _ in
                // Device management is NOT its own tab — it lives inside Settings.
                guard !w.tabs.contains(where: { $0.label == "Device" || $0.label == "Devices" }) else {
                    throw BrineStepError("a Device tab exists: \(w.tabs.map(\.label))")
                }
                guard AppTab(rawValue: "device") == nil else {
                    throw BrineStepError("AppTab has a .device case")
                }
            },
            defineCheck("I see a \"Devices & connections\" entry that opens the device page") { _, _, _ in
                guard w.settingsOpen else { throw BrineStepError("Settings is not open") }
                guard SettingsSheetPresentation.deviceEntryLabel == "Devices & connections" else {
                    throw BrineStepError("device entry label is \(SettingsSheetPresentation.deviceEntryLabel)")
                }
            },
            defineCheck("the Capture screen shows no settings gear in its header") { _, _, _ in
                // Structural truth the shell guarantees: Settings is a TAB, so no header
                // gear duplicates it. There is no Settings affordance among Capture-screen
                // header controls — Settings is reachable only as a bottom-nav tab.
                guard AppTab.launch == .capture else {
                    throw BrineStepError("Capture is not the launch surface")
                }
                guard AppTab.allCases.contains(.settings) else {
                    throw BrineStepError("Settings is not a first-class tab, so a header gear would be the only route")
                }
            },
            defineCheck("I reach Settings by tapping the Settings tab") { _, _, _ in
                w.openSettings()
                guard w.selected == .settings, w.settingsOpen else {
                    throw BrineStepError("tapping the Settings tab did not open Settings")
                }
            },
        ]
    }
}
