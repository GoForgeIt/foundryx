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

/// The outcome of one `CaptureWAL.sync()` pass — so the owner's bounded-retry drain
/// can tell "made progress / nothing to do" from a TRANSIENT failure (back off + retry)
/// and from an AUTH-EXPIRED rejection (stop retrying; the bearer is a known-bad,
/// expired id_token — re-auth is required, retrying just storms the door).
public enum SyncOutcome: Sendable, Equatable {
    case idle            // nothing pending
    case progressed      // uploaded ≥1 segment with no failure
    case failed          // transient failure (offline / door down) — retry with backoff
    case authExpired     // a 401 — STOP; the token is expired, re-auth before retrying
    /// A specific segment is PERMANENTLY un-uploadable: its on-disk file is
    /// missing/corrupt (unrecoverable), OR the door rejected it with a permanent,
    /// non-auth 4xx (e.g. 400/403/413/422). Retrying can NEVER succeed, so the owner
    /// retires the capture — but the audio bytes are KEPT (a durable marker, never a
    /// delete). Carries the offending seq + a human reason for the log. This is the
    /// ONLY auto-retire trigger: a large / old / briefly-offline capture is never
    /// poisoned, so it keeps draining until fully uploaded.
    case poisoned(seq: UInt64, reason: String)
}

public final class CaptureWAL: ObservableObject, @unchecked Sendable {
    public let captureId: String
    @Published public private(set) var status: CaptureStatus

    /// Cap the segments uploaded in ONE `sync()` pass so a giant backlog (e.g. a stuck
    /// capture with thousands of segments) drains at a sane, steady rate instead of
    /// firing thousands of POSTs back-to-back.
    public static let maxSegmentsPerSync = 16

    /// Segment uploads within one WAL sync are concurrent but bounded. This keeps a
    /// single long conversation from trickling one POST at a time for hours while still
    /// avoiding the unbounded launch storm that older per-WAL background sync caused.
    public static let maxConcurrentSegmentUploads = 4

    private let dir: URL
    private let target: DoorTarget
    private let session: URLSession
    private let log: DoorLog?
    private let chunkFrames: Int
    private let accountBinding: CaptureAccountScope.AccountBinding?
    private let startedAt = Date()
    /// Test seam: when set, replaces the real door POST for each segment (so the
    /// drain/backoff/auth-expired paths are exercised deterministically, no network).
    private let uploadOverride: (@Sendable (UInt64, Data) async throws -> Void)?

    private let io = DispatchQueue(label: "foundryx.capture-wal")
    private let ioKey = DispatchSpecificKey<Bool>()
    private var buffer: [Data] = []      // frames awaiting a chunk (io queue only)
    private var nextSeq: UInt64 = 0      // next segment seq (io queue only)
    private var streaming = false        // mutated on io; read in computeStatus (@unchecked)
    private var lastError: String?       // last sync failure detail (@unchecked)

    /// The durable UPLOAD WATERMARK: the highest CONTIGUOUSLY-ACK'd segment seq
    /// (−1 ⇒ none yet). Resume always starts at `watermark + 1`, so a giant capture
    /// makes MONOTONIC forward progress across retries / app-restarts and NEVER
    /// re-sends an already-ACK'd segment (the restart-from-0 churn this fixes).
    /// Persisted in `.upload-watermark`; for a pre-existing / already-in-progress
    /// stuck capture with no watermark file it is DERIVED from the on-disk `.ack`
    /// markers (the source of truth), so an old stuck capture resumes from where it is.
    private let wmLock = NSLock()
    private var watermark: Int64 = -1

    /// LAZY SEGMENT SCAN (launch-hang fix, 2026-07-16). Constructing a WAL used to
    /// EAGERLY scan its segment dir in `init` (`scanExisting`): enumerate + parse every
    /// segment file, derive the watermark from the on-disk `.ack` markers, and publish.
    /// Hydrating up to `maxCapturesToLoad` of those at launch turned into a multi-second
    /// stat storm (real-phone `capture-hydrate` spans of 6–11 s on backlogged libraries)
    /// that kept the conversation list stuck on its warm seed for seconds. The scan is now
    /// DEFERRED: a WAL constructs cheaply, and the (still one-time, idempotent) segment
    /// work happens only when a WAL's segment state is actually needed — the durable
    /// upload watermark on first read (`ensureWatermarkLoaded`), and the next append seq on
    /// the first flush (`ensureNextSeqLoadedOnIO`). The launch warm pass calls `warmStatus`
    /// off-main to fill in real counts a moment AFTER the fast card swap, not before it.
    ///
    /// Two separate guards on purpose: the watermark lives under `wmLock` and is read from
    /// arbitrary threads (status/drain), while `nextSeq` is `io`-queue-only, so deriving it
    /// must happen ON that serial queue (in `flushLocked`) to stay race-free.
    private let scanLock = NSLock()
    private var watermarkLoaded = false
    private var nextSeqLoaded = false          // io queue only

