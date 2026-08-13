import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Local-first onboarding (track 20260705T1100), Phase 1: the append-only capture
/// event log + the CaptureBackend brain seam. Two layers:
///  - Plain XCTest unit assertions on the real CaptureEventLog (append order, seq
///    recovery, tolerance) and the on-change emission from the card store.
///  - A HERMETIC Brine run of the `@phase1` scenarios in
///    `features/local-first-onboarding.feature`, driving a REAL CaptureManager on a
///    temp dir (stubbed door I/O) — the same wiring the app runs.
final class LocalFirstOnboardingTests: ProcessGlobalStateTestCase {

    private func tempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-eventlog-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: unit — the append-only log itself

    func testAppendsReplayInOrderWithStrictlyIncreasingSeq() throws {
        let dir = try tempDir("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        CaptureEventLog.append(.captureStarted, captureId: "c1", baseDir: dir)
        CaptureEventLog.append(.transcriptSet, captureId: "c1",
                               payload: ["source": "provisional"], baseDir: dir)
        CaptureEventLog.append(.titleSet, captureId: "c1", payload: ["title": "Standup"], baseDir: dir)

        let events = CaptureEventLog.events(baseDir: dir)
        XCTAssertEqual(events.map(\.kind), ["capture_started", "transcript_set", "title_set"])
        XCTAssertEqual(events.map(\.seq), [1, 2, 3], "seq is strictly increasing in append order")
        XCTAssertEqual(events[2].payload["title"], "Standup")
        XCTAssertTrue(events.allSatisfy { $0.captureId == "c1" })
    }

    func testAppendNeverRewritesPriorLines() throws {
        let dir = try tempDir("immutability")
        defer { try? FileManager.default.removeItem(at: dir) }
        CaptureEventLog.append(.captureStarted, captureId: "c1", baseDir: dir)
        let url = dir.appendingPathComponent("events.jsonl")
        let firstLine = try String(contentsOf: url, encoding: .utf8)

        CaptureEventLog.append(.captureFinalized, captureId: "c1", baseDir: dir)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(firstLine),
                      "appending must leave every prior byte untouched (append-only)")
    }

