// FoundryXWidgetBundle — the widget extension entry point. Bundles the home/lock-screen
// status widget and (on iOS 16.1+) the capture Live Activity.

import SwiftUI
import WidgetKit

@main
struct FoundryXWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaptureStatusWidget()
        liveActivityWidgets
        controlWidgets
    }

    // Live Activities are iOS 16.1+; gate the Live Activity widget so the bundle still
    // builds/loads on 16.0.
    @WidgetBundleBuilder
    private var liveActivityWidgets: some Widget {
        if #available(iOS 16.1, *) {
            CaptureLiveActivity()
        }
    }

    // Controls (Control Center / Action Button) are iOS 18+.
    @WidgetBundleBuilder
    private var controlWidgets: some Widget {
        if #available(iOS 18.0, *) {
            FoundryXRecordControl()
            FoundryXChatControl()
            FoundryXActionControl()
        }
    }
}
