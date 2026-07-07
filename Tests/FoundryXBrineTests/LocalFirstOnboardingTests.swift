import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Local-first onboarding (track 20260705T1100), Phase 1: the append-only capture
/// event log + the CaptureBackend brain seam. Two layers:
///  - Plain XCTest unit assertions on the real CaptureEventLog (append order, seq
///    recovery, tolerance) and the on-change emission from the card store.
///  - A HERMETIC Brine run of the `@phase1` scenarios in
///    `features/local-first-onboarding.feature`, driving a REAL CaptureManager on a
///    temp dir (stubbed door I/O) — the same wiring the app runs.
final class LocalFirstOnboardingTests: XCTestCase {

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
        for tag in ["@phase1", "@phase2"] {
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

enum OnboardingSteps {
    struct StepError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
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
                        let backend = LocalBackend(baseDir: dir, stt: stt)
                        world.fakeSTT = stt
                        world.localBackend = backend
                        mgr = CaptureManager(target: target, backend: backend,
                                             baseDir: dir, source: src)
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
                    src.onState?(.streaming)                      // ambient auto-start
                }
                // Auto-start hops the main actor — wait for the session like the
                // ambient lifecycle test does.
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

            defineCheck("the conversation is transcribed on-device") { _, _, _ in
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

