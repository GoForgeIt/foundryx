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
    private var conns: [String: DoorConnection] = [:]              // live connection per tunnel_id
    private var connecting: [String: Task<DoorConnection, Error>] = [:] // in-flight connect (dedupe)

    /// Default factory = the real Noise-over-WS channel; tests inject an in-memory one.
    init(makeChannel: @escaping @Sendable (RelayConfig) async throws -> MuxFrameChannel
         = { try await NoiseRelayChannel.connect(config: $0) }) {
        self.makeChannel = makeChannel
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
        if let c = conns[config.tunnelId] { return c }
        if let inflight = connecting[config.tunnelId] { return try await inflight.value }
        let make = makeChannel
        let task = Task { () throws -> DoorConnection in
            let channel = try await make(config)
            let conn = DoorConnection(channel: channel, log: log)
            await conn.start()
            return conn
        }
        connecting[config.tunnelId] = task
        defer { connecting[config.tunnelId] = nil }
        let conn = try await task.value
        conns[config.tunnelId] = conn
        return conn
    }
}
