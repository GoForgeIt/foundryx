import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/chat-turn-always-ends.feature.
///
/// Everything here is the real thing. The turn is `PhoneChatTurn.run` — the exact function
/// `App/ChatScreen.swift` calls. The thread is a real `ChatViewModel`, the history is a real
/// `ChatConversationStore` writing to a real file inside a real `CaptureAccountScope` account
/// root, and the door is the real `DoorClient` over a `URLProtocol` stub that answers the way
/// the measured door answers: refused connection, a streamed reply, 503 when it holds no
/// kiln-session, 502 when it cannot reach the one it holds.
///
/// WHY EVERY SCENARIO IS ON A DEADLINE. The defect this feature exists for was a main-thread
/// self-deadlock, and a suite that reproduces a deadlock by deadlocking is useless — it hangs
/// instead of failing. So the nested account-scoped write is probed FIRST, on a thread of its
/// own, with a bounded wait: if it does not return, the scenario FAILS with a sentence naming
/// the deadlock, and nothing in this file ever touches the main thread afterwards.
final class ChatTurnAlwaysEndsFeatureTests: ProcessGlobalStateTestCase {
    func testChatTurnAlwaysEndsFeature() async throws {
        try await BrineFeatureRunner.run(
            "chat-turn-always-ends",
            registry: StepRegistry(ChatTurnSteps.make(world: ChatTurnWorld())))
    }

    /// A deadlocked account gate cannot be torn down — `resetTestEnvironment()` takes the
    /// very lock the wedged thread is holding, so the inherited tearDown would hang the
    /// process and turn a named failure into a silent CI timeout. Say what happened and
    /// leave the gate alone; the scenarios have already failed by this point.
    override func tearDown() {
        if ChatTurnWorld.gateWedged {
            XCTFail("the account gate deadlocked — skipping tearDown, which would hang on "
                    + "the same lock. Fix the re-entrancy before reading any other result "
                    + "from this process.")
            return
        }
        super.tearDown()
    }
}

// MARK: - the door, behaving the way the measured one does

private enum DoorBehaviour: Sendable {
    /// Nothing is listening — the phone is off my network, or the Mac is asleep.
    case unreachable
    case answers
    /// The door is up and answers, but holds no kiln-session to route to.
    case kilnNotRunning      // 503
    /// The door holds a session URL and cannot reach it.
    case kilnUnreachable     // 502
}

