import XCTest
@testable import FoundryXKit

/// The door emits `keepalive` (elapsed ms while the model works) and `timing` (the
/// end-of-turn summary). The phone parses them and the chat model surfaces a live
/// "thinking… Ns" hint before the first token, then the per-turn timing once done.
@MainActor
final class TurnTimingTests: XCTestCase {

    func testParsesKeepaliveAndTiming() {
        guard case .keepalive(let ms) = DoorEvent.parse(#"{"type":"keepalive","ms":3200}"#) else {
            return XCTFail("expected keepalive")
        }
        XCTAssertEqual(ms, 3200)

        guard case .timing(let r, let t, let g, let total, let n) =
            DoorEvent.parse(#"{"type":"timing","route_ms":2600,"ttft_ms":14900,"gen_ms":16500,"total_ms":31400,"tokens":331}"#)
        else { return XCTFail("expected timing") }
        XCTAssertEqual([r, t, g, total, n], [2600, 14900, 16500, 31400, 331])
    }

    func testThinkingHintRisesThenClearsOnFirstToken() {
        let m = ChatViewModel()
        m.beginUserTurn("hello")
        XCTAssertEqual(m.thinkingMs, 0, "reset at turn start")

        m.apply(.keepalive(ms: 1200))
        m.apply(.keepalive(ms: 3400))
        XCTAssertEqual(m.thinkingMs, 3400, "shows the latest elapsed while waiting on the first token")

        m.apply(.assistantDelta(text: "Hi"))
        XCTAssertEqual(m.thinkingMs, 0, "first token clears the thinking hint")

        // A keepalive that somehow arrives after tokens started doesn't resurrect the hint.
        m.apply(.keepalive(ms: 9000))
        XCTAssertEqual(m.thinkingMs, 0, "no thinking hint once tokens are streaming")
    }

    func testTimingSummaryStored() {
        let m = ChatViewModel()
        m.beginUserTurn("hi")
        m.apply(.timing(routeMs: 2600, ttftMs: 14900, genMs: 16500, totalMs: 31400, tokens: 331))
        m.apply(.done(reason: "stop"))
        XCTAssertEqual(m.lastTiming, ChatViewModel.TurnTiming(routeMs: 2600, ttftMs: 14900,
                                                              genMs: 16500, totalMs: 31400, tokens: 331))
    }
}
