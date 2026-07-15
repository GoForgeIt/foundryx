// AppShellPresentation — the app shell's pure presentation (track 20260714T1800
// ux_prototype_realignment §1/§9, features/app-shell.feature).
//
// One bottom tab bar, exactly four tabs, in order: Capture → Activity → Chat →
// Device, Capture as the launch tab (prototype `bottomNav`). Settings is NOT a
// tab — a gear in the Capture/Activity top bars opens it as a dismissable sheet
// with an X close. The views render FROM these values (RootView's TabRouter.Tab
// IS AppTab), so the tests assert exactly what the shell shows.

import Foundation

/// The bottom tab bar, in declaration = render order.
public enum AppTab: String, CaseIterable, Hashable, Sendable {
    // Content loops only (Nick 2026-07-14): Device management moved into Settings, so
    // the tab bar is the three daily surfaces — no competing management tab.
    case capture, activity, chat

    /// The launch/home tab (prototype: Capture first).
    public static let launch: AppTab = .capture

    public var label: String {
        switch self {
        case .capture: return "Capture"
        case .activity: return "Activity"
        case .chat: return "Chat"
        }
    }

    public var systemImage: String {
        switch self {
        case .capture: return "waveform"
        case .activity: return "waveform.path.ecg"
        case .chat: return "message"
        }
    }
}

/// Settings-as-a-sheet (spec §9, prototype "19 Settings"): opened from the
/// Capture/Activity gear, dismissed with an X — never a bottom tab.
public enum SettingsSheetPresentation {
    public static let title = "Settings"
    public static let gearAccessibilityLabel = "Settings"
    public static let closeAccessibilityLabel = "Close Settings"
}

/// B5 — joining the Foundry Cloud waitlist never silently no-ops. A tokenless
/// (phone-only) user is routed through sign-in first; the POST fires with the
/// fresh token; a dismissed sign-in leaves the honest caption.
public enum WaitlistJoin {
    public enum Step: Equatable, Sendable { case alreadyJoined, signInFirst, post }

    public static func step(joined: Bool, hasIdToken: Bool) -> Step {
        if joined { return .alreadyJoined }
        return hasIdToken ? .post : .signInFirst
    }

    /// Shown under the join button after a dismissed (unfinished) sign-in.
    public static let signInCaption = "Sign in to join"
}
