// CaptureWAL — the phone-side durable write-ahead log for Omi capture, mirroring
// Omi's LocalWalSync pattern. Incoming Opus frames are buffered, chunked into
// segments, and each segment is written durably to disk on the phone BEFORE it's
// uploaded. A syncer POSTs each segment to the door's /foundryx/capture and marks
// it `synced` ONLY on the door's 200 ACK (durable-on-desktop) — never on "bytes
// sent." Unsynced segments persist across launches and retry; on offline/door-down
// they stay pending and drain on reconnect. The phone keeps its own copy of every
// segment (AC3) — the .ack marker only records desktop delivery, nothing is deleted.
//
// On-disk layout: <docs>/foundryx-captures/<capture_id>/
//   seg-<012-seq>.opus   — one segment = length-prefixed Opus frames
//                          ([UInt32 BE length][frame bytes]…), so frame
//                          boundaries survive for server-side Opus decode later.
//   seg-<012-seq>.ack    — present ⇒ the desktop durably stored this segment.

import Foundation

public enum CaptureStage: String, Sendable, Codable {
    case recording        // source streaming, frames arriving
    case savedOnPhone     // ≥1 segment durable in the WAL, not all ACK'd yet
    case savedToComputer  // every segment ACK'd by the desktop ("can't be lost")
}

public struct CaptureStatus: Sendable, Equatable, Identifiable {
    public let id: String          // capture_id
    public var stage: CaptureStage
    public var totalSegments: Int
    public var syncedSegments: Int
    public var bytes: Int
    public var startedAt: Date
    public var streaming: Bool
    public var lastSyncError: String?
    public var pendingSegments: Int { max(0, totalSegments - syncedSegments) }
}

public final class CaptureWAL: ObservableObject, @unchecked Sendable {
    public let captureId: String
    @Published public private(set) var status: CaptureStatus

    private let dir: URL
    private let target: DoorTarget
    private let session: URLSession
    private let log: DoorLog?
    private let chunkFrames: Int
    private let startedAt = Date()

    private let io = DispatchQueue(label: "foundryx.capture-wal")
    private var buffer: [Data] = []      // frames awaiting a chunk (io queue only)
    private var nextSeq: UInt64 = 0      // next segment seq (io queue only)
    private var streaming = false        // mutated on io; read in computeStatus (@unchecked)
    private var lastError: String?       // last sync failure detail (@unchecked)

    /// `baseDir` defaults to the app's Documents dir (persists across launches).
    public init(captureId: String,
                target: DoorTarget,
                baseDir: URL? = nil,
                chunkFrames: Int = 50,            // ~1s at Omi's ~50 frames/s
                session: URLSession = URLSession(configuration: .ephemeral),
                log: DoorLog? = nil) {
        self.captureId = captureId
        self.target = target
        self.session = session
        self.log = log
        self.chunkFrames = chunkFrames
        let root = baseDir ?? CaptureWAL.documentsCaptures()
        self.dir = root.appendingPathComponent(captureId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.status = CaptureStatus(id: captureId, stage: .recording, totalSegments: 0,
                                    syncedSegments: 0, bytes: 0, startedAt: startedAt,
                                    streaming: false, lastSyncError: nil)
        scanExisting()
    }

    public static func documentsCaptures() -> URL {
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("foundryx-captures", isDirectory: true)
    }

    // MARK: capture lifecycle

    public func beginStreaming() {
        io.async { [weak self] in self?.streaming = true; self?.publish() }
    }

    /// Append one Opus frame. Thread-safe (hops to the io queue). Flushes a
    /// segment once `chunkFrames` have accumulated.
    public func appendFrame(_ frame: Data) {
        io.async { [weak self] in
            guard let self else { return }
            self.buffer.append(frame)
            if self.buffer.count >= self.chunkFrames { self.flushLocked() }
        }
    }

    /// Flush buffered frames as a final segment + stop streaming. Pure-flush — the
    /// owner (CaptureManager / its drain loop) drives sync, so there's no racing
    /// background sync and tests are deterministic.
    public func finish() {
        io.sync { self.flushLocked(); self.streaming = false }
        publish()
    }

    /// Synchronous flush barrier (waits for queued appends — `io` is serial — then
    /// flushes the remainder). Lets tests put every frame on disk before syncing.
    public func flushAndWait() {
        io.sync { self.flushLocked() }
        publish()
    }

    // MARK: segment write (durable-on-phone)

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let seq = nextSeq; nextSeq += 1
        let body = CaptureWAL.encodeSegment(buffer)
        buffer.removeAll(keepingCapacity: true)
        let url = dir.appendingPathComponent(CaptureWAL.segName(seq))
        do {
            try body.write(to: url, options: [.atomic])   // temp + atomic rename
            log?.info("capture \(captureId): wrote segment \(seq) (\(body.count)B) to WAL")
        } catch {
            log?.error("capture \(captureId): WAL write seg \(seq) failed: \(error.localizedDescription)")
        }
    }

