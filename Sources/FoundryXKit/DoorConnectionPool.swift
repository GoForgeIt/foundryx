// DoorConnectionPool.swift — the app-session-wide holder of the persistent multiplexed
// door connections (M5 R1c activation). One `DoorConnection` per channel (interactive +
// bulk), keyed by tunnel_id, shared across every turn so the Noise handshake is paid once
// and all turns ride one socket. Only used when `DoorTarget.useMux` is true; the per-turn
// `RelayTransport` path is otherwise unchanged.
//
// A turn must survive a mid-session reconnect: if the persistent connection drops, the
// in-flight turn throws `.disconnected` (retryable) — the pool transparently drops the dead
// connection, reconnects, and re-issues the turn once. Door turns are idempotent
// (chat/finalize/status/segment-ack), so a single retry is safe.

import Foundation

public actor DoorConnectionPool {
    /// Process-wide pool. Production connections are `NoiseRelayChannel` over the blind relay.
    public static let shared = DoorConnectionPool()

    private let makeChannel: @Sendable (RelayConfig) async throws -> MuxFrameChannel
    private let now: @Sendable () -> TimeInterval
    private let jitter: @Sendable () -> Double
    private var conns: [String: DoorConnection] = [:]              // live connection per tunnel_id
    private var connecting: [String: Task<DoorConnection, Error>] = [:] // in-flight connect (dedupe)

    /// Reconnect circuit breaker, per tunnel. Each re-dial of `NoiseRelayChannel.connect`
    /// pays a full Noise XX handshake (X25519 + AEAD = real CPU). When the relay leg is
    /// broken/half-open, cadence callers (the ~5s status pollers across the visible list,
    /// the capture drain, chat retries) would otherwise each trigger a fresh handshake —
    /// stacking into sustained crypto CPU (the 48–90s CPU-exception diagnostics). The
    /// breaker caps re-dials to at most one per exponentially-growing backoff window per
    /// tunnel: `failures` counts consecutive dial failures, `nextDialAt` is the monotonic
    /// instant before which a dial is refused (fail fast, NO handshake). Both reset on a
    /// successful dial, so a LEGITIMATE first-connect and recovery after a real network
    /// flip are never delayed beyond the (capped) current window.
    private var failures: [String: Int] = [:]
    private var nextDialAt: [String: TimeInterval] = [:]

    /// Backoff schedule: the base delay doubles per consecutive failure, capped. Small
    /// base so a one-off blip barely delays; a modest cap so recovery after a real flip
    /// is bounded (≤ cap), while a persistently-dead relay leg is throttled to ~1
    /// handshake per `reconnectMaxDelay`.
    static let reconnectBaseDelay: TimeInterval = 0.25
    static let reconnectMaxDelay: TimeInterval = 8.0

    /// Default factory = the real Noise-over-WS channel; tests inject an in-memory one.
    /// `now`/`jitter` are injectable so the backoff state machine is unit-testable with a
    /// fake clock and a fixed jitter (no sleeping, no networking).
    init(makeChannel: @escaping @Sendable (RelayConfig) async throws -> MuxFrameChannel
         = { try await NoiseRelayChannel.connect(config: $0) },
         now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }) {
        self.makeChannel = makeChannel
        self.now = now
        self.jitter = jitter
    }

    /// Pure exponential-backoff-with-jitter delay for the Nth consecutive dial failure
    /// (n ≥ 1): `reconnectBaseDelay` doubles, capped at `reconnectMaxDelay`, then scaled
    /// by `jitter`. Exposed for deterministic tests (jitter = 1). Mirrors the shape of
    /// `CaptureManager.retryDelay` so the whole app backs off the door the same way.
    static func reconnectDelay(forFailures n: Int, jitter: Double) -> TimeInterval {
        guard n > 0 else { return 0 }
        let exp = reconnectBaseDelay * pow(2, Double(min(n - 1, 20)))   // clamp the exponent
        return min(reconnectMaxDelay, exp) * jitter
    }

    /// Run one turn over the shared persistent connection for `config`'s tunnel. The request
    /// bytes + the returned frames are byte-identical to `RelayTransport.roundTrip`, so the
    /// caller parses them the same way. Reconnects + retries ONCE on a dropped connection.
    public func turn(config: RelayConfig, request: Data, log: DoorLog? = nil) async throws -> [Data] {
        do {
            return try await connection(for: config, log: log).turn(request)
        } catch DoorConnectionError.disconnected {
            conns.removeValue(forKey: config.tunnelId) // drop the dead one
            return try await connection(for: config, log: log).turn(request)
        }
    }

    /// Stream one turn's response frames over the shared persistent connection — each frame
    /// is yielded as the door produces it (live SSE deltas), the stream finishing on the
    /// door's ResponseEnd. If the connection is already dead when the turn starts (no frame
    /// yielded yet), it drops + reconnects + retries ONCE; a drop AFTER frames have streamed
    /// surfaces the error (we don't replay a partially-delivered response).
    public nonisolated func turnStream(config: RelayConfig, request: Data, log: DoorLog? = nil)
        -> AsyncThrowingStream<Data, Error>
    {
        AsyncThrowingStream { continuation in
            let work = Task {
                var yielded = 0
                do {
                    let conn = try await self.connection(for: config, log: log)
                    for try await frame in conn.turnStream(request) { yielded += 1; continuation.yield(frame) }
                    continuation.finish()
                } catch {
                    let retryable = (error as? DoorConnectionError) == .disconnected
                    guard yielded == 0, retryable else { continuation.finish(throwing: error); return }
                    // Dead connection before any data → reconnect + re-issue once.
                    await self.drop(config.tunnelId)
                    do {
                        let conn = try await self.connection(for: config, log: log)
                        for try await frame in conn.turnStream(request) { continuation.yield(frame) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Drop the (dead) connection for a tunnel so the next call reconnects.
    private func drop(_ tunnelId: String) { conns.removeValue(forKey: tunnelId) }

    /// Get the live connection for this tunnel, lazily connecting. Concurrent first-callers
    /// share ONE connect (the `connecting` task), so we never open two sockets for a channel.
    private func connection(for config: RelayConfig, log: DoorLog?) async throws -> DoorConnection {
        let key = config.tunnelId
        if let c = conns[key] { return c }
        if let inflight = connecting[key] { return try await inflight.value }
        // Circuit breaker: if a prior dial failed and we're still inside its backoff
        // window, refuse to dial — NO WebSocket, NO Noise XX handshake, NO crypto. This
        // is what caps reconnect churn: however hot the caller retries, a persistently
        // broken relay leg pays at most one handshake per (growing) window per tunnel.
        // Note: no live/in-flight connection above means concurrent first-callers still
        // share the ONE dial via `connecting`; the breaker only gates a fresh dial.
        if let notBefore = nextDialAt[key], now() < notBefore {
            throw DoorConnectionError.disconnected
        }
        let make = makeChannel
        let task = Task { () throws -> DoorConnection in
            let channel = try await make(config)
            let conn = DoorConnection(channel: channel, log: log)
            await conn.start()
            return conn
        }
        connecting[key] = task
        defer { connecting[key] = nil }
        do {
            let conn = try await task.value
            // Success → clear the breaker so the next reconnect after a real network flip
            // is immediate (no residual backoff penalty on a recovered leg).
            failures[key] = nil
            nextDialAt[key] = nil
            conns[key] = conn
            return conn
        } catch {
            // Failure → push the next permitted dial out exponentially (jittered, capped).
            let n = (failures[key] ?? 0) + 1
            failures[key] = n
            let delay = Self.reconnectDelay(forFailures: n, jitter: jitter())
            nextDialAt[key] = now() + delay
            log?.warn("relay dial failed (tunnel=\(key), consecutive=\(n)) — backing off \(String(format: "%.2f", delay))s before the next handshake")
            throw error
        }
    }
}
