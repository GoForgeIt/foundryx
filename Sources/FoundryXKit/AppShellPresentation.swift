// AppShellPresentation — the app shell's pure presentation (track 20260714T1800
// ux_prototype_realignment §1/§9, features/app-shell.feature; T1 20260715T1457).
//
// One bottom tab bar, exactly four tabs, in order: Capture → Activity → Chat →
// Settings, Capture as the launch tab (prototype `bottomNav`). Settings is a
// FIRST-CLASS bottom-nav tab now (Nick 2026-07-15) — superseding the 2026-07-14
// "Settings as a dismissable sheet / 3 content tabs" decision. Device management
// still lives INSIDE Settings (no competing Device tab). The views render FROM
// these values (RootView's TabRouter.Tab IS AppTab), so the tests assert exactly
// what the shell shows.

import Foundation

/// The bottom tab bar, in declaration = render order.
/// `Codable` because the tab is half of the durable place we keep for the person
/// (`AppPlacement`) — a raw-value round trip, so an unknown tab from an older or newer
/// build fails to decode and falls back to the launch tab rather than crashing.
public enum AppTab: String, CaseIterable, Hashable, Sendable, Codable {
    // Three daily surfaces + Settings (Nick 2026-07-15): Settings is the 4th
    // bottom-nav tab. Device management still lives INSIDE Settings — no competing
    // Device tab.
    case capture, activity, chat, settings

    /// The launch/home tab (prototype: Capture first).
    public static let launch: AppTab = .capture

    public var label: String {
        switch self {
        case .capture: return "Capture"
        case .activity: return "Activity"
        case .chat: return "Chat"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .capture: return "waveform"
        case .activity: return "waveform.path.ecg"
        case .chat: return "message"
        case .settings: return "gearshape"
        }
    }
}

/// Settings presentation constants (spec §9, prototype "19 Settings"). Settings is
/// now the 4th bottom-nav tab (Nick 2026-07-15); this just carries its title.
public enum SettingsSheetPresentation {
    public static let title = "Settings"
    /// Device management lives INSIDE Settings (no competing Device tab, Nick
    /// 2026-07-14) as this entry, which opens the device page. Single source of
    /// truth so the shell test and `SettingsScreen` agree on the label.
    public static let deviceEntryLabel = "Devices & connections"
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
