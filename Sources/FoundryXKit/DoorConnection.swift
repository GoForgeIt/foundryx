// DoorConnection.swift — MULTIPLEXED door transport (M5 R1c). DORMANT: built + tested,
// NOT yet wired into the live DoorClient path (gated behind DoorTarget.useMux, default
// off). The working per-turn path (RelayTransport.roundTrip) is unchanged.
//
// One persistent connection per door channel carries MANY concurrent turns, each tagged
// with a turn_id (see MuxFrame). Replaces "dial + Noise handshake + one turn + close" per
// request with "handshake once, multiplex forever" — removing per-turn handshake latency
// and the door-pool re-dial churn. The relay stays blind (it pipes Noise ciphertext).
//
// Layering: `DoorConnection` (this file) owns the turn registry + demux and deals in
// PLAINTEXT mux frames over a `MuxFrameChannel`. The production channel
// (`NoiseRelayChannel`) does the Noise encryption + the WebSocket, so the bytes on the
// wire are Noise(mux_frame) — exactly what the Rust door's `serve_many` reads. Tests
// inject an in-memory loopback channel, so the mux/turn logic is exercised without
// networking (Noise itself is proven in NoiseXXVectorTests / RelayTransportTests).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DoorConnectionError: Error, Equatable {
    /// The connection dropped (or never came up). RETRYABLE: the caller may reconnect and
    /// re-issue the turn — turns are idempotent at the door (chat/finalize already are).
    case disconnected
    case channelError(String)
}

/// The plaintext mux-frame transport seam. `sendFrame`/`recvFrame` move ONE mux frame.
/// Production = `NoiseRelayChannel` (Noise-over-WS); tests inject an in-memory loopback.
/// Contract: `recvFrame` is called by a SINGLE reader (serial); `sendFrame` may be called
/// concurrently (the channel must serialize the underlying cipher/socket writes).
public protocol MuxFrameChannel: Sendable {
    func sendFrame(_ frame: Data) async throws
    func recvFrame() async throws -> Data
    func close()
}

