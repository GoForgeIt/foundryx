// FoundryXControl — a Control Center / Action Button control (iOS 18+). Apps do NOT
// appear in the Action Button's fixed top-level list; a ControlWidget is how an app
// becomes a first-class "Control" the user can bind to the Action Button, Control
// Center, or Lock Screen. This one starts a FoundryX recording via the SAME App
// Intent the Shortcut/Siri paths use (CaptureIntentBroker → CaptureManager).
//
// Availability-gated to iOS 18: the Controls API + ControlWidget don't exist earlier
// (on <18 the user still has the Action Button → Shortcut → "Start FoundryX
// Recording" path).

import SwiftUI
import WidgetKit
import AppIntents

@available(iOS 18.0, *)
struct FoundryXRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.goforgeit.foundryx.control.record") {
            ControlWidgetButton(action: StartRecordingControlIntent()) {
                Label("Record", systemImage: "waveform")
            }
        }
        .displayName("FoundryX Recording")
        .description("Start a FoundryX recording.")
    }
}

@available(iOS 18.0, *)
struct FoundryXChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.goforgeit.foundryx.control.chat") {
            ControlWidgetButton(action: OpenChatControlIntent()) {
                Label("Chat", systemImage: "message")
            }
        }
        .displayName("FoundryX Chat")
        .description("Jump straight into FoundryX chat.")
    }
}

@available(iOS 18.0, *)
struct FoundryXActionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.goforgeit.foundryx.control.action") {
            ControlWidgetButton(action: FoundryXActionControlIntent()) {
                Label("FoundryX", systemImage: "bolt")
            }
        }
        .displayName("FoundryX Action")
        .description("Your chosen action — record, chat, or ask each time.")
    }
}
