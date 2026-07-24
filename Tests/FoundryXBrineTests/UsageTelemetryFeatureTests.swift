import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/usage-telemetry.feature. Drives the REAL usage stream —
/// `UsageHook` typed emitters (page/session/generation/chat), the `UsageDiag` pure
/// serializer, and `UsageContext` — so the content-free guarantee (every value is a
/// count, a duration, or a safe token; build + anonymous install id on every event;
/// free text reduced to a capped safe token) is asserted against the exact wire shape
/// the door re-parses. Hermetic: no door, no network.
final class UsageTelemetryFeatureTests: XCTestCase {
    func testUsageTelemetryFeature() async throws {
        try await BrineFeatureRunner.run(
            "usage-telemetry",
            registry: StepRegistry(UsageTelemetrySteps.make(world: UsageTelemetryWorld())))
    }
}

private struct CapturedEvent { let kind: String; let cats: [String: String]; let nums: [String: Double] }

private final class UsageTelemetryWorld: @unchecked Sendable {
    let ctx = UsageContext(build: "288", installId: "a1b2c3d4")
    // Serial queue instead of NSLock — NSLock.lock/unlock is banned in async scopes.
    private let q = DispatchQueue(label: "foundryx.usage-telemetry-world")
    private var events: [CapturedEvent] = []
    var last: CapturedEvent? { q.sync { events.last } }
    /// The wire line for the last event, exactly as UsageSink ships it.
    var lastLine: String? { last.map { UsageDiag.event(kind: $0.kind, cats: $0.cats, nums: $0.nums, ctx: ctx) } }

    func wire() {
        q.sync { events = [] }
        UsageHook.install { [weak self] kind, cats, nums in
            guard let self else { return }
            self.q.sync { self.events.append(CapturedEvent(kind: kind, cats: cats, nums: nums)) }
        }
    }
    /// Stage an event directly (for the serializer scenario, which has no live emitter).
    func stage(_ e: CapturedEvent) { q.sync { events.append(e) } }
    /// The set of characters allowed in any serialized token value (UsageDiag.token grammar).
    static func isSafeToken(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy {
            ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")
                || $0 == "_" || $0 == "." || $0 == ":" || $0 == "-"
        }
    }
}

