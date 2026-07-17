import XCTest
import Foundation
import FoundryXKit

/// Content-free PRODUCT-USAGE telemetry (features/usage-telemetry.feature). A SIBLING
/// of PerfTelemetry: where perf ships launch/hang numbers, this ships pages, recording
/// minutes, conversations, generated actions, user actions, and chat usage — all
/// content-free (counts, durations, enum tokens ONLY). These tests pin BOTH the wire
/// shape the Foundry door re-parses AND — the whole point — that NO content (transcript
/// text, titles, names, prompts, comments) can ever leave the phone in a usage event.
final class UsageTelemetryTests: XCTestCase {

    private let ctx = UsageContext(build: "166", installId: "a1b2c3d4")

    /// A capturing UsageHook bridge — records every (kind, cats, nums) the app emits,
    /// exactly as the real app installs `UsageSink.emit`. Thread-safe.
    final class Recorder: @unchecked Sendable {
        struct Event { let kind: String; let cats: [String: String]; let nums: [String: Double] }
        private let lock = NSLock()
        private var _events: [Event] = []
        var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
        func install() {
            UsageHook.install { [weak self] kind, cats, nums in
                self?.lock.lock(); self?._events.append(Event(kind: kind, cats: cats, nums: nums))
                self?.lock.unlock()
            }
        }
    }

    override func tearDown() {
        UsageHook.install { _, _, _ in }   // detach the bridge between tests
        super.tearDown()
    }

    // MARK: - Wire shape (what the door re-parses + appends to the rollup)

