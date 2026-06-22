import SwiftUI
import Grain
#if canImport(UIKit)
import UIKit
#endif

struct ChatScreen: View {
    let config: DoorConfig
    /// When set (signed in + a host resolved), chat is served through the blind
    /// relay (off-LAN); nil = LAN-direct (unchanged).
    var relay: RelayConfig? = nil
    @StateObject private var model = ChatViewModel()
    // Shared with DeviceManager + CaptureManager (injected by MainTabs) so the
    // "Copy logs" button surfaces BLE/capture events too — not just chat.
    @ObservedObject var log: DoorLog
    @State private var input = ""
    @State private var sessionId = ""
    @State private var streaming = false
    @State private var copied = false

    private var client: DoorClient {
        DoorClient(target: DoorTarget(baseURL: config.doorURL, bearer: config.bearer, relay: relay), log: log)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Debug bar: copy the full session log to paste elsewhere when the
            // connection misbehaves. (Status dot lives in ChatView, by the messages.)
            HStack(spacing: GrainSpacing.x2) {
                Text("\(log.entries.count) log entries")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                Spacer()
                GrainButton(copied ? "Copied!" : "Copy logs", variant: .text, size: .sm) {
                    copyLogs()
                }
            }
            .padding(.horizontal, GrainSpacing.x4)
            .padding(.vertical, GrainSpacing.x2)

            ScrollView {
                ChatView(model: model,
                         onApprove: { answer($0, "always") },
                         onReject: { answer($0, "reject") })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Tap anywhere in the chat (or drag) dismisses the keyboard; tapping
            // back into the composer field re-opens it (its own focus, default).
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
            GrainComposer("Message the local brain…", text: $input, isSending: streaming, onSend: send)
        }
        .grainBackground()
    }

    private func copyLogs() {
        #if canImport(UIKit)
        UIPasteboard.general.string = log.dump()
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// Resign first responder so a tap in the chat closes the keyboard.
    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func send() {
        let text = input; input = ""; streaming = true
        model.beginUserTurn(text)
        model.setConnection(.connecting)
        log.info("send tapped → \(config.doorURL.absoluteString)")
        Task {
            var sawEvent = false
            do {
                for try await ev in client.events(for: ChatRequest(message: text, platform: "foundryx", chatId: "ios", org: "acme")) {
                    if !sawEvent { sawEvent = true; await MainActor.run { model.setConnection(.streaming) } }
                    if case .session(let sid) = ev { sessionId = sid }
                    if case .done(let reason) = ev { await MainActor.run { model.setConnection(.completed(reason: reason)) } }
                    await MainActor.run { model.apply(ev) }
                }
                // Stream ended without a thrown error. If we never saw an event the
                // door dropped the socket before replying — flag it, don't look "done".
                if !sawEvent {
                    log.warn("stream ended with 0 events (door closed before any reply)")
                    await MainActor.run { model.setConnection(.error(detail: "no response from door (0 events)")) }
                }
            } catch {
                let detail = Self.errorDetail(error)
                log.error("turn failed: \(detail)")
                await MainActor.run {
                    model.setConnection(.error(detail: detail))
                    model.apply(.boundary(label: "error: \(detail)"))
                }
            }
            await MainActor.run { streaming = false }
        }
    }

    /// Human-readable failure reason for the status pill (the detail that used to vanish).
    private static func errorDetail(_ error: Error) -> String {
        if let de = error as? DoorError {
            switch de {
            case .unauthorized: return "401 unauthorized (bad token)"
            case .http(let code): return "HTTP \(code)"
            case .transport(let msg): return msg
            }
        }
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    private func answer(_ callId: String, _ decision: String) {
        Task { try? await client.answerApproval(sessionId: sessionId, callId: callId, decision: decision) }
    }
}
