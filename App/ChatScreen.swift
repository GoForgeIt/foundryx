import SwiftUI

struct ChatScreen: View {
    let config: DoorConfig
    @StateObject private var model = ChatViewModel()
    @State private var input = ""
    @State private var sessionId = ""
    @State private var streaming = false

    private var client: DoorClient {
        DoorClient(target: DoorTarget(baseURL: config.doorURL, bearer: config.bearer))
    }

    var body: some View {
        VStack {
            ScrollView { ChatView(model: model, onApprove: { answer($0, "always") }, onReject: { answer($0, "reject") }) }
            HStack {
                TextField("Message the local brain…", text: $input)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { send() }.disabled(input.isEmpty || streaming)
            }.padding()
        }
    }

    private func send() {
        let text = input; input = ""; streaming = true
        model.beginUserTurn(text)
        Task {
            do {
                for try await ev in client.events(for: ChatRequest(message: text, platform: "foundryx", chatId: "ios", org: "acme")) {
                    if case .session(let sid) = ev { sessionId = sid }
                    await MainActor.run { model.apply(ev) }
                }
            } catch { await MainActor.run { model.apply(.boundary(label: "error: \(error)")) } }
            await MainActor.run { streaming = false }
        }
    }

    private func answer(_ callId: String, _ decision: String) {
        Task { try? await client.answerApproval(sessionId: sessionId, callId: callId, decision: decision) }
    }
}