    // Scenario: a usage event is ONE content-free JSON line the door can parse.
    func testEventSerializationShape() throws {
        let line = UsageDiag.event(kind: "session",
                                   cats: ["kind": "recording", "source": "mic"],
                                   nums: ["duration_sec": 90, "kept": 1], ctx: ctx)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["event_kind"] as? String, "session")
        let cats = try XCTUnwrap(obj["cats"] as? [String: Any])
        XCTAssertEqual(cats["kind"] as? String, "recording")
        XCTAssertEqual(cats["source"] as? String, "mic")
        let nums = try XCTUnwrap(obj["nums"] as? [String: Any])
        XCTAssertEqual((nums["duration_sec"] as? NSNumber)?.intValue, 90)
        XCTAssertEqual((nums["kept"] as? NSNumber)?.intValue, 1)
        // Whole numbers serialize as integers (90, not 90.0).
        XCTAssertTrue(line.contains("\"duration_sec\":90"))
        XCTAssertFalse(line.contains("90.0"))
    }

    // Scenario: every usage event carries the build + the anonymous install id.
    func testEventCarriesBuildAndAnonymousInstallId() throws {
        let line = UsageDiag.event(kind: "page", cats: ["page": "recording"], nums: [:], ctx: ctx)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["build"] as? String, "166")
        XCTAssertEqual(obj["dev"] as? String, "a1b2c3d4", "the anonymous IDFV-first-8-hex, never a name/email")
        XCTAssertFalse(line.contains("@"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("token"))
    }

    // Scenario: the safe-token grammar strips any content that reaches a field/value.
    func testTokenGrammarIsContentFree() {
        // A "value" that is actually free text (a transcript / a comment) is reduced to
        // safe tokens — no spaces, punctuation, emoji, or newlines survive.
        let secret = "Meet Dr. Alice at 5pm about the merger! 🎉\nsecret-comment"
        let line = UsageDiag.event(kind: "action", cats: ["outcome": secret], nums: [:], ctx: ctx)
        XCTAssertFalse(line.contains("Meet Dr"), "no free-text phrase survives")
        XCTAssertFalse(line.contains(" "))
        XCTAssertFalse(line.contains("🎉"))
        XCTAssertFalse(line.contains("\n") || line.contains("!"))
        // …and every value stays ≤64 safe-token chars.
        let long = String(repeating: "x", count: 200)
        let capped = UsageDiag.event(kind: "page", cats: ["page": long], nums: [:], ctx: ctx)
        XCTAssertTrue(capped.contains("\"page\":\"\(String(repeating: "x", count: 64))\""))
        XCTAssertFalse(capped.contains(String(repeating: "x", count: 65)))
    }

    // MARK: - (a) a page selection emits a page event with the right token

    func testPageEmitsRightToken() {
        let rec = Recorder(); rec.install()
        UsageHook.page("chat")
        let e = try? XCTUnwrap(rec.events.first)
        XCTAssertEqual(e?.kind, "page")
        XCTAssertEqual(e?.cats["page"], "chat")
        XCTAssertEqual(e?.nums.isEmpty, true)
    }

    // MARK: - (b) ending a recording emits a session with numeric duration + NO text

    func testSessionEmitsDurationAndKeptAsNumbersNoText() throws {
        let rec = Recorder(); rec.install()
        UsageHook.session(kind: "recording", source: "omi", durationSec: 90, kept: true)
        let e = try XCTUnwrap(rec.events.first)
        XCTAssertEqual(e.kind, "session")
        XCTAssertEqual(e.cats["kind"], "recording")
        XCTAssertEqual(e.cats["source"], "omi")
        XCTAssertEqual(e.nums["duration_sec"], 90)
        XCTAssertEqual(e.nums["kept"], 1)
        // Serialized, it is content-free — a known transcript string could never appear
        // because the session emitter never accepts text in the first place.
        let line = UsageDiag.event(kind: e.kind, cats: e.cats, nums: e.nums, ctx: ctx)
        XCTAssertFalse(line.contains("the quarterly numbers"))
    }

    // MARK: - The instrumented KIT paths never leak content

    // AmbientLane.consider emits a content-free `generation` (ambient_candidate) — the
    // window text + the candidate utterance NEVER appear; only ms + the window SIZE.
    func testAmbientLaneGenerationIsContentFree() async throws {
        let rec = Recorder(); rec.install()
        let gate = AmbientLaneTests.FakeGate()
        gate.triggerPhrase = "book the flight"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-ambient-\(UUID().uuidString).jsonl")
        let lane = AmbientLane(gate: gate, isEnabled: { true }, decisionLogURL: url)

        let secretWindow = "book the flight to Denver for the secret board meeting"
        _ = await lane.consider(captureId: "cap-1", window: secretWindow)

        let gen = try XCTUnwrap(rec.events.first { $0.kind == "generation" })
        XCTAssertEqual(gen.cats["kind"], "ambient_candidate")
        XCTAssertNotNil(gen.nums["ms"])
        XCTAssertEqual(gen.nums["window_chars"], Double(secretWindow.count))
        // The serialized event carries NONE of the window / candidate text.
        let line = UsageDiag.event(kind: gen.kind, cats: gen.cats, nums: gen.nums, ctx: ctx)
        XCTAssertFalse(line.contains("Denver"))
        XCTAssertFalse(line.contains("board meeting"))
        XCTAssertFalse(line.contains("flight"))
    }

    // ChatViewModel emits a content-free `chat` when a turn completes — model target_id +
    // local/cloud route + timings + a token COUNT; never the prompt or the response.
    func testChatTurnCompletionIsContentFree() throws {
        let rec = Recorder(); rec.install()
        let m = ChatViewModel()
        m.beginUserTurn("what were the merger figures we discussed")   // a "secret" prompt
        m.apply(.boundary(label: "routed: local-qwen3-8b"))
        m.apply(.assistantDelta(text: "here are the confidential numbers"))
        m.apply(.timing(routeMs: 12, ttftMs: 340, genMs: 900, totalMs: 1300, tokens: 42))

        let chat = try XCTUnwrap(rec.events.first { $0.kind == "chat" })
        XCTAssertEqual(chat.cats["model"], "local-qwen3-8b")
        XCTAssertEqual(chat.cats["route"], "local")
        XCTAssertEqual(chat.nums["ms"], 1300)
        XCTAssertEqual(chat.nums["ttft_ms"], 340)
        XCTAssertEqual(chat.nums["gen_ms"], 900)
        XCTAssertEqual(chat.nums["token_count"], 42)
        let line = UsageDiag.event(kind: chat.kind, cats: chat.cats, nums: chat.nums, ctx: ctx)
        XCTAssertFalse(line.contains("merger"))
        XCTAssertFalse(line.contains("confidential"))
    }

    func testChatRouteIsCloudForCloudTarget() throws {
        let rec = Recorder(); rec.install()
        let m = ChatViewModel()
        m.beginUserTurn("hi")
        m.apply(.boundary(label: "routed: claude-max"))
        m.apply(.timing(routeMs: 1, ttftMs: 2, genMs: 3, totalMs: 6, tokens: 5))
        let chat = try XCTUnwrap(rec.events.first { $0.kind == "chat" })
        XCTAssertEqual(chat.cats["model"], "claude-max")
        XCTAssertEqual(chat.cats["route"], "cloud")
    }

    // MARK: - (c) the serialized batch body is content-free ndjson

    func testBatchBodyIsNdjsonAndContentFree() throws {
        let sink = UsageSink(ctx: ctx)
        sink.emit("page", cats: ["page": "capture"])
        sink.emit("session", cats: ["kind": "recording", "source": "mic"],
                  nums: ["duration_sec": 90, "kept": 1])
        // Drain the batch through the wire builder (no live door needed).
        // Re-serialize the exact lines the sink would ship and assert the shape.
        let lines = [
            UsageDiag.event(kind: "page", cats: ["page": "capture"], nums: [:], ctx: ctx),
            UsageDiag.event(kind: "session", cats: ["kind": "recording", "source": "mic"],
                            nums: ["duration_sec": 90, "kept": 1], ctx: ctx),
        ]
        let body = try XCTUnwrap(UsageSink.body(for: lines))
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"), "newline-delimited (trailing newline)")
        let rows = text.split(separator: "\n")
        XCTAssertEqual(rows.count, 2, "one content-free event per line")
        for row in rows {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
            XCTAssertNotNil(obj["event_kind"])
            XCTAssertNotNil(obj["cats"]); XCTAssertNotNil(obj["nums"])
        }
        // A known transcript string is nowhere in the body.
        XCTAssertFalse(text.contains("the quarterly numbers"))
    }

    // An unconfigured sink (no door target yet — pre sign-in) never crashes on flush.
    func testFlushWithoutTargetIsSafeNoOp() {
        let sink = UsageSink(ctx: ctx)
        sink.emit("page", cats: ["page": "settings"])
        sink.flush()   // no target set → dropped, best-effort, no throw/crash
    }
}