    /// Load the durable upload watermark exactly once, lazily. Idempotent + thread-safe:
    /// `scanLock` serializes so concurrent first-readers all see the fully-loaded value
    /// (never the −1 default mid-derive). Distinct from `wmLock`, which
    /// `loadOrDeriveWatermark` takes internally to set `watermark` — no re-entrancy.
    private func ensureWatermarkLoaded() {
        scanLock.lock(); defer { scanLock.unlock() }
        guard !watermarkLoaded else { return }
        loadOrDeriveWatermark()
        watermarkLoaded = true
    }

    /// Derive the next segment seq once, lazily, from the highest on-disk segment. MUST be
    /// called on the serial `io` queue (it reads/writes `nextSeq`, which is io-queue-only) —
    /// so a resumed/active capture continues its sequence instead of overwriting seg 0.
    private func ensureNextSeqLoadedOnIO() {
        guard !nextSeqLoaded else { return }
        nextSeqLoaded = true
        if let maxSeq = allSegmentURLs().map({ $0.0 }).max() { nextSeq = maxSeq + 1 }
    }

    /// Launch WARM pass (off the fast first-paint path): publish the real status ONCE, so the
    /// conversation list + sync banner reflect true segment/sync counts a moment AFTER the fast
    /// card swap. Cheap per WAL; the owner runs it off-main over the hydrated set. Deliberately
    /// does NOT sync — the CaptureManager's bounded, backoff-aware drain remains the SOLE upload
    /// coordinator.
    ///
    /// DURABLE STATUS CACHE (2026-07-17, WS-B). This pass USED to re-derive every hydrated
    /// capture's segment/sync/byte state by enumerating its thousands of segment files + `.ack`
    /// markers EVERY launch — the `capture-status-warm-n128` storm (avg 180s, max 1780s on a
    /// backlogged device). Now, when a per-capture status cache is present + valid, it publishes
    /// that snapshot and SKIPS the directory scan entirely. Only a cache MISS or a CORRUPT cache
    /// falls through to the full scan (which then persists a fresh clean cache). Every segment
    /// mutation (append/ack/bulk-ack/prune/poison) invalidates the cache, so a stale snapshot is
    /// never served. The cache is DISPLAY-ONLY: the upload path still reads the durable
    /// `.upload-watermark` file + the real `.ack` files, so a stale cache can NEVER re-upload an
    /// already-ACK'd segment or lose audio.
    /// Warm this capture's status once and publish it. Idempotent PER INSTANCE — re-armed
    /// only when a segment mutation invalidates the durable cache (`invalidateStatusCache`),
    /// so a re-warm of an UNCHANGED capture (a merge, a refresh, a relaunch scroll) does no
    /// rescan and no publish. This is the change-token half of the list-open warm-flood fix
    /// (2026-07-20): "warm only NEW or CHANGED captures, not all N on every pass."
    public func warmStatus() {
        guard !hasWarmed else { return }
        hasWarmed = true
        publish(warmedSnapshot())
    }

    /// Whether this instance has already warmed AND nothing has changed since. Flipped back
    /// to `false` by `invalidateStatusCache()` — the same signal that dirties the durable
    /// cache on every segment mutation — so a genuinely-changed capture warms again while an
    /// unchanged one stays a no-op.
    private var hasWarmed = false

    /// Compute the warm status OFF the main actor WITHOUT publishing. The owner batches many
    /// of these and applies them in ONE main-actor hop (`applyWarmedStatus`), instead of one
    /// `DispatchQueue.main.async` @Published write per capture — that per-capture publish
    /// storm (N SwiftUI card invalidations dispatched onto main in a burst) IS the
    /// `capture-status-warm-n<N>` main-thread stall MetricKit reports on a big library.
    /// Cache-hit returns the snapshot; a miss does the one-time scan and persists a clean
    /// cache, exactly as the publishing path would.
    public func warmedSnapshot() -> CaptureStatus {
        if let cached = loadStatusCache() { return statusFromCache(cached) }
        ensureWatermarkLoaded()
        let s = computeStatus()
        persistStatusCache(s, watermark: uploadWatermark())
        return s
    }

    /// Apply a status computed off-main by `warmedSnapshot()`. Marks the instance warmed and
    /// publishes — which (see `publish`) writes the `@Published` status ONLY when it actually
    /// changed, so a batch of unchanged re-warms costs zero SwiftUI invalidations. Intended to
    /// be called on the main thread inside the owner's single batched main-actor hop.
    public func applyWarmedStatus(_ s: CaptureStatus) {
        hasWarmed = true
        publish(s)
    }