    /// Segment encoding: length-prefixed frames so boundaries survive for decode.
    static func encodeSegment(_ frames: [Data]) -> Data {
        var out = Data()
        for f in frames {
            var len = UInt32(f.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(f)
        }
        return out
    }

    static func segName(_ seq: UInt64) -> String { String(format: "seg-%012llu.opus", seq) }
    private func ackURL(_ segURL: URL) -> URL { segURL.deletingPathExtension().appendingPathExtension("ack") }

    // MARK: sync (mark synced ONLY on the door's 200 ACK)

    /// Drain every unsynced segment to the door. Re-entrant-safe; segments that
    /// fail stay pending and are retried on the next call.
    public func sync() async {
        let pending = pendingSegmentURLs()
        guard !pending.isEmpty else { lastError = nil; publish(); return }
        for (seq, segURL) in pending {
            do {
                let bytes = try Data(contentsOf: segURL)
                try await upload(seq: seq, body: bytes)
                try Data().write(to: ackURL(segURL), options: [.atomic])   // 200 ACK ⇒ saved to computer
                lastError = nil
                log?.info("capture \(captureId): segment \(seq) ACK'd by desktop (saved to computer)")
                publish()
            } catch {
                lastError = (error as NSError).localizedDescription
                log?.warn("capture \(captureId): segment \(seq) not synced (\(lastError ?? "?")) — staying pending, will retry")
                publish()
                return  // stop on first failure; the rest stay pending for the next tick
            }
        }
    }

    /// POST one segment. Throws on any non-200 so the segment stays pending. In
    /// remote mode the door lives behind the relay tunnel, so the upload goes E2E
    /// through RelayHTTP (a plain POST to the nominal baseURL — the relay's HTTP
    /// control port — has no /foundryx/capture route and 404s).
    private func upload(seq: UInt64, body: Data) async throws {
        let headers = ["X-Capture-Id": captureId, "X-Capture-Seq": String(seq)]
        if let relay = target.relay {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: "/foundryx/capture", extraHeaders: headers,
                contentType: "application/octet-stream", body: body,
                session: session, log: log)
            if resp.status == 401 { throw DoorError.unauthorized }
            guard resp.status == 200 else { throw DoorError.http(resp.status) }
            return
        }
        var r = URLRequest(url: target.baseURL.appendingPathComponent("foundryx/capture"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(target.bearer)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(captureId, forHTTPHeaderField: "X-Capture-Id")
        r.setValue(String(seq), forHTTPHeaderField: "X-Capture-Seq")
        r.httpBody = body
        r.timeoutInterval = 30
        let (_, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw DoorError.transport("non-HTTP response") }
        if http.statusCode == 401 { throw DoorError.unauthorized }
        guard http.statusCode == 200 else { throw DoorError.http(http.statusCode) }
    }

    // MARK: status

    /// Synchronous status from disk — no `@Published` write. For tests + sync().
    public func snapshot() -> CaptureStatus { computeStatus() }

    private func computeStatus() -> CaptureStatus {
        let all = allSegmentURLs()
        let syncedCount = all.filter { FileManager.default.fileExists(atPath: ackURL($0.1).path) }.count
        var byteCount = 0
        for (_, u) in all {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
               let n = attrs[.size] as? Int { byteCount += n }
        }
        let stage: CaptureStage = all.isEmpty ? .recording
            : (syncedCount == all.count && !streaming ? .savedToComputer : .savedOnPhone)
        var s = status
        s.totalSegments = all.count
        s.syncedSegments = syncedCount
        s.bytes = byteCount
        s.streaming = streaming
        s.stage = stage
        s.lastSyncError = lastError
        return s
    }

    private func publish() {
        let s = computeStatus()
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.status = s
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func pendingSegmentURLs() -> [(UInt64, URL)] {
        allSegmentURLs().filter { !FileManager.default.fileExists(atPath: ackURL($0.1).path) }
    }

    private func allSegmentURLs() -> [(UInt64, URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "opus" }
            .compactMap { url -> (UInt64, URL)? in
                let name = url.deletingPathExtension().lastPathComponent  // seg-000…000
                guard let seqStr = name.split(separator: "-").last, let seq = UInt64(seqStr) else { return nil }
                return (seq, url)
            }
            .sorted { $0.0 < $1.0 }
    }

    private func scanExisting() {
        let segs = allSegmentURLs()
        if let maxSeq = segs.map({ $0.0 }).max() { nextSeq = maxSeq + 1 }
        publish()
        if !pendingSegmentURLs().isEmpty { Task { await self.sync() } }
    }
}
