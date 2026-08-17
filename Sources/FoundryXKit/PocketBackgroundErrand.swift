// A BRING-OVER THAT SURVIVES A SCREENSHOT, AND SURVIVES THE PHONE GOING IN A POCKET.
//
// THE DEFECT THIS ANSWERS, in one line of `App/DeviceScreen.swift`:
//
//     .onChange(of: scenePhase) { phase in if phase != .active { check.cancel() } }
//
// iOS reports `.inactive` for a SCREENSHOT, for Control Center, for the app switcher and for
// a notification banner sliding down. None of those is the person leaving. Nick, on his own
// phone, with recordings on the recorder: "if I do anything like screenshot or leave the page
// to go to another app it fails even the loading, which is an issue if this will take time to
// pull recordings over, it needs to be able to happen in the background."
//
// So there are two facts here and the second is the real one.
//
//   1. THE DECISION. `.inactive` is not a departure and must never stop an errand. It lives
//      here, in the kit, rather than as an `if` typed into a SwiftUI body — because nothing in
//      this repository can execute a body: `swift test` cannot compile `App/` at all. A rule
//      written in a view is a rule with no test, which is exactly how the `!= .active`
//      comparison shipped.
//
//   2. THE ASSERTION. Not stopping is not the same as continuing. iOS suspends a backgrounded
//      app within a few seconds unless it holds a background task assertion, and a suspended
//      app's `URLSession`, its `CBCentralManager` callbacks and its `Task` continuations all
//      stop dead — so a transfer that merely declined to cancel would still die, silently,
//      with the page still claiming it was working. `PocketBackgroundLease` is that assertion,
//      taken for the DURATION of an errand and released on EVERY exit path: the errand
//      finished, the errand failed, the owner left the page, or the system took the time back.
//
// WHAT IS DELIBERATELY UNCHANGED. Leaving the page still stops the errand. `onDisappear` is a
// deliberate departure and the radio should not stay up for a screen nobody is on.

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Where the app is

/// WHERE THE APP IS, in the only three states iOS actually reports.
///
/// A plain enum rather than SwiftUI's `ScenePhase` so the rule below is testable on a runtime
/// with no scene at all. The bridge from `ScenePhase` is at the bottom of this file.
public enum PocketErrandScenePhase: String, Sendable, CaseIterable {
    /// In front of the person, receiving events.
    case active
    /// ON SCREEN BUT NOT RECEIVING EVENTS. A screenshot, Control Center, the app switcher,
    /// a notification banner, an incoming call, the volume HUD. Every one of these is a
    /// moment, not a departure, and several of them are things a person does BECAUSE a
    /// transfer is running — taking a screenshot of the progress being the literal case that
    /// reported this defect.
    case inactive
    /// The app is no longer on screen. Without an assertion the system suspends it here.
    case background
}

/// WHAT A SCENE CHANGE MEANS FOR AN ERRAND THAT IS ALREADY RUNNING.
public enum PocketErrandContinuation: String, Sendable, Equatable {
    /// Nothing about this transition is a reason to stop.
    case carryOn
    /// The errand cannot make progress from here, so it stops SAYING SO rather than being
    /// suspended mid-transfer and coming back looking like it never ran.
    case stopTheErrand
}

/// THE RULE, WITH NOTHING ELSE IN IT.
///
/// It is deliberately total over `PocketErrandScenePhase` — a `switch` with no `default`, so a
/// fourth phase added by a future OS is a compile error here rather than a silent inheritance
/// of whatever the old comparison happened to do.
public enum PocketErrandScenePhasePolicy {