    // MARK: durable per-capture status cache (launch warm stat-storm fix, WS-B)

    /// The persisted snapshot of a warm scan: enough to publish the list/banner without
    /// re-enumerating segment + `.ack` files. `v` is a schema tag so a shape change auto-
    /// invalidates every on-disk cache. DISPLAY-ONLY — never drives the upload watermark.
    struct StatusCache: Codable, Sendable {
        static let schema = 1
        var v: Int
        var totalSegments: Int
        var syncedSegments: Int
        var bytes: Int
        var watermark: Int64
    }

    private func statusCacheURL() -> URL { dir.appendingPathComponent(".status-cache.json") }

    /// Load the durable status cache IF present + decodable + current-schema; nil on any
    /// doubt (missing / corrupt / schema mismatch) so the caller falls back to a full scan.
    /// Never throws — correctness prefers a rescan over trusting a questionable cache.
    private func loadStatusCache() -> StatusCache? {
        guard let data = try? Data(contentsOf: statusCacheURL()),
              let c = try? JSONDecoder().decode(StatusCache.self, from: data),
              c.v == StatusCache.schema else { return nil }
        return c
    }

    /// Rebuild a `CaptureStatus` from the cached counts. Warm runs on RELOADED (non-streaming)
    /// captures, so `streaming` is false and the stage is derived from the counts exactly as
    /// `computeStatus` would with `streaming == false`; `lastSyncError` is cleared (a fresh
    /// launch has attempted no sync yet).
    private func statusFromCache(_ c: StatusCache) -> CaptureStatus {
        var s = status
        s.totalSegments = c.totalSegments
        s.syncedSegments = c.syncedSegments
        s.bytes = c.bytes
        s.streaming = false
        s.lastSyncError = nil
        s.stage = c.totalSegments == 0 ? .savedOnPhone
            : (c.syncedSegments == c.totalSegments ? .savedToComputer : .savedOnPhone)
        return s
    }

    /// Persist a clean status cache from a freshly-SCANNED status (called only after a real
    /// warm scan). Skipped for a streaming capture (warm never runs on the active one, but a
    /// streaming snapshot must never be cached as terminal). Atomic write.
    private func persistStatusCache(_ s: CaptureStatus, watermark: Int64) {
        guard !s.streaming else { return }
        let c = StatusCache(v: StatusCache.schema, totalSegments: s.totalSegments,
                            syncedSegments: s.syncedSegments, bytes: s.bytes, watermark: watermark)
        guard let data = try? JSONEncoder().encode(c) else { return }
        _ = try? performDurableMutation {
            try data.write(to: statusCacheURL(), options: [.atomic])
        }
    }

    /// Invalidate (delete) the durable status cache — called at EVERY segment mutation so the
    /// next warm pass rescans instead of serving a stale snapshot. Cheap unlink; no-op if absent.
    private func invalidateStatusCache() {
        hasWarmed = false   // a real segment change re-arms warmStatus (change-token semantics)
        _ = performDurableMutation {
            try? FileManager.default.removeItem(at: statusCacheURL())
        }
    }

    /// Nonisolated invalidation for an OUT-OF-INSTANCE mutation (the retention audio prune
    /// deletes a capture's segment files directly on disk, without the live WAL object). Keeps
    /// the cache honest when segments vanish underneath a not-yet-hydrated capture.
    public static func invalidateStatusCache(captureDir: URL) {
        try? FileManager.default.removeItem(at: captureDir.appendingPathComponent(".status-cache.json"))
    }