/// Multiplexes concurrent door turns over one `MuxFrameChannel`. An `actor`, so the turn
/// registry is mutated safely from both the reader loop and concurrent `turn()` callers.
public actor DoorConnection {
    private let channel: MuxFrameChannel
    private let log: DoorLog?

    private var nextTurnId: UInt64 = 1
    private var readerTask: Task<Void, Never>?
    private var closed = false

    /// One in-flight turn. Either BUFFERED (frames accumulate, the continuation resolves on
    /// ResponseEnd — for capture/finalize/status) or STREAMING (`stream` is set; each
    /// ResponseFrame is yielded live and the stream finishes on ResponseEnd — for chat SSE).
    /// `done` handles the (tiny) race where ResponseEnd arrives before buffered `turn()` has
    /// attached its continuation across the send `await`.
    private struct Turn {
        var frames: [Data] = []
        var continuation: CheckedContinuation<[Data], Error>?
        var done = false
        var stream: AsyncThrowingStream<Data, Error>.Continuation?
    }
    private var turns: [UInt64: Turn] = [:]

    public init(channel: MuxFrameChannel, log: DoorLog? = .shared) {
        self.channel = channel
        self.log = log
    }

    /// Start the single reader loop. Idempotent.
    public func start() {
        guard readerTask == nil, !closed else { return }
        readerTask = Task { [weak self] in await self?.readLoop() }
    }

    /// Run one multiplexed turn: send the request, collect response frames until the door's
    /// ResponseEnd, return them (same shape as `RelayTransport.roundTrip`). Throws
    /// `.disconnected` (retryable) if the connection drops while in flight.
    public func turn(_ request: Data) async throws -> [Data] {
        if closed { throw DoorConnectionError.disconnected }
        let id = nextTurnId
        nextTurnId &+= 1
        // Register BEFORE awaiting the send so a fast ResponseEnd is never dropped.
        turns[id] = Turn()
        do {
            try await channel.sendFrame(encodeMuxFrame(turnId: id, kind: .request, payload: request))
        } catch {
            turns.removeValue(forKey: id)
            throw DoorConnectionError.disconnected
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Data], Error>) in
            guard var t = turns[id] else {
                // failAll already ran (disconnected) between the send and here.
                cont.resume(throwing: DoorConnectionError.disconnected)
                return
            }
            if t.done {
                turns.removeValue(forKey: id)
                cont.resume(returning: t.frames)
            } else {
                t.continuation = cont
                turns[id] = t
            }
        }
    }

    /// Run one multiplexed turn but STREAM the door's response frames: each ResponseFrame
    /// is yielded as it arrives (the door flushes per SSE line), and the stream finishes on
    /// ResponseEnd — so chat deltas reach the UI live instead of all-at-once. The stream
    /// finishes with `.disconnected` (retryable) if the connection drops mid-turn.
    public nonisolated func turnStream(_ request: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { await self.startStreamTurn(request, continuation) }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Register the streaming turn (continuation stored atomically with its id, BEFORE the
    /// send — so a fast ResponseFrame/End is never dropped) and send the request.
    private func startStreamTurn(
        _ request: Data,
        _ continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        if closed { continuation.finish(throwing: DoorConnectionError.disconnected); return }
        let id = nextTurnId
        nextTurnId &+= 1
        var t = Turn()
        t.stream = continuation
        turns[id] = t
        do {
            try await channel.sendFrame(encodeMuxFrame(turnId: id, kind: .request, payload: request))
        } catch {
            turns.removeValue(forKey: id)
            continuation.finish(throwing: DoorConnectionError.disconnected)
        }
    }

    /// Best-effort cancel: tell the door to stop a turn (it navigated away). Resolves the
    /// local turn as disconnected so a waiter doesn't hang.
    public func cancel(turnId id: UInt64) async {
        try? await channel.sendFrame(encodeMuxFrame(turnId: id, kind: .cancel, payload: Data()))
        if let t = turns.removeValue(forKey: id) {
            t.continuation?.resume(throwing: DoorConnectionError.disconnected)
        }
    }

    /// Tear down: stop reading, close the channel, fail every in-flight turn (retryable).
    public func shutdown() {
        failAll(.disconnected)
        readerTask?.cancel()
        readerTask = nil
        channel.close()
    }

    // MARK: reader

    private func readLoop() async {
        while !closed {
            let frame: Data
            do {
                frame = try await channel.recvFrame()
            } catch {
                log?.warn("mux reader ended: \(error) — failing in-flight turns (retryable)")
                failAll(.disconnected)
                return
            }
            guard let (id, kindByte, payload) = decodeMuxFrame(frame),
                  let kind = MuxKind(rawValue: kindByte) else {
                continue // garbage / unknown kind → ignore (blind to malformed frames)
            }
            switch kind {
            case .responseFrame:
                if let stream = turns[id]?.stream {
                    stream.yield(payload)          // streaming: deliver the delta live
                } else {
                    turns[id]?.frames.append(payload)  // buffered: accumulate
                }
            case .responseEnd:
                if let t = turns[id], let stream = t.stream {
                    turns.removeValue(forKey: id)
                    stream.finish()
                } else {
                    completeTurn(id)
                }
            case .request, .cancel:
                continue // the client never receives these
            }
        }
    }

    private func completeTurn(_ id: UInt64) {
        guard var t = turns[id] else { return } // unknown / already resolved
        if let cont = t.continuation {
            turns.removeValue(forKey: id)
            cont.resume(returning: t.frames)
        } else {
            t.done = true // ResponseEnd beat the continuation; turn() will see it
            turns[id] = t
        }
    }

    private func failAll(_ err: DoorConnectionError) {
        guard !closed else { return }
        closed = true
        let pending = turns
        turns = [:]
        for (_, t) in pending {
            t.continuation?.resume(throwing: err)
            t.stream?.finish(throwing: err)
        }
    }
}

// MARK: - Production channel: Noise over a persistent relay WebSocket

/// `MuxFrameChannel` over the blind relay: one persistent WebSocket + a completed Noise XX
/// transport. `sendFrame` = encrypt + ws.send; `recvFrame` = ws.receive + decrypt. Sends
/// are serialized through an internal actor (the Noise send-cipher nonce is sequential);
/// receives are driven by DoorConnection's single reader. A ~20s WS ping detects a dead
/// relay → the next `recvFrame` throws → DoorConnection fails in-flight turns retryably.
///
/// NOTE: this is the dormant production wiring. It is not exercised by `swift test` (no live
/// relay there); DoorConnection's mux logic is covered by the loopback test. It mirrors
/// RelayTransport's handshake exactly, then KEEPS the connection instead of one-shot.
public final class NoiseRelayChannel: MuxFrameChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let recv: NoiseCipherState
    private let sender: SendSide
    private let pinger: Task<Void, Never>

    /// Serializes Noise send-cipher use + the socket write (the cipher nonce must advance
    /// in order even under concurrent `turn()` calls).
    private actor SendSide {
        let task: URLSessionWebSocketTask
        let send: NoiseCipherState
        init(task: URLSessionWebSocketTask, send: NoiseCipherState) {
            self.task = task; self.send = send
        }
        func sendFrame(_ frame: Data) async throws {
            let ct = try send.encryptWithAd(ad: Data(), plaintext: frame)
            try await task.send(.data(ct))
        }
    }

    private init(task: URLSessionWebSocketTask, send: NoiseCipherState, recv: NoiseCipherState) {
        self.task = task
        self.recv = recv
        self.sender = SendSide(task: task, send: send)
        // App-level heartbeat: a dead/half-open relay is noticed in ~one ping (the ping
        // errors), which closes the task → recvFrame throws. Mirrors the door's keepalive.
        self.pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                if Task.isCancelled { break }
                let alive: Bool = await withCheckedContinuation { cont in
                    // URLSessionWebSocketTask.sendPing's completion handler can fire TWICE
                    // during a teardown/cancel race (notably when a ping lands mid-turn on a
                    // long turn) — and resuming a CheckedContinuation twice is a hard crash.
                    // Gate it so we resume exactly once.
                    let lock = NSLock()
                    var resumed = false
                    task.sendPing { err in
                        lock.lock(); let first = !resumed; resumed = true; lock.unlock()
                        if first { cont.resume(returning: err == nil) }
                    }
                }
                if !alive { task.cancel(with: .goingAway, reason: nil); break }
            }
        }
    }

    /// Open the persistent connection: WS + client Hello + Noise XX initiator handshake (+
    /// optional door-key pin), then enter transport mode and keep it open for multiplexing.
    public static func connect(config: RelayConfig,
                               session: URLSession = URLSession(configuration: .ephemeral)) async throws -> NoiseRelayChannel {
        let task = session.webSocketTask(with: config.relayURL)
        task.resume()

        let hello: [String: Any] = ["role": "client", "tunnel_id": config.tunnelId]
        let helloJSON = (try? String(data: JSONSerialization.data(withJSONObject: hello), encoding: .utf8)) ?? "{}"
        let withBearer = helloJSON.replacingOccurrences(of: "}", with: ",\"bearer\":null}")
        try await task.send(.string(withBearer))

        let initiator = try NoiseXXInitiator(staticPrivate: config.staticPrivate)
        try await task.send(.data(try initiator.writeMessage()))
        let msg2 = try await Self.recvBinary(task)
        _ = try initiator.readMessage(msg2)
        try await task.send(.data(try initiator.writeMessage()))
        // THE PIN. Unconditional — `RelayConfig.expectedDoorStatic` is not optional, so
        // this site has no unpinned form.
        if initiator.remoteStaticPublic != config.expectedDoorStatic {
            task.cancel(with: .policyViolation, reason: nil)
            throw RelayError.doorIdentityMismatch
        }
        let (send, recv) = try initiator.split()
        return NoiseRelayChannel(task: task, send: send, recv: recv)
    }

    public func sendFrame(_ frame: Data) async throws { try await sender.sendFrame(frame) }

    public func recvFrame() async throws -> Data {
        let ct = try await Self.recvBinary(task)
        return try recv.decryptWithAd(ad: Data(), ciphertext: ct)
    }

    public func close() {
        pinger.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private static func recvBinary(_ task: URLSessionWebSocketTask) async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string: throw RelayError.nonBinaryFrame
        @unknown default: throw RelayError.nonBinaryFrame
        }
    }
}
