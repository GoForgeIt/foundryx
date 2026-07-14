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
    private let startedAt = Date()
    /// Test seam: when set, replaces the real door POST for each segment (so the
    /// drain/backoff/auth-expired paths are exercised deterministically, no network).
    private let uploadOverride: (@Sendable (UInt64, Data) async throws -> Void)?

    private let io = DispatchQueue(label: "foundryx.capture-wal")
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

    /// `baseDir` defaults to the app's Documents dir (persists across launches).
    public init(captureId: String,
                target: DoorTarget,
                baseDir: URL? = nil,
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
                        try Data().write(to: ackURL(job.url), options: [.atomic])   // 200 ACK ⇒ saved to computer
                        advanceWatermark(throughAcked: seq)                        // durable resume point moves forward
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
                try Data().write(to: ack, options: [.atomic])
                newlyMarked += 1
            } catch {
                log?.warn("capture \(captureId): bulk-ACK seq \(seq) marker write failed: \(error.localizedDescription)")
            }
        }
        guard newlyMarked > 0 else { return 0 }
        advanceWatermarkOverContiguousAcks()
        publish()
        return newlyMarked
    }

    /// Advance the watermark over whatever contiguous `.ack` run now starts at
    /// `watermark + 1` (bulk-ACK can fill holes anywhere, not just the next seq),
    /// persisting it. Monotonic — never moves backward.
    private func advanceWatermarkOverContiguousAcks() {
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
    public func uploadWatermark() -> Int64 { wmLock.lock(); defer { wmLock.unlock() }; return watermark }

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
        try? Data(String(v).utf8).write(to: watermarkURL(), options: [.atomic])
    }

    /// Advance the watermark over a freshly-ACK'd seq (and any contiguous already-ACK'd
    /// successors), persisting it. Called after each 200 ACK; uploads are in-order so
    /// `seq == watermark + 1` normally. Monotonic — never moves backward.
    private func advanceWatermark(throughAcked seq: UInt64) {
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

    private func scanExisting() {
        let segs = allSegmentURLs()
        if let maxSeq = segs.map({ $0.0 }).max() { nextSeq = maxSeq + 1 }
        loadOrDeriveWatermark()   // resume point: load, else derive from on-disk `.ack` markers
        publish()
        // NOTE: no auto-sync here on purpose. The CaptureManager's bounded, backoff-aware
        // drain is the SOLE upload coordinator. A per-WAL `Task { sync() }` on construction
        // meant a multi-day backlog spawned hundreds of UNBOUNDED concurrent uploads the
        // instant the app launched (a retry storm that pegged the device) — exactly the
        // bug this change fixes. Pending segments drain through the rate-limited drain.
    }
}
