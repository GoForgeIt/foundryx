// CaptureIntents — the interactive Live Activity buttons (iOS 17+ App Intents). TWO
// actions on the capture Live Activity:
//   • End Current  — end/finalize the CURRENT conversation now (a discrete card); capture
//                    keeps running and the next voiced audio opens a fresh conversation.
//   • Pause/Resume — toggle capture pause (device stays connected).
//
// SHARED source: this file is compiled into BOTH the app target AND the widget extension.
// The widget REFERENCES the intent types to attach them to `Button(intent:)`; the APP
// PERFORMS them (a LiveActivityIntent runs in the app's process). So the intents must NOT
// depend on the app-only FoundryXKit module — instead they route through
// `CaptureIntentBroker`, a tiny process-wide handler the APP registers (wiring to the live
// CaptureManager). In the widget process the broker has no handler and `perform()` is a
// harmless no-op (the widget never performs an intent).
//
// AppIntents landed in iOS 16, but `LiveActivityIntent` (interactive Live Activity
// buttons) is iOS 17+, so every intent is `@available(iOS 17.0, *)`-gated. On iOS 16 the
// Live Activity simply renders the buttons as non-interactive labels (guarded at the UI).

import Foundation
#if canImport(AppIntents)
import AppIntents
#endif

/// The interactive actions the capture Live Activity offers.
public enum CaptureLiveActivityAction: String, Sendable {
    /// End/finalize the current conversation now; keep capturing (start a fresh one on the
    /// next voiced audio). Backed by CaptureManager.endCurrentConversation().
    case endCurrent
    /// Toggle capture pause/resume. Backed by CaptureManager.togglePause().
    case togglePause
    /// Quick-start a phone-mic recording (track 20260705T1100 decision #4 — Action
    /// Button / Control Center / Siri). Backed by CaptureManager.startMicRecording().
    case startRecording
    /// Jump straight into chat. Backed by the tab router.
    case openChat
    /// The Action-Button "Ask me" chooser (two-button sheet: Record | Chat).
    case askChooser
}

/// Process-wide broker between the Live Activity's App Intents and the live capture
/// pipeline. The APP registers a handler on launch (→ CaptureManager); the intents call
/// `perform(_:)`. Main-actor isolated: the handler mutates main-actor capture state. In a
/// process with no handler (the widget extension), `perform` is a no-op.
@MainActor
public final class CaptureIntentBroker {
    public static let shared = CaptureIntentBroker()
    private init() {}

    /// Perform an action; returns whether it acted (false = no active capture / no handler,
    /// so the button was a safe no-op). The app installs the real handler.
    public var handler: ((CaptureLiveActivityAction) -> Bool)?

    @discardableResult
    public func perform(_ action: CaptureLiveActivityAction) -> Bool {
        handler?(action) ?? false
    }
}

#if canImport(AppIntents)
/// "End Current" — finalize the current conversation now (capture keeps running).
@available(iOS 17.0, *)
public struct EndCurrentConversationIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "End Current Conversation"
    public static let description = IntentDescription(
        "End the current conversation now and keep capturing the next one.")
    // Don't foreground the app for a quick capture-boundary toggle.
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = CaptureIntentBroker.shared.perform(.endCurrent)
        return .result()
    }
}

/// "Pause/Resume" — toggle capture pause. The button's LABEL reflects the current phase
/// (Pause while recording, Resume while paused); the intent itself just toggles.
@available(iOS 17.0, *)
public struct ToggleCapturePauseIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Pause or Resume Capture"
    public static let description = IntentDescription(
        "Pause capture (the device stays connected) or resume it.")
    public static let openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = CaptureIntentBroker.shared.perform(.togglePause)
        return .result()
    }
}

/// "Record" for the Control Center / Action Button control (iOS 18 ControlWidget).
/// Plain AppIntent (not LiveActivityIntent) so it can OPEN the app, then start a
/// phone-mic recording through the broker — same path as the Shortcut/Siri intent,
/// but defined in the SHARED file so the widget extension can reference it.
@available(iOS 16.0, *)
public struct StartRecordingControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start FoundryX Recording"
    public static let description = IntentDescription("Start recording from the phone microphone.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = CaptureIntentBroker.shared.perform(.startRecording)
        return .result()
    }
}

/// "Open Chat" for the Controls picker — same broker path as the App Shortcut.
@available(iOS 16.0, *)
public struct OpenChatControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open FoundryX Chat"
    public static let description = IntentDescription("Jump straight into chat.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        _ = CaptureIntentBroker.shared.perform(.openChat)
        return .result()
    }
}

/// The configurable "FoundryX Action" (Record | Chat | Ask me — Settings picks) for
/// the Controls picker. Reads the same UserDefaults key the App-Shortcut variant uses
/// (duplicated literal: the widget target can't see ActionButtonChoice in the App target).
@available(iOS 16.0, *)
public struct FoundryXActionControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "FoundryX Action"
    public static let description = IntentDescription(
        "Runs your chosen FoundryX action — start recording, open chat, or ask each time.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        switch UserDefaults.standard.string(forKey: "foundryx.action-button.choice") ?? "record" {
        case "chat": _ = CaptureIntentBroker.shared.perform(.openChat)
        case "ask": _ = CaptureIntentBroker.shared.perform(.askChooser)
        default: _ = CaptureIntentBroker.shared.perform(.startRecording)
        }
        return .result()
    }
}
#endif
