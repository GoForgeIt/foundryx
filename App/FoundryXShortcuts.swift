// FoundryXShortcuts — the quick-start App Intents (track 20260705T1100, Phase 5,
// locked decision #4): `Start FoundryX Recording` (phone mic) and `Open FoundryX
// Chat`, bindable to the Action Button (15 Pro+), Control Center, Lock Screen,
// Siri, and back-tap. Plus the configurable `FoundryX Action` whose behavior the
// user picks (Record | Chat | Ask me — the "Ask me" chooser is a two-button sheet
// in the app). App-target only: performing any of these runs IN the app process
// and routes through the same CaptureIntentBroker the Live Activity uses.

import Foundation
import AppIntents

@available(iOS 16.0, *)
struct StartFoundryXRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start FoundryX Voice Note"
    static let description = IntentDescription("Start a voice note from the phone microphone.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentBroker.shared.perform(.startRecording)
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenFoundryXChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open FoundryX Chat"
    static let description = IntentDescription("Jump straight into chat.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureIntentBroker.shared.perform(.openChat)
        return .result()
    }
}

/// What the configurable FoundryX Action does (Settings → Action Button).
enum ActionButtonChoice: String, CaseIterable {
    case record, chat, ask

    static let key = "foundryx.action-button.choice"
    static var current: ActionButtonChoice {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(ActionButtonChoice.init) ?? .record
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var label: String {
        switch self {
        case .record: return "Start a note"
        case .chat: return "Open chat"
        case .ask: return "Ask me each time"
        }
    }
}

@available(iOS 16.0, *)
struct FoundryXActionIntent: AppIntent {
    static let title: LocalizedStringResource = "FoundryX Action"
    static let description = IntentDescription(
        "Runs your chosen FoundryX action — start a note, open chat, or ask each time.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        switch ActionButtonChoice.current {
        case .record: CaptureIntentBroker.shared.perform(.startRecording)
        case .chat: CaptureIntentBroker.shared.perform(.openChat)
        case .ask: CaptureIntentBroker.shared.perform(.askChooser)
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct FoundryXShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFoundryXRecordingIntent(),
            phrases: ["Start a \(.applicationName) voice note",
                      "Make a voice note with \(.applicationName)"],
            shortTitle: "Start Voice Note",
            systemImageName: "waveform")
        AppShortcut(
            intent: OpenFoundryXChatIntent(),
            phrases: ["Open \(.applicationName) chat",
                      "Ask \(.applicationName)"],
            shortTitle: "Open Chat",
            systemImageName: "message")
        AppShortcut(
            intent: FoundryXActionIntent(),
            phrases: ["\(.applicationName) action"],
            shortTitle: "FoundryX Action",
            systemImageName: "bolt")
    }
}