    func testSeqRecoversAcrossProcessRestart() throws {
        // A "restart" = the in-memory counter knows nothing; the log must recover the
        // sequence from disk, never restart at 1. Simulate with a pre-existing file.
        let dir = try tempDir("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let existing = """
        {"seq":41,"ts":1,"kind":"capture_started","capture_id":"old","payload":{}}
        {"seq":42,"ts":2,"kind":"capture_finalized","capture_id":"old","payload":{}}

        """
        try existing.data(using: .utf8)!.write(to: url)

        CaptureEventLog.append(.captureStarted, captureId: "new", baseDir: dir)
        let events = CaptureEventLog.events(baseDir: dir)
        XCTAssertEqual(events.last?.seq, 43, "sequence continues from the on-disk log")
        XCTAssertEqual(events.count, 3)
    }

    func testTornLineIsSkippedNotFatal() throws {
        let dir = try tempDir("torn")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("events.jsonl")
        let torn = """
        {"seq":1,"ts":1,"kind":"capture_started","capture_id":"c1","payload":{}}
        {"seq":2,"ts":2,"kind":"title_
        """
        try torn.data(using: .utf8)!.write(to: url)
        let events = CaptureEventLog.events(baseDir: dir)
        XCTAssertEqual(events.count, 1, "a torn tail line is skipped, the log stays readable")
        XCTAssertEqual(events[0].kind, "capture_started")
    }

    // MARK: unit — on-change emission from the card store (the poller choke point)

    func testCardMergeAppendsTitleAndSummaryOnChangeOnly() throws {
        let dir = try tempDir("merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = ConversationCardStore.merge(captureId: "c1", baseDir: dir,
                                        title: "Standup", summary: "Discussed the relay")
        // Re-poll with IDENTICAL content — must not grow the log.
        _ = ConversationCardStore.merge(captureId: "c1", baseDir: dir,
                                        title: "Standup", summary: "Discussed the relay")
        var kinds = CaptureEventLog.events(baseDir: dir).map(\.kind)
        XCTAssertEqual(kinds, ["title_set", "summary_set"],
                       "an unchanged re-poll appends nothing")

        // A real change appends again (history, not a mutable cell).
        _ = ConversationCardStore.merge(captureId: "c1", baseDir: dir, title: "Monday standup")
        kinds = CaptureEventLog.events(baseDir: dir).map(\.kind)
        XCTAssertEqual(kinds, ["title_set", "summary_set", "title_set"])
    }

    // MARK: unit — the brain seam

    func testDoorClientIsACaptureBackend() {
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let backend: CaptureBackend = DoorClient(target: target)
        XCTAssertNotNil(backend, "DoorClient satisfies the CaptureBackend brain seam")
    }

    // MARK: hermetic brine — wire the @phase1 scenarios to the real pipeline

    func testPhase1OnboardingScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url.appendingPathComponent("features/local-first-onboarding.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        // One lane per implemented phase tag (TagFilter's include is AND semantics,
        // so a combined include would match nothing).
        for tag in ["@phase1", "@phase2", "@phase3", "@phase4", "@phase6", "@phase7"] {
            let world = OnboardingWorld()
            let registry = StepRegistry(OnboardingSteps.make(world: world))

            var collected: [JSONValue] = []
            let result = try await Resources.run(parsed.features, registry: registry, resources: [],
                                                 tagFilter: TagFilter(include: [tag]),
                                                 collector: { collected.append($0) })

            var failures: [String] = []
            for ev in collected {
                guard case .object(let o) = ev,
                      case .string("scenario_end")? = o["type"],
                      case .string(let status)? = o["status"], status != "passed" else { continue }
                let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
                let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
                failures.append("[\(status)] \(name): \(err)")
            }
            XCTAssertTrue(failures.isEmpty, "\(tag) scenarios failed:\n" + failures.joined(separator: "\n"))
            XCTAssertEqual(result.failed, 0)
            let tagged = parsed.features[0].scenarios.filter { $0.tags.contains(tag) }.count
            XCTAssertEqual(result.passed, tagged, "every \(tag) scenario runs and passes")
            XCTAssertGreaterThan(result.passed, 0, "the \(tag) lane must not be empty")
        }
    }
}

// MARK: - Brine world + steps (real CaptureManager, stubbed door I/O)

final class OnboardingWorld: @unchecked Sendable {
    var dir: URL!
    var signedIn = false
    /// Events snapshotted mid-flow (after recording, before brain results) so the
    /// append-only check can prove the prefix never changed.
    var midSnapshot: [CaptureEvent] = []
    var captureId = ""
    // Held so the real manager + its source outlive the recording step (only ever
    // touched from MainActor.run blocks).
    var manager: CaptureManager?
    var source: OnboardingSteps.TestSource?
    /// @phase2: "no brain is connected" — finalize runs through a LocalBackend
    /// (on-device STT) instead of the stubbed door.
    var localOnly = false
    var localBackend: LocalBackend?
    var fakeSTT: OnboardingFakeSTT?
    var chatAnswer = ""
    var chatDrewOn: [String] = []
    // @phase6/7 routing + seed state
    var gateSignedIn = false
    var gateDest: RootDestination = .signInGate
    var brains: BrainStore?
    var brainDefaults: UserDefaults?
    var rearmedCount = 0
}

/// The Phase 2 STT seam fake — LocalBackend's pipeline is real, only the speech
/// engine is substituted (WhisperKit isn't runnable in CI).
final class OnboardingFakeSTT: LocalSTT, @unchecked Sendable {
    var isAvailable: Bool { true }
    var framesSeen = 0
    func transcribe(opusFrames: [Data]) async throws -> String {
        framesSeen = opusFrames.count
        return "on-device transcript of \(opusFrames.count) frames"
    }
}

/// The Phase 3 title/summary seam fake (Foundation Models isn't runnable in CI).
final class OnboardingFakeTitler: LocalTitleSummary, @unchecked Sendable {
    var isAvailable: Bool { true }
    func titleAndSummary(for transcript: String) async throws -> (title: String, summary: String) {
        ("Kitchen catch-up", "A short chat, transcribed on the phone.")
    }
}

enum OnboardingSteps {
    struct StepError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// SettingsScreen must OWN both cloud rows through the pure rules, not inline
    /// conditions. `swift test` compiles the SPM package only — it cannot see `App/` —
    /// so the wiring is held by reading the file's CODE (comments stripped, string
    /// literals blanked: prose naming the rule is not a call to it).
    static func assertSettingsRendersTheCloudRows() throws {
        for rule in ["VaultSettingsPresentation.showWaitlist(",
                     "VaultSettingsPresentation.showCellBrain("] {
            let callers = try AppSourceTree.filesContaining(rule)
            guard callers.contains("App/SettingsScreen.swift") else {
                throw StepError(
                    "App/SettingsScreen.swift does not call \(rule)…) — the BRAIN section's "
                        + "cloud row is not driven by the tested rule. Found in: \(callers)")
            }
        }
    }

    /// The controllable source (same shape as CaptureAmbientTests.TestSource).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    static func make(world: OnboardingWorld) -> [StepDefinition] {
        [
            defineStep("I have signed in") { ctx, _, _ in
                // Scenario reset point (each scenario begins signed-in on a fresh store).
                world.signedIn = true
                world.localOnly = false
                world.localBackend = nil
                world.fakeSTT = nil
                world.manager = nil
                world.source = nil
                world.midSnapshot = []
                world.captureId = ""
                world.dir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("foundryx-onboarding-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: world.dir, withIntermediateDirectories: true)
                return ctx
            },

            defineStep("I record a conversation and stop") { ctx, _, _ in
                guard world.signedIn else { throw StepError("not signed in") }
                let dir = world.dir!
                await MainActor.run {
                    let src = TestSource()
                    let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
                    let mgr: CaptureManager
                    if world.localOnly {
                        // @phase2 — the REAL LocalBackend is the brain; only its STT
                        // engine is faked.
                        let stt = OnboardingFakeSTT()
                        let backend = LocalBackend(baseDir: dir, stt: stt,
                                                   titler: OnboardingFakeTitler())
                        world.fakeSTT = stt
                        world.localBackend = backend
                        mgr = CaptureManager(target: target, backend: backend,
                                             baseDir: dir, source: src,
                                             localMode: true)
                    } else {
                        // Real CaptureManager; the brain round-trips are stubbed at
                        // the SAME seams the app wires (finalize + per-segment upload).
                        mgr = CaptureManager(
                            target: target, baseDir: dir, source: src,
                            finalize: { _, _ in },                    // brain accepts the capture
                            uploadSegment: { _, _, _ in }             // every segment ACKs instantly
                        )
                    }
                    world.manager = mgr
                    world.source = src
                    src.onState?(.streaming)                      // ambient: arm for speech
                }
                let armDeadline = Date().addingTimeInterval(3)
                while await MainActor.run(
                    body: {
                        world.manager?.isListeningForSpeechForTests != true
                    })
                {
                    if Date() > armDeadline {
                        throw StepError("capture source never reached streaming")
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                _ = await MainActor.run {
                    RealOmiFrames.openSession(world.source?.onFrame)
                }
                // The speech onset → beginSession hop is async — wait for the session
                // like the ambient lifecycle test does.
                let startDeadline = Date().addingTimeInterval(3)
                while await MainActor.run(body: { world.manager?.active == nil }) {
                    if Date() > startDeadline { throw StepError("capture did not auto-start") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try await MainActor.run { () throws -> Void in
                    guard let mgr = world.manager, let src = world.source,
                          let wal = mgr.active else { throw StepError("no active capture") }
                    // Real voiced Opus packets — the substance gate must see actual
                    // voice or the fragment is (correctly) discarded, not finalized.
                    let voiced = RealOmiFrames.voiced()
                    for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { src.onFrame?(voiced) }
                    world.captureId = wal.captureId
                    wal.flushAndWait()
                    src.onState?(.stopped)
                }
                // The stop → reconnect-grace suspension hops the main actor too;
                // wait for it before elapsing the grace (same as the ambient test).
                let stopDeadline = Date().addingTimeInterval(3)
                while await MainActor.run(body: { world.manager?.isAwaitingReconnect != true }) {
                    if Date() > stopDeadline { throw StepError("capture never suspended after stop") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                await MainActor.run {
                    world.manager?.resolveReconnectGrace(
                        now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
                }
                let endDeadline = Date().addingTimeInterval(3)
                while await MainActor.run(body: { world.manager?.active != nil }) {
                    if Date() > endDeadline { throw StepError("session never ended") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                // Segments durably on the desktop (door-free ACK, the finalize-test
                // pattern), then the pending-finalize sweep closes the capture.
                let cdir = dir.appendingPathComponent(world.captureId, isDirectory: true)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: cdir, includingPropertiesForKeys: nil)) ?? []
                for f in files where f.pathExtension == "opus" {
                    try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"),
                                      options: [.atomic])
                }
                if let mgr = world.manager { await mgr.retryPendingFinalizes() }
                world.midSnapshot = CaptureEventLog.events(baseDir: dir)

                if !world.localOnly {
                    // Door brain reports back: transcript content lands in the cache…
                    TranscriptCacheStore.save(
                        CachedTranscript(transcript: "we talked about the relay deploy",
                                         title: nil, summary: nil, fetchedAt: 1),
                        captureId: world.captureId, baseDir: dir)
                    // …and a status poll merges the authoritative title + summary
                    // (the exact call CaptureStatusPoller makes).
                    _ = ConversationCardStore.merge(captureId: world.captureId, baseDir: dir,
                                                    title: "Relay deploy chat",
                                                    summary: "Shipped the account endpoints")
                }
                return ctx
            },

            defineCheck("the capture, transcript, title, and summary are appended to the local event log") { _, _, _ in
                let kinds = CaptureEventLog.events(baseDir: world.dir).map(\.kind)
                for expected in ["capture_started", "capture_finalized",
                                 "transcript_set", "title_set", "summary_set"] {
                    guard kinds.contains(expected) else {
                        throw StepError("missing \(expected) in event log; got \(kinds)")
                    }
                }
            },

            defineStep("no brain is connected") { ctx, _, _ in
                world.localOnly = true
                return ctx
            },

            // Hermetically the local lane makes zero network calls by construction;
            // the REAL airplane-mode acceptance is the on-device e2e.
            defineStep("the phone has no network connection") { ctx, _, _ in
                world.localOnly = true
                return ctx
            },

            defineCheck("it receives an on-device title and summary") { _, _, _ in
                guard let backend = world.localBackend else { throw StepError("no local backend") }
                let status = try await backend.captureStatus(captureId: world.captureId)
                guard status.title == "Kitchen catch-up",
                      status.summary == "A short chat, transcribed on the phone." else {
                    throw StepError("title/summary missing: \(String(describing: status.title))")
                }
            },

            defineCheck("it appears as a browsable conversation card") { _, _, _ in
                guard let card = ConversationCardStore.load(captureId: world.captureId,
                                                            baseDir: world.dir),
                      card.title?.isEmpty == false else {
                    throw StepError("no browsable card with a title")
                }
                let visible = await MainActor.run {
                    world.manager?.visibleCaptures.contains { $0.captureId == world.captureId } ?? false
                }
                guard visible else { throw StepError("conversation not in the visible timeline") }
            },

            defineCheck("the conversation is transcribed on-device") { _, _, _ in
                // finalize runs on a detached task after the stop step — poll briefly
                // instead of racing it (the flake: "on-device STT never ran" under load).
                for _ in 0..<100 where (world.fakeSTT?.framesSeen ?? 0) == 0 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard let stt = world.fakeSTT, stt.framesSeen > 0 else {
                    throw StepError("on-device STT never ran")
                }
                let cached = TranscriptCacheStore.load(captureId: world.captureId, baseDir: world.dir)
                guard cached?.transcript == "on-device transcript of \(stt.framesSeen) frames" else {
                    throw StepError("transcript not persisted: \(String(describing: cached?.transcript))")
                }
            },

            defineCheck("the transcript is readable on the conversation") { _, _, _ in
                guard let backend = world.localBackend else { throw StepError("no local backend") }
                let content = try await backend.captureContent(captureId: world.captureId)
                guard content.found, !content.transcript.isEmpty else {
                    throw StepError("content not readable: found=\(content.found)")
                }
                let status = try await backend.captureStatus(captureId: world.captureId)
                guard status.transcribed else { throw StepError("status not transcribed") }
            },

            defineCheck("the transcript is recorded in the local event log") { _, _, _ in
                let kinds = CaptureEventLog.events(baseDir: world.dir).map(\.kind)
                guard kinds.contains("transcript_set") else {
                    throw StepError("no transcript_set in event log: \(kinds)")
                }
            },

            // ── @phase4: whole-library local chat ────────────────────────────
            defineStep("I have several transcribed conversations") { ctx, _, _ in
                for (i, text) in ["we planted tomatoes by the fence",
                                  "the tomatoes joke at standup",
                                  "sandwiches only"].enumerated() {
                    let id = "chat-c\(i)"
                    ConversationCardStore.save(
                        .init(title: "Convo \(i)", summary: nil, stage: "ready",
                              updatedAt: 1, startedAt: UInt64(100 + i)),
                        captureId: id, baseDir: world.dir)
                    TranscriptCacheStore.save(
                        CachedTranscript(transcript: text, title: nil, summary: nil, fetchedAt: 1),
                        captureId: id, baseDir: world.dir)
                }
                return ctx
            },

            defineStep("I ask a question in chat that spans multiple conversations") { ctx, _, _ in
                final class Echo: LocalChatModel, @unchecked Sendable {
                    var isAvailable: Bool { true }
                    func respond(to prompt: String) async throws -> String { "they came up twice" }
                }
                let engine = LocalChatEngine(baseDir: world.dir, model: Echo())
                let (text, drewOn) = try await engine.answer("what did we say about tomatoes?")
                world.chatAnswer = text
                world.chatDrewOn = drewOn
                return ctx
            },

            defineCheck("the answer draws on more than the open conversation") { _, _, _ in
                guard world.chatDrewOn.count > 1 else {
                    throw StepError("answer drew on \(world.chatDrewOn) — not cross-conversation")
                }
                guard !world.chatAnswer.isEmpty else { throw StepError("empty answer") }
            },

            defineCheck("a persistent honesty notice says answers run entirely on my phone and may be inaccurate") { _, _, _ in
                let n = LocalChatPresentation.honestyNotice
                guard n.contains("entirely on your phone"), n.contains("inaccurate") else {
                    throw StepError("honesty notice missing the locked copy: \(n)")
                }
            },

            defineCheck("a join-the-waitlist button is present on the chat surface") { _, _, _ in
                guard LocalChatPresentation.waitlistButtonTitle == "Join the waitlist" else {
                    throw StepError("waitlist button contract broken")
                }
            },

            // ── @phase6: sign-in-first gate + brain picker default ───────────
            defineStep("a fresh install that has never signed in") { ctx, _, _ in
                world.gateSignedIn = false
                world.brainDefaults = UserDefaults(suiteName: "brine-brain-\(UUID().uuidString)")
                world.brains = BrainStore(defaults: world.brainDefaults!)
                world.dir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("foundryx-gate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: world.dir, withIntermediateDirectories: true)
                return ctx
            },

            defineStep("I launch the app") { ctx, _, _ in
                world.gateDest = RootGate.destination(signedIn: world.gateSignedIn,
                                                      splashElapsed: true,
                                                      brain: world.brains?.choice ?? .justMyPhone,
                                                      hostResolved: false)
                return ctx
            },

            defineCheck("I am asked to sign in with Apple, Google, or Microsoft") { _, _, _ in
                guard world.gateDest == .signInGate else {
                    throw StepError("expected the sign-in gate, got \(world.gateDest)")
                }
                let auth = FoundryAuth(config: OAuthConfig(googleClientID: "g",
                                                           microsoftClientID: "m",
                                                           microsoftTenant: "organizations"))
                let offered = AuthProvider.allCases.filter { auth.isConfigured($0) }
                guard offered == [.apple, .google, .microsoft] else {
                    throw StepError("providers offered: \(offered) — Apple must lead")
                }
            },

            defineCheck("I cannot reach capture or chat until I sign in") { _, _, _ in
                for brain in BrainChoice.allCases {
                    for host in [true, false] {
                        guard RootGate.destination(signedIn: false, splashElapsed: true,
                                                   brain: brain, hostResolved: host) == .signInGate else {
                            throw StepError("unsigned route escaped the gate (brain=\(brain) host=\(host))")
                        }
                    }
                }
            },

            defineStep("I open the brain picker in settings") { ctx, _, _ in
                if world.brains == nil {
                    world.brainDefaults = UserDefaults(suiteName: "brine-brain-\(UUID().uuidString)")
                    world.brains = BrainStore(defaults: world.brainDefaults!)
                }
                return ctx
            },

            defineCheck("{string} is the current choice") { _, p, _ in
                let want = try p.requireString(0)
                guard world.brains?.choice.label == want else {
                    throw StepError("current brain is \(world.brains?.choice.label ?? "?"), wanted \(want)")
                }
            },

            defineCheck("{string} is offered for pairing with the desktop app") { _, p, _ in
                let want = try p.requireString(0)
                guard BrainChoice.allCases.map(\.label).contains(want) else {
                    throw StepError("\(want) not among brain choices")
                }
            },

            defineCheck("{string} is shown as coming soon with a waitlist") { _, p, _ in
                _ = try p.requireString(0)
                // The Cloud row is UI (SettingsScreen); its contract here is that the
                // waitlist verb exists on the account surface.
                guard LocalChatPresentation.waitlistButtonTitle == "Join the waitlist" else {
                    throw StepError("waitlist affordance contract broken")
                }
                // …and that the row this scenario names is the one SettingsScreen actually
                // draws for an unentitled owner. Asserting only the verb string was a null
                // assertion: it stayed green with no cloud row in SettingsScreen at all.
                guard VaultSettingsPresentation.showWaitlist(entitlement: .off) else {
                    throw StepError("the waitlist row is no longer shown to an off Vault")
                }
                try Self.assertSettingsRendersTheCloudRows()
            },

            // ── @phase6: the Vault as a pickable brain, once it is live ──────
            defineCheck("{string} is not a brain I can choose until my Vault is live") { _, p, _ in
                let want = try p.requireString(0)
                guard want == BrainChoice.foundryCloud.label else {
                    throw StepError("\(want) is not the cloud brain's label")
                }
                for entitlement in [VaultEntitlement.off, .unknown] {
                    guard !VaultSettingsPresentation.showCellBrain(entitlement: entitlement) else {
                        throw StepError(
                            "the Vault brain is offered at entitlement \(entitlement) — a brain "
                                + "with no Vault behind it")
                    }
                }
            },

            defineCheck("once my Vault is live {string} is a brain I can choose in settings") { _, p, _ in
                let want = try p.requireString(0)
                guard want == BrainChoice.foundryCloud.label else {
                    throw StepError("\(want) is not the cloud brain's label")
                }
                guard VaultSettingsPresentation.showCellBrain(entitlement: .live) else {
                    throw StepError("a live Vault is still not offered as a brain")
                }
                // The rule existing is not the row existing. `swift test` cannot compile
                // App/, so this reads it: SettingsScreen must consult the rule AND draw a
                // SELECTABLE row (brainRow is the only thing that calls brains.select).
                try Self.assertSettingsRendersTheCloudRows()
                let selectable = try AppSourceTree.filesContaining("brainRow(.foundryCloud")
                guard selectable.contains("App/SettingsScreen.swift") else {
                    throw StepError(
                        "SettingsScreen never draws a SELECTABLE Solleva Cloud row "
                            + "(brainRow(.foundryCloud …) is what calls brains.select) — "
                            + "found in: \(selectable)")
                }
            },

            defineCheck("the coming-soon waitlist and the live Vault brain are never shown together") { _, _, _ in
                for entitlement in [VaultEntitlement.off, .live, .unknown] {
                    let waitlist = VaultSettingsPresentation.showWaitlist(entitlement: entitlement)
                    let brain = VaultSettingsPresentation.showCellBrain(entitlement: entitlement)
                    guard !(waitlist && brain) else {
                        throw StepError(
                            "entitlement \(entitlement) shows BOTH the waitlist and the Vault brain")
                    }
                }
            },

            // ── @phase7: replay-seed + additive disconnect ───────────────────
            defineStep("I have transcribed conversations recorded phone-only") { ctx, _, _ in
                for i in 0..<2 {
                    let id = "seed-c\(i)"
                    let cdir = world.dir.appendingPathComponent(id, isDirectory: true)
                    try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
                    try CaptureWAL.encodeSegment([Data([UInt8(i), 9])])
                        .write(to: cdir.appendingPathComponent(CaptureWAL.segName(0)))
                    try Data().write(to: cdir.appendingPathComponent("seg-000000000000.ack"))
                    TranscriptCacheStore.save(
                        CachedTranscript(transcript: "phone-only words \(i)", title: nil,
                                         summary: nil, fetchedAt: 1),
                        captureId: id, baseDir: world.dir, markConfirmed: false)
                }
                return ctx
            },

            defineStep("I connect my computer as the brain") { ctx, _, _ in
                world.rearmedCount = BrainSeeder.rearmForDoorSeed(baseDir: world.dir)
                return ctx
            },

            defineCheck("my local conversations are seeded into the brain by replaying the event log") { _, _, _ in
                guard world.rearmedCount == 2 else {
                    throw StepError("expected 2 conversations re-queued for the door, got \(world.rearmedCount)")
                }
                for i in 0..<2 {
                    let cdir = world.dir.appendingPathComponent("seed-c\(i)")
                    guard FileManager.default.fileExists(atPath: cdir.appendingPathComponent(".needs-finalize").path),
                          !FileManager.default.fileExists(atPath: cdir.appendingPathComponent("seg-000000000000.ack").path) else {
                        throw StepError("seed-c\(i) not re-armed for the door drain")
                    }
                }
            },

            defineCheck("my local conversations remain readable on the phone") { _, _, _ in
                for i in 0..<2 {
                    guard TranscriptCacheStore.load(captureId: "seed-c\(i)", baseDir: world.dir)?
                        .transcript == "phone-only words \(i)" else {
                        throw StepError("seed-c\(i) transcript lost during seeding")
                    }
                }
            },

            defineStep("my computer is connected as the brain") { ctx, _, _ in
                world.brainDefaults = UserDefaults(suiteName: "brine-brain-\(UUID().uuidString)")
                world.brains = BrainStore(defaults: world.brainDefaults!, hasPairedDesktop: true)
                return ctx
            },

            defineStep("my conversations have been enriched by the brain") { ctx, _, _ in
                for i in 0..<2 {
                    let id = "rich-c\(i)"
                    TranscriptCacheStore.save(
                        CachedTranscript(transcript: "enriched \(i)", title: "T\(i)",
                                         summary: "S\(i)", fetchedAt: 1),
                        captureId: id, baseDir: world.dir)   // Lore-confirmed
                    _ = ConversationCardStore.merge(captureId: id, baseDir: world.dir,
                                                    title: "T\(i)", summary: "S\(i)")
                }
                return ctx
            },

            defineStep("I disconnect the brain") { ctx, _, _ in
                world.brains?.select(.justMyPhone)
                world.gateDest = RootGate.destination(signedIn: true, splashElapsed: true,
                                                      brain: world.brains!.choice,
                                                      hostResolved: false)
                return ctx
            },

            defineCheck("all my conversations are still readable on the phone") { _, _, _ in
                guard world.gateDest == .phoneBrain else {
                    throw StepError("disconnect should land on the phone brain, got \(world.gateDest)")
                }
                for i in 0..<2 {
                    guard TranscriptCacheStore.load(captureId: "rich-c\(i)", baseDir: world.dir)?
                        .transcript == "enriched \(i)",
                          ConversationCardStore.load(captureId: "rich-c\(i)", baseDir: world.dir)?
                        .title == "T\(i)" else {
                        throw StepError("rich-c\(i) unreadable after disconnect")
                    }
                }
            },

            defineCheck("no prior event in the log is modified or deleted") { _, _, _ in
                let events = CaptureEventLog.events(baseDir: world.dir)
                let prefix = Array(events.prefix(world.midSnapshot.count))
                guard prefix == world.midSnapshot else {
                    throw StepError("earlier events changed after later appends")
                }
                let seqs = events.map(\.seq)
                guard seqs == seqs.sorted(), Set(seqs).count == seqs.count else {
                    throw StepError("seq not strictly increasing: \(seqs)")
                }
            },
        ]
    }
}