private enum UsageTelemetrySteps {
    static func make(world w: UsageTelemetryWorld) -> [StepDefinition] {
        [
            defineStep("the usage stream is wired") { ctx, _, _ in w.wire(); return ctx },
            defineStep("any usage event") { ctx, _, _ in w.wire(); UsageHook.page("capture"); return ctx },
            defineStep("a usage event whose value contains punctuation, spaces, and emoji") { ctx, _, _ in
                w.wire(); return ctx
            },

            defineStep("the user moves to the chat page") { ctx, _, _ in UsageHook.page("chat"); return ctx },
            defineStep("a recording session of 90 seconds ends and is kept") { ctx, _, _ in
                UsageHook.session(kind: "ambient", source: "omi", durationSec: 90, kept: true); return ctx
            },
            defineStep("the ambient lane generates a candidate from the live window") { ctx, _, _ in
                // The candidate + window are TEXT the call site holds; only the SIZE + timing
                // may be reported. The emitter's signature makes text impossible to pass.
                UsageHook.generation(kind: "ambient_candidate", ms: 42, extraNums: ["window_chars": 320]); return ctx
            },
            defineStep("a chat turn routed to a local model completes") { ctx, _, _ in
                UsageHook.chat(model: "qwen2.5-7b", route: "local", ms: 1200, ttftMs: 180, genMs: 1020, tokenCount: 256)
                return ctx
            },
            defineStep("it is serialized for shipping") { ctx, _, _ in
                // A caller passes a dirty free-text value; serialization must reduce it.
                let dirty = "Hello, world! 🎤 — this is a full sentence with spaces & punctuation and way more than sixty-four characters of content"
                w.stage(CapturedEvent(kind: "page", cats: ["page": dirty], nums: [:]))
                return ctx
            },

            defineCheck("a \"page\" event is emitted whose page token is \"chat\"") { _, _, _ in
                guard let e = w.last, e.kind == "page" else { throw BrineStepError("no page event, got \(String(describing: w.last?.kind))") }
                guard e.cats["page"] == "chat" else { throw BrineStepError("page token was \(String(describing: e.cats["page"]))") }
            },
            defineCheck("the event carries no content") { _, _, _ in
                guard let e = w.last else { throw BrineStepError("no event") }
                for (k, v) in e.cats where !(UsageTelemetryWorld.isSafeToken(k) && UsageTelemetryWorld.isSafeToken(v)) {
                    throw BrineStepError("cat \(k)=\(v) is not a safe token")
                }
                // nums are numbers by type — no text can ride them.
            },
            defineCheck("a \"session\" event is emitted with a numeric duration of 90 seconds") { _, _, _ in
                guard let e = w.last, e.kind == "session" else { throw BrineStepError("no session event") }
                guard e.nums["duration_sec"] == 90 else { throw BrineStepError("duration was \(String(describing: e.nums["duration_sec"]))") }
            },
            defineCheck("it carries the source and kept as tokens/numbers, never the transcript") { _, _, _ in
                guard let e = w.last else { throw BrineStepError("no event") }
                guard e.cats["source"] == "omi" else { throw BrineStepError("source missing/wrong") }
                guard e.nums["kept"] == 1 else { throw BrineStepError("kept not a number") }
                // No transcript field of any kind.
                guard e.cats["transcript"] == nil, e.cats["text"] == nil else { throw BrineStepError("a text field leaked") }
            },
            defineCheck("a \"generation\" event is emitted with a duration and the window SIZE") { _, _, _ in
                guard let e = w.last, e.kind == "generation" else { throw BrineStepError("no generation event") }
                guard e.nums["ms"] == 42 else { throw BrineStepError("no duration") }
                guard e.nums["window_chars"] == 320 else { throw BrineStepError("no window size") }
            },
            defineCheck("neither the window text nor the candidate text is present") { _, _, _ in
                guard let line = w.lastLine else { throw BrineStepError("no wire line") }
                for banned in ["window_text", "candidate", "utterance", "text"] {
                    guard !line.contains("\"\(banned)\":\"") else { throw BrineStepError("banned key \(banned) present") }
                }
            },
            defineCheck("a \"chat\" event is emitted with the model token, the local route, and timings") { _, _, _ in
                guard let e = w.last, e.kind == "chat" else { throw BrineStepError("no chat event") }
                guard e.cats["model"] == "qwen2.5-7b", e.cats["route"] == "local" else { throw BrineStepError("model/route wrong") }
                guard e.nums["ttft_ms"] == 180, e.nums["gen_ms"] == 1020 else { throw BrineStepError("timings missing") }
            },
            defineCheck("neither the prompt nor the response text is present") { _, _, _ in
                guard let line = w.lastLine else { throw BrineStepError("no wire line") }
                for banned in ["prompt", "response", "text", "content"] {
                    guard !line.contains("\"\(banned)\":\"") else { throw BrineStepError("banned key \(banned) present") }
                }
            },
            defineCheck("it carries the app build and a stable anonymous install id") { _, _, _ in
                guard let line = w.lastLine else { throw BrineStepError("no wire line") }
                guard line.contains("\"build\":\"288\"") else { throw BrineStepError("build missing: \(line)") }
                guard line.contains("\"dev\":\"a1b2c3d4\"") else { throw BrineStepError("install id missing: \(line)") }
            },
            defineCheck("it never carries personal data") { _, _, _ in
                guard let e = w.last else { throw BrineStepError("no event") }
                // The install id is anonymous (identifierForVendor-derived), not an email/name.
                guard !w.ctx.installId.contains("@") else { throw BrineStepError("install id looks like an email") }
                for (_, v) in e.cats where v.contains("@") { throw BrineStepError("a cat value looks like personal data: \(v)") }
            },
            defineCheck("only safe token characters survive, capped at 64") { _, _, _ in
                guard let e = w.last, let raw = e.cats["page"] else { throw BrineStepError("no dirty value staged") }
                let tok = UsageDiag.token(raw)
                guard tok.count <= 64 else { throw BrineStepError("token not capped: \(tok.count) chars") }
                guard UsageTelemetryWorld.isSafeToken(tok) else { throw BrineStepError("unsafe chars survived: \(tok)") }
                guard !tok.contains("🎤"), !tok.contains(" "), !tok.contains("!") else { throw BrineStepError("free text survived: \(tok)") }
            },
        ]
    }
}