private final class DoorStub: URLProtocol {
    nonisolated(unsafe) static var behaviour: DoorBehaviour = .answers

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.behaviour {
        case .unreachable:
            // The exact error a refused connection produces, which is what
            // `http://127.0.0.1:1` gives the app in the simulator.
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
            return
        case .answers:
            let body = Data((
                "data: {\"type\":\"assistant_delta\",\"text\":\"the door answered\"}\n\n"
                + "data: {\"type\":\"done\",\"reason\":\"stop\"}\n\n").utf8)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
        case .kilnNotRunning, .kilnUnreachable:
            let code = Self.behaviour == .kilnNotRunning ? 503 : 502
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - the world

private final class ChatTurnWorld: @unchecked Sendable {

    /// How long a finished turn gets to be recorded before we call it a deadlock. The real
    /// work is one small JSON encode and one atomic write — milliseconds. Five seconds is
    /// slack for a loaded CI worker, not a race.
    static let deadline: TimeInterval = 5

    var binding: CaptureAccountScope.AccountBinding?
    var store: ChatConversationStore?
    var model = ChatViewModel()
    var behaviour: DoorBehaviour = .answers
    /// Set once the account gate is proven to have deadlocked. Every later step refuses to
    /// touch it, so ONE wedged thread cannot become a hung suite. Static because the damage
    /// outlives the world: the wedged thread holds a process-wide lock forever, so tearDown
    /// has to know too.
    nonisolated(unsafe) static var gateWedged = false
    var wedged: Bool {
        get { Self.gateWedged }
        set { Self.gateWedged = newValue }
    }
    /// Whether the composer would have come back — the caller's unconditional hand-back.
    var composerFree = false
    var turnRecorded: Bool?
    /// Did the nested account-scoped write return at all, and did the inner work run?
    var innerRan = false

    func reset() {
        binding = nil
        store = nil
        model = ChatViewModel()
        behaviour = .answers
        composerFree = false
        turnRecorded = nil
        innerRan = false
        DoorStub.behaviour = .answers
    }

    func requireHealthy() throws {
        if wedged {
            throw BrineStepError(
                "the account gate deadlocked earlier in this feature and is still held — "
                    + "refusing to touch it again")
        }
    }

    func requireStore() throws -> ChatConversationStore {
        guard let store else { throw BrineStepError("no chat store — sign in first") }
        return store
    }

    func requireBinding() throws -> CaptureAccountScope.AccountBinding {
        guard let binding else { throw BrineStepError("no account binding — sign in first") }
        return binding
    }

    /// Run `work` on a thread of its own and wait `deadline` for it. Returns false if it did
    /// not return — which, for anything that enters `CaptureAccountScope`, means the gate
    /// deadlocked. The stuck thread is deliberately NOT joined: it is holding a lock it will
    /// never release, and the point is to report that rather than to join it.
    func withinDeadline(_ what: String, _ work: @escaping () -> Void) throws {
        let boxed = UncheckedBox(work)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            boxed.value()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        if done.wait(timeout: .now() + Self.deadline) == .timedOut {
            wedged = true
            let diagnosis =
                "\(what) did not return within \(Int(Self.deadline))s — the account gate "
                + "deadlocked (account-scoped work cannot do account-scoped work). "
                + "On the phone this is the app freezing: no screen, no composer, no "
                + "accessibility hierarchy."
            // Say it NOW, on stderr, before anything else can happen. The wedged thread is
            // holding a process-wide lock it will never release, so whatever runs next —
            // another scenario, this suite's tearDown, another suite — may hang too. XCTest
            // buffers its report until the process finishes, which a deadlocked process
            // never does, so without this line the only symptom is silence. The named
            // diagnosis has to escape the process before the process stops being able to
            // report anything.
            FileHandle.standardError.write(Data(
                "\n[chat-turn-always-ends] DEADLOCK: \(diagnosis)\n".utf8))
            throw BrineStepError(diagnosis)
        }
    }

    /// Sign in: publish an account, and bind a REAL conversation store to its root.
    ///
    /// The probe is the point. Before any scenario asserts anything, the exact composition
    /// that froze the app — an account-scoped write whose own persistence is account-scoped —
    /// is run once, on its own thread, under a deadline.
    func signIn() throws {
        // FIRST — before anything touches the gate. Once a thread has wedged it, reading the
        // current binding blocks forever, and a later scenario must fail loudly rather than
        // hang on the damage the earlier one already reported.
        try requireHealthy()
        reset()
        guard let binding = CaptureAccountScope.currentAccountBinding() else {
            throw BrineStepError("no current account — the fixture did not publish one")
        }
        self.binding = binding
        let url = ChatConversationStore.storageURL(inAccountRoot: binding.root)
        try FileManager.default.createDirectory(
            at: binding.root, withIntermediateDirectories: true)
        let store = ChatConversationStore(storageURL: url)
        self.store = store

        try withinDeadline("recording a finished turn") { [weak self] in
            let recorded = PhoneChatTurn.record(
                [.init(role: "user", text: "probe")],
                into: store, chatId: store.activeId, as: binding)
            self?.innerRan = recorded
        }
        guard innerRan else {
            throw BrineStepError(
                "the account gate refused a write from the account that is current — "
                    + "the probe proves nothing if it never entered")
        }
        // Leave the store as the scenario found it.
        store.setMessages([], for: store.activeId)
        innerRan = false
    }

    func client() -> DoorClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DoorStub.self]
        DoorStub.behaviour = behaviour
        return DoorClient(
            target: DoorTarget(baseURL: URL(string: "http://computer.local:14288")!,
                               bearer: "tok-9"),
            session: URLSession(configuration: cfg))
    }

