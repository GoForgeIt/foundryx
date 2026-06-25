import XCTest
@testable import FoundryXKit

/// DoorConnection multiplex logic, exercised over an in-memory loopback channel + a
/// concurrent fake door (no networking; Noise is proven separately). Proves: concurrent
/// turns demux by turn_id with no cross-talk, ResponseEnd resolves the right turn, a slow
/// turn doesn't block others, and a disconnect fails in-flight turns retryably.
final class DoorConnectionTests: XCTestCase {

    // MARK: in-memory async frame queue (single consumer)

    final class FrameQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [Data] = []
        private var waiters: [CheckedContinuation<Data?, Never>] = []
        private var finished = false

        func push(_ d: Data) {
            lock.lock()
            if !waiters.isEmpty {
                let w = waiters.removeFirst(); lock.unlock(); w.resume(returning: d)
            } else {
                buffer.append(d); lock.unlock()
            }
        }
        func finish() {
            lock.lock(); finished = true; let ws = waiters; waiters = []; lock.unlock()
            ws.forEach { $0.resume(returning: nil) }
        }
        func pull() async -> Data? {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if !buffer.isEmpty { let d = buffer.removeFirst(); lock.unlock(); cont.resume(returning: d) }
                else if finished { lock.unlock(); cont.resume(returning: nil) }
                else { waiters.append(cont); lock.unlock() }
            }
        }
    }

    /// Loopback `MuxFrameChannel`: client↔door over two queues, no Noise/WS.
    final class LoopbackChannel: MuxFrameChannel, @unchecked Sendable {
        let toDoor = FrameQueue()    // client → door
        let fromDoor = FrameQueue()  // door → client
        func sendFrame(_ frame: Data) async throws { toDoor.push(frame) }
        func recvFrame() async throws -> Data {
            if let d = await fromDoor.pull() { return d }
            throw DoorConnectionError.disconnected
        }
        func close() { toDoor.finish(); fromDoor.finish() }
    }

    /// A fake door: reads client Requests and runs each on its OWN task (concurrently),
    /// streaming the handler's frames + a ResponseEnd back, tagged with the turn_id.
    private func runFakeDoor(_ ch: LoopbackChannel,
                             handler: @escaping @Sendable (Data) async -> [Data]) -> Task<Void, Never> {
        Task {
            while let frame = await ch.toDoor.pull() {
                guard let (id, kindByte, payload) = decodeMuxFrame(frame),
                      MuxKind(rawValue: kindByte) == .request else { continue }
                Task {
                    let frames = await handler(payload)
                    for f in frames {
                        ch.fromDoor.push(encodeMuxFrame(turnId: id, kind: .responseFrame, payload: f))
                    }
                    ch.fromDoor.push(encodeMuxFrame(turnId: id, kind: .responseEnd, payload: Data()))
                }
            }
        }
    }

    // MARK: tests

    func testConcurrentTurnsDemuxWithoutCrossTalk() async throws {
        let ch = LoopbackChannel()
        let conn = DoorConnection(channel: ch)
        await conn.start()
        let door = runFakeDoor(ch) { req in
            let s = String(decoding: req, as: UTF8.self)
            return [Data("\(s)-a".utf8), Data("\(s)-b".utf8)] // two ordered frames per turn
        }
        defer { door.cancel() }

        // 8 concurrent turns; each must get back exactly its own two ordered frames.
        try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            for i in 0..<8 {
                group.addTask {
                    let frames = try await conn.turn(Data("t\(i)".utf8))
                    return ("t\(i)", frames.map { String(decoding: $0, as: UTF8.self) })
                }
            }
            var seen = 0
            for try await (tag, frames) in group {
                XCTAssertEqual(frames, ["\(tag)-a", "\(tag)-b"], "turn \(tag) demuxed its own frames in order")
                seen += 1
            }
            XCTAssertEqual(seen, 8)
        }
    }

    func testSlowTurnDoesNotBlockFastTurn() async throws {
        let ch = LoopbackChannel()
        let conn = DoorConnection(channel: ch)
        await conn.start()
        let door = runFakeDoor(ch) { req in
            if String(decoding: req, as: UTF8.self) == "slow" {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return [Data("slow-reply".utf8)]
            }
            return [Data("fast-reply".utf8)]
        }
        defer { door.cancel() }

        let t0 = Date()
        async let slow = conn.turn(Data("slow".utf8))
        async let fast = conn.turn(Data("fast".utf8))
        let fastFrames = try await fast
        let fastElapsed = Date().timeIntervalSince(t0)
        let slowFrames = try await slow

        XCTAssertEqual(fastFrames.map { String(decoding: $0, as: UTF8.self) }, ["fast-reply"])
        XCTAssertEqual(slowFrames.map { String(decoding: $0, as: UTF8.self) }, ["slow-reply"])
        // The fast turn must return WITHOUT waiting out the 300ms slow turn — proves the
        // turns run concurrently over the one connection (not head-of-line blocked).
        XCTAssertLessThan(fastElapsed, 0.2, "fast turn was blocked behind the slow one")
    }

    func testDisconnectFailsInFlightTurnsRetryable() async throws {
        let ch = LoopbackChannel()
        let conn = DoorConnection(channel: ch)
        await conn.start()
        // No fake door → the turn never gets a response; then drop the connection.
        let pending = Task { try await conn.turn(Data("x".utf8)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        ch.fromDoor.finish() // reader's recvFrame → nil → DoorConnection.failAll(.disconnected)

        do {
            _ = try await pending.value
            XCTFail("expected the in-flight turn to fail on disconnect")
        } catch let e as DoorConnectionError {
            XCTAssertEqual(e, .disconnected, "in-flight turn fails retryably, not silently hangs")
        }
    }

    /// The pool reuses ONE connection across turns (handshake paid once), and a dropped
    /// connection reconnects + retries the turn exactly once.
    func testPoolReusesConnectionAndReconnects() async throws {
        actor Holder {
            var count = 0
            var channels: [LoopbackChannel] = []
            var doors: [Task<Void, Never>] = []
            func record(_ ch: LoopbackChannel, _ door: Task<Void, Never>) {
                count += 1; channels.append(ch); doors.append(door)
            }
            func snapshot() -> (Int, LoopbackChannel?) { (count, channels.first) }
            func cancelAll() { doors.forEach { $0.cancel() } }
        }
        let holder = Holder()
        let makeChannel: @Sendable (RelayConfig) async throws -> MuxFrameChannel = { _ in
            let ch = LoopbackChannel()
            let door = Task {
                while let frame = await ch.toDoor.pull() {
                    guard let (id, k, payload) = decodeMuxFrame(frame),
                          MuxKind(rawValue: k) == .request else { continue }
                    Task {
                        ch.fromDoor.push(encodeMuxFrame(turnId: id, kind: .responseFrame, payload: payload))
                        ch.fromDoor.push(encodeMuxFrame(turnId: id, kind: .responseEnd, payload: Data()))
                    }
                }
            }
            await holder.record(ch, door)
            return ch
        }
        let pool = DoorConnectionPool(makeChannel: makeChannel)
        let cfg = RelayConfig(relayURL: URL(string: "ws://x")!, tunnelId: "t",
                              staticPrivate: Data(repeating: 0, count: 32), expectedDoorStatic: nil)

        let a = try await pool.turn(config: cfg, request: Data("a".utf8))
        XCTAssertEqual(a.map { String(decoding: $0, as: UTF8.self) }, ["a"])
        let b = try await pool.turn(config: cfg, request: Data("b".utf8))
        XCTAssertEqual(b.map { String(decoding: $0, as: UTF8.self) }, ["b"])
        let (c1, firstCh) = await holder.snapshot()
        XCTAssertEqual(c1, 1, "second turn reused the one connection (no new channel)")

        firstCh?.fromDoor.finish()                     // drop the connection
        try await Task.sleep(nanoseconds: 60_000_000)  // let the reader fail the conn
        let c = try await pool.turn(config: cfg, request: Data("c".utf8))
        XCTAssertEqual(c.map { String(decoding: $0, as: UTF8.self) }, ["c"], "turn survived a reconnect")
        let (c2, _) = await holder.snapshot()
        XCTAssertEqual(c2, 2, "a dropped connection reconnected exactly once")
        await holder.cancelAll()
    }

    /// `turnStream` yields each ResponseFrame AS IT ARRIVES (not collected at ResponseEnd) —
    /// the property that makes chat deltas reach the UI live instead of all-at-once.
    func testTurnStreamYieldsFramesIncrementally() async throws {
        let ch = LoopbackChannel()
        let conn = DoorConnection(channel: ch)
        await conn.start()
        // Door pushes 3 frames with 120ms gaps, then ResponseEnd — the shape of SSE deltas
        // produced over time. Buffered delivery would collapse all arrivals to the end.
        let door = Task {
            while let frame = await ch.toDoor.pull() {
                guard let (id, k, _) = decodeMuxFrame(frame), MuxKind(rawValue: k) == .request else { continue }
                Task {
                    for i in 0..<3 {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        ch.fromDoor.push(encodeMuxFrame(turnId: id, kind: .responseFrame, payload: Data("d\(i)".utf8)))
                    }
                    ch.fromDoor.push(encodeMuxFrame(turnId: id, kind: .responseEnd, payload: Data()))
                }
            }
        }
        defer { door.cancel() }

        let t0 = Date()
        var arrivals: [(String, TimeInterval)] = []
        for try await frame in conn.turnStream(Data("go".utf8)) {
            arrivals.append((String(decoding: frame, as: UTF8.self), Date().timeIntervalSince(t0)))
        }
        XCTAssertEqual(arrivals.map { $0.0 }, ["d0", "d1", "d2"], "all frames streamed, in order")
        // The PROOF: the first delta arrives early and frames are spaced over time. If the
        // turn buffered to ResponseEnd, all three arrivals would be ~0.36s (collapsed).
        XCTAssertLessThan(arrivals[0].1, 0.25, "first delta streamed early, not buffered to the end")
        XCTAssertGreaterThanOrEqual(arrivals[2].1 - arrivals[0].1, 0.15,
                                    "frames spaced over time — incremental, not batched")
    }

    /// The incremental SSE parser tolerates `data:` lines split ACROSS mux frame boundaries:
    /// only whole lines are emitted; a partial line carries forward in the remainder.
    func testDrainSSELinesHandlesSplitLines() {
        // Frame 1 ends mid-line; frame 2 completes it + adds another.
        var buf = Data("data: {\"type\":\"assistant_delta\",\"te".utf8)
        var (events, remainder, done) = DoorClient.drainSSELines(buf)
        XCTAssertTrue(events.isEmpty, "no complete line yet → nothing emitted")
        XCTAssertFalse(done)

        buf = remainder + Data("xt\":\"hi\"}\ndata: {\"type\":\"done\",\"reason\":\"ok\"}\n".utf8)
        (events, remainder, done) = DoorClient.drainSSELines(buf)
        XCTAssertEqual(events.count, 2, "the rejoined delta + the done event")
        XCTAssertTrue(done, "done event terminates the turn")
        if case .assistantDelta(let t) = events[0] { XCTAssertEqual(t, "hi") } else { XCTFail("expected delta") }
    }
}