    /// `baseDir` defaults to the app's Documents dir (persists across launches).
    public init(captureId: String,
                target: DoorTarget,
                baseDir: URL? = nil,
                binding: CaptureAccountScope.AccountBinding? = nil,
                chunkFrames: Int = 50,            // ~1s at Omi's ~50 frames/s
                session: URLSession = URLSession(configuration: .ephemeral),
                log: DoorLog? = nil,
                upload: (@Sendable (UInt64, Data) async throws -> Void)? = nil) {
        self.captureId = captureId
        self.target = target
        self.session = session
        self.log = log
        self.chunkFrames = chunkFrames
        self.uploadOverride = upload
        io.setSpecific(key: ioKey, value: true)
        let currentBinding = CaptureAccountScope.currentAccountBinding()
        let root = baseDir ?? binding?.root
            ?? currentBinding?.root ?? CaptureWAL.documentsCaptures()
        if let binding {
            self.accountBinding =
                binding.root.standardizedFileURL == root.standardizedFileURL
                    ? binding
                    : nil
        } else {
            self.accountBinding =
                currentBinding?.root.standardizedFileURL
                        == root.standardizedFileURL
                    ? currentBinding
                    : CaptureAccountScope.binding(forExplicitRoot: root)
        }
        self.dir = root.appendingPathComponent(captureId, isDirectory: true)
        self.status = CaptureStatus(id: captureId, stage: .recording, totalSegments: 0,
                                    syncedSegments: 0, bytes: 0, startedAt: startedAt,
                                    streaming: false, lastSyncError: nil)
        _ = try? performDurableMutation {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        // NO eager segment scan here — see the LAZY SEGMENT SCAN note above. The watermark
        // and next-append seq are derived on first use; the launch warm pass fills status.
    }

    public static func documentsCaptures() -> URL {
        // The root is account-scoped; CaptureAccountScope owns resolution and migration.
        CaptureAccountScope.currentRoot()
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
        syncOnIO { self.flushLocked(); self.streaming = false }
        publish()
    }

    /// Synchronous flush barrier (waits for queued appends — `io` is serial — then
    /// flushes the remainder). Lets tests put every frame on disk before syncing.
    public func flushAndWait() {
        syncOnIO { self.flushLocked() }
        publish()
    }

    private func syncOnIO(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: ioKey) == true {
            operation()
        } else {
            io.sync(execute: operation)
        }
    }

    /// Every retained WAL mutation re-enters the immutable account binding's
    /// admission door. The shared lease is atomic/memory-only on the producer path,
    /// so a deletion in another process cannot race a segment, ACK, watermark, or
    /// status-cache publication after revoking the captured epoch.
    private func performDurableMutation<Result>(
        _ mutation: () throws -> Result
    ) rethrows -> Result? {
        guard let accountBinding else { return nil }
        return try CaptureAccountScope.perform(as: accountBinding) { _ in
            try mutation()
        }
    }