    /// - Parameter isHoldingBackgroundTime: whether an assertion is currently held for this
    ///   errand. It is the ONLY thing that makes `.background` survivable: without it the
    ///   process is suspended within seconds and the errand stops whether or not anybody
    ///   cancels it, so continuing would be a claim the runtime does not honour.
    public static func decide(phase: PocketErrandScenePhase,
                              isHoldingBackgroundTime: Bool) -> PocketErrandContinuation {
        switch phase {
        case .active:
            return .carryOn
        // THE FIX. This used to be folded into `phase != .active` with `.background`, and
        // that single comparison is the whole bug: it treats the four commonest interruptions
        // on iOS as though the owner had walked away.
        case .inactive:
            return .carryOn
        case .background:
            return isHoldingBackgroundTime ? .carryOn : .stopTheErrand
        }
    }

    /// The outcome token an errand stopped by a scene change records. A CLOSED token, never a
    /// sentence: `DoorLog`'s wire form is space-separated `key=value`.
    public static let stoppedWithoutBackgroundTimeToken = "backgrounded-without-time"
}

// MARK: - The assertion itself

/// A HANDLE ON ONE PIECE OF BACKGROUND TIME. Opaque on purpose: nothing outside this file
/// should be able to construct a UIKit identifier by hand.
public struct PocketBackgroundTimeToken: Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

/// THE SYSTEM SEAM, as two closures.
///
/// `UIApplication` is the one thing a hermetic run cannot have — the same reason the radio is
/// injected one file over — so it is the one thing injected. Everything else about the lease
/// (when it is taken, that it is taken once, that it is released on every path) is the shipped
/// code running in the shipped process.
public struct PocketBackgroundTime: Sendable {

    /// Ask the system to keep this process running. Returns `nil` when it refuses — which is a
    /// real answer, not an error: an app already in the background past its budget gets
    /// nothing, and the honest consequence is that the errand stops rather than pretends.
    ///
    /// `onExpiry` is the system TAKING THE TIME BACK. It must be honoured: an assertion that
    /// is not ended from its own expiry handler gets the app KILLED, and a killed app is a
    /// transfer with no message and no log line.
    public var begin: @MainActor @Sendable (_ named: String,
                                            _ onExpiry: @escaping @MainActor @Sendable () -> Void)
        -> PocketBackgroundTimeToken?

    /// Give it back. NOT main-actor isolated, because it has to be callable from a `deinit`,
    /// which is where the last unreleased assertion in the process would otherwise sit
    /// forever. The live implementation hops to the main thread itself.
    public var end: @Sendable (PocketBackgroundTimeToken) -> Void

    public init(begin: @escaping @MainActor @Sendable (String, @escaping @MainActor @Sendable () -> Void)
                    -> PocketBackgroundTimeToken?,
                end: @escaping @Sendable (PocketBackgroundTimeToken) -> Void) {
        self.begin = begin
        self.end = end
    }

    /// THE SHIPPED ONE. `UIApplication.beginBackgroundTask` needs no entitlement and no
    /// `UIBackgroundModes` key — it is the plain "let me finish what I started" budget every
    /// app gets, which is exactly what a bring-over is.
    public static let live = PocketBackgroundTime(
        begin: { named, onExpiry in
            #if canImport(UIKit) && !os(watchOS)
            let identifier = UIApplication.shared.beginBackgroundTask(withName: named) {
                onExpiry()
            }
            guard identifier != .invalid else { return nil }
            return PocketBackgroundTimeToken(rawValue: identifier.rawValue)
            #else
            // A platform with no UIApplication cannot be suspended out from under an errand
            // the way iOS can. Reporting "no time held" there would stop every errand the
            // moment a macOS test host reported a background phase.
            return PocketBackgroundTimeToken(rawValue: 0)
            #endif
        },
        end: { token in
            #if canImport(UIKit) && !os(watchOS)
            let identifier = UIBackgroundTaskIdentifier(rawValue: token.rawValue)
            let release = { @Sendable in
                MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(identifier) }
            }
            if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
            #endif
        })

    /// A SYSTEM THAT WILL NOT GIVE ANY. The honest floor, and the state a scenario needs to
    /// prove that backgrounding without an assertion stops the errand instead of leaving it
    /// suspended and lying about it.
    public static let refused = PocketBackgroundTime(begin: { _, _ in nil }, end: { _ in })
}

