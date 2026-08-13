import XCTest
import Foundation
import UIKit

/// DRIVING THE APPLICATION'S OWN CODE, INSIDE THE APPLICATION.
///
/// WHY THIS LANE EXISTS. `Tests/FoundryXBrineTests` is a hostless bundle whose only code
/// dependency is the FoundryXKit library. It cannot import `App/` — so every scenario it runs
/// asserts against an object graph the TEST assembled, and passes identically whether or not
/// the shipping app ever reaches that graph. An audit of 17 `*FeatureTests.swift` files
/// spanning capture, chat, account, pocket, vault, device, sync, onboarding and search found
/// 17 of 17 hand-building the seam, 0 of 17 driving a production entry point, and 0 of 17
/// asserting app reachability by executing app code. Seven of the 73 feature suites hold an
/// App-side fact at all, and all seven hold it by SCANNING App SOURCE AS TEXT. Meanwhile 345
/// of the 660 public types in `Sources/FoundryXKit` are never named in `App/` or `Widget/`,
/// and 274 of those are referenced only by tests.
///
/// The consequence is a whole category of defect that ships green: `PocketBLEClient.download`
/// and `RecordingDeviceAdoption.remember` were each fully implemented, fully scenario-covered
/// and entirely unreachable from the application. It is also a category of defect nothing
/// could REGRESS on, because `App/DeviceScreen.swift` holds roughly 900 lines of view-model
/// logic — `RecordingDeviceListModel`, `PocketRecorderCheckModel`, `RecordingDeviceAttachModel`
/// — that not one test in this repository is able to execute.
///
/// WHAT THIS BUNDLE IS. It is injected into the REAL application process (`TEST_HOST` =
/// `FoundryX.app`), so `@testable import FoundryX` reaches the app module — `App/` and
/// `Sources/FoundryXKit` compiled exactly as the app compiles them. A scenario here drives the
/// app's own objects; deleting a call site in `App/` turns it red.
///
/// WHAT IT DELIBERATELY IS NOT. It does not read pixels. An earlier draft rendered the shipping
/// SwiftUI view in a `UIWindow` and walked the accessibility tree for the button's words; that
/// cannot work in-process and the failed attempt is worth recording so nobody spends the day
/// again. SwiftUI does not back `Text` or `Button` with `UIView`s — a laid-out
/// `RecordingDevicePageView` at 402x874 produces exactly six views (`_UIHostingView`,
/// `PlatformContainer`, `HostingScrollView`, `PlatformGroupContainer`, the scroll indicator
/// and its backing view) and draws every word into the host layer's display list. The words
/// are published only through the accessibility server, which is not running in a hosted unit
/// test, so `accessibilityElements` and `accessibilityElementCount()` both come back empty.
/// Rendered-control claims therefore stay the `uiproof` XCUITest lane's job, which queries
/// that server out-of-process. This lane owns the layer underneath: the app's models, wired
/// the way the app wires them.
enum AppScenarioHost {

    /// Wait for a condition on main-actor state to hold, by YIELDING the main actor.
    ///
    /// The app's models do their work in a `Task` that resumes on the main actor. A scenario
    /// therefore has to GIVE THE ACTOR UP while it waits, and the obvious-looking way to wait
    /// — a nested `RunLoop.current.run(until:)` — does the opposite: it holds the main thread
    /// inside the model's own isolation, the model's continuation never gets to run, and the
    /// check hangs until the timeout. (That was not a theory; it deadlocked here first, and
    /// the crash it produced was the fake radio's `unowned` stack being read after the world
    /// had moved on, which reads like an ownership bug and is not one.)
    ///
    /// `Task.sleep` suspends instead, so every awaiting job on this actor gets to proceed.
    /// It returns the instant the state arrives and THROWS when it does not, naming what was
    /// being waited for. A silent timeout would hand the next step a half-finished model and
    /// produce a failure about the wrong thing.
    @MainActor
    static func settle(untilTrue condition: () -> Bool,
                       timeout: TimeInterval = 20,
                       describing what: @autoclosure () -> String) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw Timeout(description:
                    "waited \(Int(timeout))s for \(what()) and it never happened")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    struct Timeout: Error, CustomStringConvertible { let description: String }
}