    /// Send one turn through the REAL `PhoneChatTurn.run` — the function the chat screen
    /// calls — and hand the composer back the way the screen does.
    @MainActor
    func sendTurn(_ text: String) async throws {
        try requireHealthy()
        let store = try requireStore()
        let binding = try requireBinding()
        await PhoneChatTurn.run(
            text: text, chatId: store.activeId, store: store, model: model,
            client: client(), as: binding)
        composerFree = true
    }

    /// Everything the reader can actually see in the thread: the turns themselves, the
    /// turn-status line a refused turn renders (`ChatView`'s `turn-status`), and the
    /// connection row (`connection-status`). Asserting on the messages alone would miss the
    /// failure sentence entirely — a refusal is a STATE the surface renders, not a message.
    var threadText: String {
        var parts = model.snapshot().map(\.text)
        if case .refused(let reason) = model.turnState { parts.append(reason ?? "") }
        if case .error(let detail) = model.connection { parts.append(detail) }
        return parts.joined(separator: "\n")
    }

    func historyText() throws -> String {
        let store = try requireStore()
        // Read it back from the FILE the store persisted, not from the object in hand —
        // "written into my history" is a durability claim.
        let url = ChatConversationStore.storageURL(inAccountRoot: try requireBinding().root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BrineStepError("the store never wrote \(url.lastPathComponent)")
        }
        let reloaded = ChatConversationStore(storageURL: url)
        guard let convo = reloaded.conversations.first(where: { $0.id == store.activeId })
        else {
            throw BrineStepError("the persisted list holds no conversation \(store.activeId)")
        }
        return convo.messages.map(\.text).joined(separator: "\n")
    }
}

/// Carries the probe closure onto its own `Thread`. The closure touches the store and the
/// world, neither of which is `Sendable`; the hand-off is safe because this thread is the
/// only one running while the caller blocks on the semaphore.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - the steps