/// BACKGROUND TIME, TAKEN ONCE AND GIVEN BACK ON EVERY PATH.
///
/// It is a separate object from the model that uses it for one reason: the property that
/// matters — "taken exactly as many times as it was released" — is a COUNT, and a count is
/// something a test can hold. `App/DeviceScreen.swift` cannot be compiled by `swift test`, so
/// a lease implemented as two lines inside the model would be a leak nothing could notice.
@MainActor
public final class PocketBackgroundLease {

    /// Whether this lease is holding the process up right now.
    public var isHeld: Bool { token != nil }

    /// What the held time is for, in the errand vocabulary (`shelf`, `bring-over`, …).
    public private(set) var subject: String?

    /// HOW MANY TIMES TIME WAS TAKEN AND GIVEN BACK. The instrument for "released on every
    /// exit path": at rest these must be equal, and `isHeld` must be false. A leak is
    /// `taken > released`, and it is the failure that gets an app killed by the watchdog
    /// rather than the one that shows up as a wrong pixel.
    public private(set) var taken = 0
    public private(set) var released = 0

    /// HOW MANY TIMES THE SYSTEM REFUSED. Distinct from "never asked": an errand running with
    /// no protection is a different fact from an errand nobody tried to protect.
    public private(set) var refusals = 0

    /// THE SYSTEM TOOK THE TIME BACK. Set by the owner so it can stop the errand honestly —
    /// the assertion is already released by the time this runs, so carrying on would be a
    /// transfer the runtime is about to suspend.
    public var onExpiry: (@MainActor () -> Void)?

    private let time: PocketBackgroundTime
    private var token: PocketBackgroundTimeToken?

    public init(time: PocketBackgroundTime = .live) {
        self.time = time
    }

    /// Take background time for `subject`, unless this lease already holds some.
    ///
    /// IDEMPOTENT BY TOKEN, not by a flag. Two assertions for one errand is a leak that only
    /// shows up as a killed app under memory pressure, and the model above this has five
    /// errand entry points that all funnel through one `beginErrand`.
    /// - Returns: whether time is now held. `false` means the system refused, and the caller's
    ///   errand runs unprotected — which the scene policy then treats as "a background
    ///   transition stops this".
    @discardableResult
    public func begin(subject: String) -> Bool {
        if token != nil { return true }
        guard let granted = time.begin(subject, { [weak self] in self?.expire() }) else {
            refusals += 1
            return false
        }
        token = granted
        self.subject = subject
        taken += 1
        return true
    }

    /// Give the time back. SILENT WHEN THERE IS NOTHING TO GIVE BACK, because the paths that
    /// call it — an errand that finished, an errand that failed, an owner who left the page —
    /// can and do overlap for one departure.
    public func end() {
        guard let held = token else { return }
        token = nil
        subject = nil
        released += 1
        time.end(held)
    }

    private func expire() {
        end()
        onExpiry?()
    }

    /// THE LAST RESORT. If the model that owns this lease is released mid-errand, nothing else
    /// is ever going to end the assertion — and an assertion that outlives its owner is the
    /// one that gets the app terminated. `time.end` is deliberately not main-actor isolated so
    /// this is callable here.
    deinit {
        if let held = token { time.end(held) }
    }
}

// MARK: - The bridge from SwiftUI

#if canImport(SwiftUI)
extension PocketErrandScenePhase {
    /// The view's phase, in the kit's vocabulary. `@unknown default` maps to `.inactive`
    /// because that is the direction that does not stop a transfer for a state nobody has
    /// described yet — and `.background` is the only phase this policy treats as a stop, so a
    /// phase we cannot recognise must never be mistaken for one.
    public init(_ phase: ScenePhase) {
        switch phase {
        case .active:     self = .active
        case .inactive:   self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}
#endif