    // MARK: segment write (durable-on-phone)

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        ensureNextSeqLoadedOnIO()   // derive the resume seq before the first append (io queue)
        let seq = nextSeq; nextSeq += 1
        let body = CaptureWAL.encodeSegment(buffer)
        buffer.removeAll(keepingCapacity: true)
        let url = dir.appendingPathComponent(CaptureWAL.segName(seq))
        do {
            guard try performDurableMutation({
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try body.write(to: url, options: [.atomic]) // temp + atomic rename
                return true
            }) == true else {
                log?.warn(
                    "capture \(captureId): rejected WAL segment \(seq) for stale account binding")
                return
            }
            invalidateStatusCache()   // a new segment changes total/bytes → force a rescan next warm
            log?.info("capture \(captureId): wrote segment \(seq) (\(body.count)B) to WAL")
        } catch {
            log?.error("capture \(captureId): WAL write seg \(seq) failed: \(error.localizedDescription)")
        }
    }

    /// Segment encoding: length-prefixed frames so boundaries survive for decode.
    public static func encodeSegment(_ frames: [Data]) -> Data {
        var out = Data()
        for f in frames {
            var len = UInt32(f.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(f)
        }
        return out
    }

    /// Inverse of `encodeSegment`: split a stored segment back into its raw Opus
    /// frames. Tolerant of a torn tail (a truncated final frame is dropped) — the
    /// local brain must be able to transcribe whatever survived.
    public static func decodeSegment(_ data: Data) -> [Data] {
        var frames: [Data] = []
        var i = data.startIndex
        while data.distance(from: i, to: data.endIndex) >= 4 {
            let len = data[i..<data.index(i, offsetBy: 4)].reduce(0) { ($0 << 8) | UInt32($1) }
            let start = data.index(i, offsetBy: 4)
            guard len > 0, data.distance(from: start, to: data.endIndex) >= Int(len) else { break }
            let end = data.index(start, offsetBy: Int(len))
            frames.append(Data(data[start..<end]))
            i = end
        }
        return frames
    }

    public static func segName(_ seq: UInt64) -> String { String(format: "seg-%012llu.opus", seq) }
    private func ackURL(_ segURL: URL) -> URL { segURL.deletingPathExtension().appendingPathExtension("ack") }

    // MARK: sync (mark synced ONLY on the door's 200 ACK)

    /// Drain unsynced segments to the door, AT MOST `maxSegmentsPerSync` per pass (so a
    /// huge backlog drains steadily, not in a storm). Re-entrant-safe; segments that fail
    /// stay pending and are retried on the next call. Returns the outcome so the owner's
    /// bounded-retry drain can back off on `.failed` and STOP on `.authExpired` (a 401 ⇒
    /// the bearer is an expired id_token; retrying with it just storms the door).
    @discardableResult
    public func sync() async -> SyncOutcome {
        let pending = pendingSegmentURLs()
        guard !pending.isEmpty else { lastError = nil; publish(); return .idle }
        var jobs: [(seq: UInt64, url: URL, bytes: Data)] = []
        jobs.reserveCapacity(min(Self.maxSegmentsPerSync, pending.count))
        for (seq, segURL) in pending.prefix(Self.maxSegmentsPerSync) {
            // The segment's OWN file must be readable. A missing/corrupt file is
            // unrecoverable — retrying can never succeed — so it's permanent poison.
            // The audio that remains is KEPT (the owner writes a durable marker, it
            // never deletes), but this poisoned capture stops wedging the drain.
            do {
                let bytes = try Data(contentsOf: segURL)
                jobs.append((seq, segURL, bytes))
            } catch {
                lastError = "segment \(seq) unreadable: \((error as NSError).localizedDescription)"
                log?.error("capture \(captureId): segment \(seq) file missing/corrupt — permanent poison, retiring (audio kept)")
                invalidateStatusCache()   // poison changes the capture's terminal state → rescan next warm
                publish()
                return .poisoned(seq: seq, reason: "segment file missing/corrupt")
            }
        }

        var uploaded = 0
        var firstTransientError: String?
        var firstPoison: (seq: UInt64, reason: String)?
        var sawAuthExpired = false

        await withTaskGroup(of: SegmentUploadResult.self) { group in
            var next = 0
            let initial = min(Self.maxConcurrentSegmentUploads, jobs.count)
            for _ in 0..<initial {
                let job = jobs[next]
                next += 1
                group.addTask { [self] in await uploadPreparedSegment(seq: job.seq, body: job.bytes) }
            }

            while let result = await group.next() {
                switch result {
                case .success(let seq):
                    guard let job = jobs.first(where: { $0.seq == seq }) else { break }
                    do {
                        guard try performDurableMutation({
                            try Data().write(
                                to: ackURL(job.url),
                                options: [.atomic])
                            return true
                        }) == true else {
                            firstTransientError =
                                "ACK rejected for stale account binding"
                            continue
                        }
                        advanceWatermark(throughAcked: seq)                        // durable resume point moves forward
                        invalidateStatusCache()   // synced count/watermark changed → rescan next warm
                        uploaded += 1
                        log?.info("capture \(captureId): segment \(seq) ACK'd by desktop (saved to computer)")
                        publish()
                    } catch {
                        firstTransientError = "ack marker write failed for segment \(seq): \((error as NSError).localizedDescription)"
                    }
                case .authExpired(let seq):
                    sawAuthExpired = true
                    lastError = "unauthorized (id_token expired)"
                    log?.warn("capture \(captureId): segment \(seq) rejected 401 (token expired) — stopping uploads, re-auth required")
                    group.cancelAll()
                case .permanent(let seq, let status):
                    if firstPoison == nil {
                        firstPoison = (seq, "door rejected HTTP \(status)")
                    }
                    lastError = "door permanently rejected segment \(seq): HTTP \(status)"
                    log?.error("capture \(captureId): segment \(seq) permanently rejected (HTTP \(status)) — retiring (audio kept)")
                    group.cancelAll()
                case .transient(let seq, let message):
                    if firstTransientError == nil {
                        firstTransientError = message
                    }
                    lastError = message
                    log?.warn("capture \(captureId): segment \(seq) not synced (\(message)) — staying pending, will retry")
                }

                if !sawAuthExpired, firstPoison == nil, firstTransientError == nil, next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { [self] in await uploadPreparedSegment(seq: job.seq, body: job.bytes) }
                }
            }
        }

        if sawAuthExpired {
            publish()
            return .authExpired
        }
        if let poison = firstPoison {
            invalidateStatusCache()   // permanent-poison retire changes terminal state → rescan next warm
            publish()
            return .poisoned(seq: poison.seq, reason: poison.reason)
        }
        if let error = firstTransientError {
            lastError = error
            publish()
            return .failed
        }
        lastError = nil
        return uploaded > 0 ? .progressed : .idle
    }

    private enum SegmentUploadResult: Sendable {
        case success(seq: UInt64)
        case authExpired(seq: UInt64)
        case permanent(seq: UInt64, status: Int)
        case transient(seq: UInt64, message: String)
    }

    private func uploadPreparedSegment(seq: UInt64, body: Data) async -> SegmentUploadResult {
        do {
            try await upload(seq: seq, body: body)
            return .success(seq: seq)
        } catch DoorError.unauthorized {
            return .authExpired(seq: seq)
        } catch DoorError.http(let status) where CaptureWAL.isPermanentRejection(status) {
            return .permanent(seq: seq, status: status)
        } catch {
            return .transient(seq: seq, message: (error as NSError).localizedDescription)
        }
    }

    /// POST one segment. Throws on any non-200 so the segment stays pending. In
    /// remote mode the door lives behind the relay tunnel, so the upload goes E2E
    /// through RelayHTTP (a plain POST to the nominal baseURL — the relay's HTTP
    /// control port — has no /foundryx/capture route and 404s).
    private func upload(seq: UInt64, body: Data) async throws {
        if let uploadOverride { try await uploadOverride(seq, body); return }
        let headers = ["X-Capture-Id": captureId, "X-Capture-Seq": String(seq)]
        if let relay = target.relay {
            let resp = try await RelayHTTP.roundTrip(
                relay: relay, bearer: target.bearer, method: "POST",
                path: "/foundryx/capture", extraHeaders: headers,
                contentType: "application/octet-stream", body: body,
                session: session, log: log, useMux: target.useMux)
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

    // MARK: bulk-ACK (the resync handshake, capture-sync AC1)

    /// Bulk-mark segments ACK'd from the door's resync handshake: the door reported
    /// it ALREADY durably stores `seqs` (its manifest's `segment_seqs`), so write the
    /// same `.ack` markers a 200 upload ACK would — recovering ACKs lost to a tunnel
    /// drop mid-drain, so those segments are never re-uploaded. Only segments present
    /// on disk are marked (a door seq we don't hold is ignored); already-ACK'd
    /// segments are untouched. Advances + persists the upload watermark over the new
    /// contiguous ACK'd run, exactly as live ACKs do. Returns the number of NEWLY
    /// marked segments so the owner can log the resync savings.
    @discardableResult
    public func bulkMarkSynced(_ seqs: [UInt64]) -> Int {
        let doorSeqs = Set(seqs)
        guard !doorSeqs.isEmpty else { return 0 }
        var newlyMarked = 0
        for (seq, segURL) in allSegmentURLs() where doorSeqs.contains(seq) {
            let ack = ackURL(segURL)
            guard !FileManager.default.fileExists(atPath: ack.path) else { continue }
            do {
                guard try performDurableMutation({
                    try Data().write(to: ack, options: [.atomic])
                    return true
                }) == true else { continue }
                newlyMarked += 1
            } catch {
                log?.warn("capture \(captureId): bulk-ACK seq \(seq) marker write failed: \(error.localizedDescription)")
            }
        }
        guard newlyMarked > 0 else { return 0 }
        advanceWatermarkOverContiguousAcks()
        invalidateStatusCache()   // bulk-ACK changed the synced count/watermark → rescan next warm
        publish()
        return newlyMarked
    }

    /// Advance the watermark over whatever contiguous `.ack` run now starts at
    /// `watermark + 1` (bulk-ACK can fill holes anywhere, not just the next seq),
    /// persisting it. Monotonic — never moves backward.
    private func advanceWatermarkOverContiguousAcks() {
        ensureWatermarkLoaded()
        wmLock.lock()
        var next = UInt64(watermark + 1)
        while FileManager.default.fileExists(
            atPath: ackURL(dir.appendingPathComponent(CaptureWAL.segName(next))).path) {
            watermark = Int64(next); next += 1
        }
        let w = watermark
        wmLock.unlock()
        persistWatermark(w)
    }

    // MARK: upload watermark (durable resume point — never re-send an ACK'd segment)

    private func watermarkURL() -> URL { dir.appendingPathComponent(".upload-watermark") }

    /// The current upload watermark (highest contiguously-ACK'd seq; −1 ⇒ none yet).
    /// Triggers the one-time lazy watermark load — so `computeStatus`, `pendingSegmentURLs`,
    /// and any direct caller resume from the true durable point, never the −1 default.
    public func uploadWatermark() -> Int64 {
        ensureWatermarkLoaded()
        wmLock.lock(); defer { wmLock.unlock() }; return watermark
    }

    /// Load the persisted watermark, else DERIVE it from the on-disk `.ack` markers
    /// (the highest contiguous run of ACK'd seqs from 0) so a pre-existing / stuck
    /// capture resumes correctly. Persists the derived value. Called once at load.
    private func loadOrDeriveWatermark() {
        if let data = try? Data(contentsOf: watermarkURL()),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let v = Int64(s) {
            wmLock.lock(); watermark = v; wmLock.unlock()
            return
        }
        let acked = Set(allSegmentURLs()
            .filter { FileManager.default.fileExists(atPath: ackURL($0.1).path) }
            .map { $0.0 })
        var w: Int64 = -1
        var next: UInt64 = 0
        while acked.contains(next) { w = Int64(next); next += 1 }   // contiguous run from 0
        wmLock.lock(); watermark = w; wmLock.unlock()
        persistWatermark(w)
    }

    private func persistWatermark(_ v: Int64) {
        _ = try? performDurableMutation {
            try Data(String(v).utf8).write(
                to: watermarkURL(), options: [.atomic])
        }
    }

    /// Advance the watermark over a freshly-ACK'd seq (and any contiguous already-ACK'd
    /// successors), persisting it. Called after each 200 ACK; uploads are in-order so
    /// `seq == watermark + 1` normally. Monotonic — never moves backward.
    private func advanceWatermark(throughAcked seq: UInt64) {
        ensureWatermarkLoaded()
        wmLock.lock()
        guard Int64(seq) == watermark + 1 else { wmLock.unlock(); return }
        watermark = Int64(seq)
        var next = seq + 1
        while FileManager.default.fileExists(
            atPath: ackURL(dir.appendingPathComponent(CaptureWAL.segName(next))).path) {
            watermark = Int64(next); next += 1
        }
        let w = watermark
        wmLock.unlock()
        persistWatermark(w)
    }

    /// A door HTTP status that will NEVER succeed on retry ⇒ permanent poison. 401 is
    /// handled separately (re-auth). 408 (request timeout), 429 (rate-limit) and ALL
    /// 5xx are TRANSIENT (server busy / down / throttling) — those keep retrying, so a
    /// briefly-unreachable or throttled large capture is never discarded.
    public static func isPermanentRejection(_ status: Int) -> Bool {
        (400..<500).contains(status) && status != 401 && status != 408 && status != 429
    }

    // MARK: status

    /// Synchronous status from disk — no `@Published` write. For tests + sync().
    public func snapshot() -> CaptureStatus { computeStatus() }

    // MARK: main-thread segment-enumeration probe (build-286 drain-hang regression seam)
    //
    // The dominant remaining field hang (15/22 build-286 `stallstack` samples, dSYM
    // 60BD8356): the drain GATE called `snapshot()` — i.e. `computeStatus()`, a full
    // on-disk segment enumeration (`allSegmentURLs()`) — for EVERY capture on the main
    // actor, every 5s tick. On a 212-capture backlogged library that O(captures ×
    // segments) directory/stat storm pinned `com.apple.main-thread` with nav-stalls to
    // 4161ms. The fix reads the already-@Published, in-memory `status.pendingSegments`
    // in the gate instead, so it does ZERO disk enumeration per capture. This counter
    // pins the pathology as a HARD INTEGER — `computeStatus()` calls made while ON the
    // main thread — exactly like CaptureManager's `mainThread*DiskOpsForTests` probes
    // (nonisolated + NSLock, machine-independent, can't flake into green).
    nonisolated(unsafe) private static let _computeStatusProbeLock = NSLock()
    nonisolated(unsafe) private static var _mainThreadComputeStatus = 0
    private static func noteMainThreadComputeStatus() {
        guard Thread.isMainThread else { return }
        _computeStatusProbeLock.lock(); _mainThreadComputeStatus += 1; _computeStatusProbeLock.unlock()
    }
    /// Count of synchronous `computeStatus()` (segment-enumeration) calls made on the main
    /// thread. The drain gate must hold this at 0 across a full drain cycle.
    nonisolated static var mainThreadComputeStatusCallsForTests: Int {
        _computeStatusProbeLock.lock(); defer { _computeStatusProbeLock.unlock() }; return _mainThreadComputeStatus
    }
    /// Reset the probe — call immediately before a measured drain cycle.
    nonisolated static func resetMainThreadComputeStatusCallsForTests() {
        _computeStatusProbeLock.lock(); _mainThreadComputeStatus = 0; _computeStatusProbeLock.unlock()
    }

    /// Recompute + republish the status from disk. Used after the retention pass
    /// prunes a capture's segment files, so the card reflects the pruned state.
    public func refreshStatus() { publish() }

    /// Per-seq segment sizes + ACK knowledge, filled INCREMENTALLY — segment files are
    /// immutable once written and an ACK never un-happens, so each needs at most one
    /// stat ever. The old full rescan (attributesOfItem + fileExists on EVERY segment,
    /// every status pass) is what Apple's bug_type-328 hang reports caught freezing the
    /// main thread 2-9s on 4000-segment backlogged captures (2026-07-12).
    private var seqBytes: [UInt64: Int] = [:]
    private var seqAcked: Set<UInt64> = []
    private let statusCacheLock = NSLock()

    private func computeStatus() -> CaptureStatus {
        CaptureWAL.noteMainThreadComputeStatus()   // regression probe: the drain gate must make ZERO of these on main
        let all = allSegmentURLs()
        let wm = uploadWatermark()
        statusCacheLock.lock()
        defer { statusCacheLock.unlock() }
        var syncedCount = 0
        var byteCount = 0
        var current = Set<UInt64>()
        current.reserveCapacity(all.count)
        for (seq, u) in all {
            current.insert(seq)
            // ACK: at/below the durable watermark counts as synced by definition;
            // otherwise stat the .ack marker once and remember it forever.
            if Int64(seq) <= wm || seqAcked.contains(seq) {
                syncedCount += 1
            } else if FileManager.default.fileExists(atPath: ackURL(u).path) {
                seqAcked.insert(seq)
                syncedCount += 1
            }
            // Bytes: read each immutable segment's size exactly once, from the
            // SIZE-ONLY resource value (prefetched by allSegmentURLs' bulk
            // enumeration). NEVER attributesOfItem — that fetches EXTENDED
            // ATTRIBUTES (getxattr/listxattr), the leaf of every bug_type-328
            // hang report (2-9s main-thread freezes on backlogged captures,
            // builds 135/142/143/164). fileSizeKey is a plain getattrlist.
            if let known = seqBytes[seq] {
                byteCount += known
            } else if let n = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                seqBytes[seq] = n
                byteCount += n
            }
        }
        // Retention pruning deletes segment files — drop their cache entries so the
        // byte total stays exact (cheap set math, no syscalls).
        if seqBytes.count > current.count {
            seqBytes = seqBytes.filter { current.contains($0.key) }
            seqAcked = seqAcked.intersection(current)
        }
        // NOTE: do NOT wrap this in `io.sync` — `publish()` is sometimes called from
        // INSIDE the io queue (e.g. `beginStreaming`), so a reentrant `io.sync` traps.
        // The real fix for the cross-drain race that crashed here is the single-drain
        // guard in CaptureManager.drainPending (no two `computeStatus` run concurrently).
        // An empty WAL is "recording" ONLY while genuinely streaming. A dead capture
        // with zero segments (ended, orphaned, or audio pruned by retention) must NOT
        // claim to be recording — that's how 6-day-old cards read "Recording · 0/0"
        // with a live green dot (deep-review finding, 2026-07-07).
        let stage: CaptureStage = all.isEmpty ? (streaming ? .recording : .savedOnPhone)
            : (syncedCount == all.count && !streaming ? .savedToComputer : .savedOnPhone)
        var s = status
        s.totalSegments = all.count
        s.syncedSegments = syncedCount
        s.bytes = byteCount
        s.streaming = streaming
        s.stage = stage
        let incomplete = dir.appendingPathComponent(".incomplete")
        s.lastSyncError = (try? String(contentsOf: incomplete, encoding: .utf8)) ?? lastError
        return s
    }

    private func publish() {
        publish(computeStatus())
    }

    /// Publish a pre-computed status (the warm cache-hit path publishes a cached snapshot
    /// WITHOUT calling `computeStatus`, so no segment enumeration happens).
    private func publish(_ s: CaptureStatus) {
        let apply: () -> Void = { [weak self] in
            // Skip the @Published write (and the SwiftUI invalidation it triggers) when the
            // status is UNCHANGED — a re-warm/refresh that computed the same snapshot costs
            // nothing on the main thread. `CaptureStatus` is Equatable.
            guard let self, s != self.status else { return }
            self.status = s
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Segments still to upload: everything ABOVE the durable watermark that lacks an
    /// `.ack`. Anchoring on the watermark means a giant capture skips re-stat'ing
    /// thousands of already-ACK'd segments every pass (and never re-sends them) — the
    /// resume is O(remaining), not O(total).
    private func pendingSegmentURLs() -> [(UInt64, URL)] {
        let wm = uploadWatermark()
        return allSegmentURLs().filter {
            Int64($0.0) > wm && !FileManager.default.fileExists(atPath: ackURL($0.1).path)
        }
    }

    private func allSegmentURLs() -> [(UInt64, URL)] {
        // Prefetch the file SIZE in the single bulk enumeration (getattrlist under
        // the hood) so `computeStatus` reads it from the URL's cached resource
        // values instead of stat'ing each segment separately. Combined with the
        // per-seq size memo, this means no per-file syscall on the hot path.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { $0.pathExtension == "opus" }
            .compactMap { url -> (UInt64, URL)? in
                let name = url.deletingPathExtension().lastPathComponent  // seg-000…000
                guard let seqStr = name.split(separator: "-").last, let seq = UInt64(seqStr) else { return nil }
                return (seq, url)
            }
            .sorted { $0.0 < $1.0 }
    }

}
