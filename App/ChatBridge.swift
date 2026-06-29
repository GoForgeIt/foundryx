import SwiftUI

/// Glue between the Capture and Chat tabs: lets a captured conversation's transcript
/// launch a chat seeded with that conversation as context ("Ask in chat"), and drives
/// the tab switch. Owned by MainTabs; WRITTEN by ConversationDetailView (sets the seed),
/// READ by ChatScreen (consumes the seed into a fresh chat, then clears it).
///
/// This is the capture→chat loop: ambient recall becomes action without leaving the app.
@MainActor
final class ChatBridge: ObservableObject {
    /// The active tab. 0 = Chat, 1 = Capture, 2 = Device — matches MainTabs' `.tag` order.
    @Published var selectedTab: Int = 0
    /// A pending prompt to seed a NEW chat with (a captured conversation as context).
    /// ChatScreen consumes it on appear / change, then nils it.
    @Published var pendingPrompt: String?

    /// Seed a new chat with `prompt` and jump to the Chat tab.
    func askAbout(_ prompt: String) {
        pendingPrompt = prompt
        selectedTab = 0
    }
}