private enum ChatTurnSteps {
    // swiftlint:disable:next function_body_length
    static func make(world w: ChatTurnWorld) -> [StepDefinition] {
        [
            // ── Given ────────────────────────────────────────────────────────────────

            defineStep("I am signed in on this phone") { ctx, _, _ in
                try w.signIn()
                return ctx
            },
            defineStep("my computer cannot be reached") { ctx, _, _ in
                w.behaviour = .unreachable
                return ctx
            },
            defineStep("my computer answers") { ctx, _, _ in
                w.behaviour = .answers
                return ctx
            },
            defineStep("my computer answers but Kiln is not running") { ctx, _, _ in
                w.behaviour = .kilnNotRunning
                return ctx
            },
            defineStep("my computer cannot reach its own Kiln") { ctx, _, _ in
                w.behaviour = .kilnUnreachable
                return ctx
            },

            // ── When ─────────────────────────────────────────────────────────────────

            defineStep("I send a chat turn") { ctx, _, _ in
                try await w.sendTurn("what did we decide about the relay")
                return ctx
            },
            defineStep("account-scoped work does account-scoped work") { ctx, _, _ in
                try w.requireHealthy()
                let store = try w.requireStore()
                let binding = try w.requireBinding()
                try w.withinDeadline("account-scoped work nested in account-scoped work") {
                    // The OUTER gate is the caller's; the INNER one is the store's own
                    // `persist()`. This is the shape, verbatim, that froze the app.
                    w.innerRan = CaptureAccountScope.perform(as: binding) { _ in
                        store.setMessages(
                            [.init(role: "user", text: "nested")], for: store.activeId)
                        return true
                    } == true
                }
                return ctx
            },
            defineStep("account-scoped work from a superseded account "
                       + "does account-scoped work") { ctx, _, _ in
                try w.requireHealthy()
                let store = try w.requireStore()
                let live = try w.requireBinding()
                // A binding whose generation the gate has moved past. It must be REFUSED,
                // and refusing must not hang either.
                let stale = CaptureAccountScope.AccountBinding(
                    root: live.root, scope: live.scope,
                    generation: live.generation &+ 1,
                    admissionEpoch: live.admissionEpoch,
                    admissionCell: live.admissionCell)
                try w.withinDeadline("a superseded account's nested write") {
                    w.innerRan = CaptureAccountScope.perform(as: stale) { _ in
                        store.setMessages(
                            [.init(role: "user", text: "stale")], for: store.activeId)
                        return true
                    } == true
                }
                return ctx
            },

            // ── Then ─────────────────────────────────────────────────────────────────

            defineStep("the turn ends") { ctx, _, _ in
                guard w.composerFree else {
                    throw BrineStepError("the turn never returned — the composer is still gone")
                }
                if case .connecting = w.model.connection {
                    throw BrineStepError(
                        "the turn is still shown as connecting — it did not end")
                }
                return ctx
            },
            defineStep("the composer is mine again") { ctx, _, _ in
                guard w.composerFree else {
                    throw BrineStepError("the composer never came back")
                }
                return ctx
            },
            defineStep("the thread says my computer couldn't be reached") { ctx, _, _ in
                try expectThread(w, contains: ChatSendFailure.unreachable)
                return ctx
            },
            defineStep("the thread says Kiln isn't running on my computer") { ctx, _, _ in
                try expectThread(w, contains: ChatSendFailure.kilnNotRunning)
                try refuseThread(w, contains: ChatSendFailure.tryAgain)
                return ctx
            },
            defineStep("the thread says my computer couldn't reach Kiln") { ctx, _, _ in
                try expectThread(w, contains: ChatSendFailure.kilnUnreachable)
                try refuseThread(w, contains: ChatSendFailure.tryAgain)
                return ctx
            },
            defineStep("my chat history holds the reply") { ctx, _, _ in
                let text = try w.historyText()
                guard text.contains("the door answered") else {
                    throw BrineStepError(
                        "the persisted history does not hold the reply — it holds: \(text)")
                }
                return ctx
            },
            // Opening the turn belongs to the turn. When the screen ALSO opened it — which
            // is exactly what the extraction of `PhoneChatTurn` briefly made true — the
            // reader's own sentence appeared in the thread twice.
            defineStep("what I asked appears once, not twice") { ctx, _, _ in
                let asked = "what did we decide about the relay"
                let mine = w.model.snapshot().filter { $0.role == "user" && $0.text == asked }
                guard mine.count == 1 else {
                    throw BrineStepError(
                        "what I asked appears \(mine.count) time(s) in the thread, not once")
                }
                let persisted = try w.historyText()
                    .components(separatedBy: asked).count - 1
                guard persisted == 1 else {
                    throw BrineStepError(
                        "what I asked was persisted \(persisted) time(s), not once")
                }
                return ctx
            },
            defineStep("my chat history holds what I asked") { ctx, _, _ in
                let text = try w.historyText()
                guard text.contains("what did we decide about the relay") else {
                    throw BrineStepError(
                        "a failed turn lost what I asked — the history holds: \(text)")
                }
                return ctx
            },
            defineStep("the inner work runs") { ctx, _, _ in
                guard w.innerRan else {
                    throw BrineStepError("the nested account-scoped work never ran")
                }
                let text = try w.historyText()
                guard text.contains("nested") else {
                    throw BrineStepError(
                        "the nested write returned but persisted nothing — history: \(text)")
                }
                return ctx
            },
            defineStep("the work is refused") { ctx, _, _ in
                guard !w.innerRan else {
                    throw BrineStepError(
                        "a superseded account was allowed to write into the current one")
                }
                return ctx
            },
            defineStep("the screen was never blocked") { ctx, _, _ in
                guard !w.wedged else {
                    throw BrineStepError("the account gate deadlocked")
                }
                return ctx
            },
        ]
    }

    private static func expectThread(_ w: ChatTurnWorld, contains needle: String) throws {
        guard w.threadText.contains(needle) else {
            throw BrineStepError(
                "the thread does not say \"\(needle)\" — it says: \(w.threadText)")
        }
    }

    private static func refuseThread(_ w: ChatTurnWorld, contains needle: String) throws {
        if w.threadText.contains(needle) {
            throw BrineStepError(
                "the thread says \"\(needle)\", which is the wrong advice here — "
                    + "it says: \(w.threadText)")
        }
    }
}
