// WhisperKitSTT — the REAL on-device speech engine behind the LocalSTT seam
// (onboarding track 20260705T1100, Phase 2; locked decision #2: WhisperKit for STT
// on essentially every modern iPhone — no MLX fallback anywhere).
//
// Pipeline: stored Opus frames → OpusPCMDecoder (48 kHz mono Int16, the same
// decoder the live-preview path uses) → AVAudioConverter down to WhisperKit's
// 16 kHz Float mono → WhisperKit.transcribe. The model (base) is fetched on first
// use — "setting up your private on-device brain"; model weights are the ONLY
// bytes that ever come IN, and no audio ever goes OUT.
//
// Lives in the App target (not FoundryXKit/SPM) so `swift test` never builds
// WhisperKit; tests drive the LocalSTT seam with a fake.

import Foundation
import AVFoundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit

public actor WhisperKitSTT: LocalSTT {
    private let modelName: String
    private var engine: WhisperKit?
    /// The folder the weights landed in — set only AFTER `WhisperKit.download` returns.
    ///
    /// It is NOT a "retry doesn't re-fetch" guarantee: on the stall path — the only path
    /// the retry button exists for — this is still nil, because the download never
    /// returned. Cheap retries come from Hugging Face's own per-file cache + `.incomplete`
    /// resume, not from this. What this DOES buy is skipping the whole seam after a
    /// build-phase failure.
    private var downloadedFolder: URL?
    /// The ONE in-flight `WhisperKit.download` for this variant (B2).
    ///
    /// Without this, a retry could enter `WhisperKit.download` while the stalled first
    /// attempt was still alive: two `HubFileDownloader`s then open the SAME `.incomplete`
    /// file for writing and `seekToEnd()`, so the file grows past `expectedSize` and the
    /// transfer throws. The oversized `.incomplete` is never deleted, so every subsequent
    /// launch resumes from the bogus offset and fails forever — a permanent, reinstall-only
    /// poisoning of the model cache. A retry now JOINS the live attempt instead (and is
    /// still bounded, because the retry brings its own fresh stall watchdog).
    private var downloadTask: Task<URL, any Error>?
    /// Fans the single download's progress out to every joined attempt.
    private let progressRelay = ProgressRelay()
    /// Set once a download attempt has failed in this process — see `purgeCorruptIncomplete`.
    private var hadDownloadFailure = false
    /// Main-actor status sink for the "setting up your private on-device brain"
    /// banner (nil = no UI, e.g. background use). Reported to as download/load
    /// proceed; only ever touched on the main actor.
    private let status: LocalBrainStatus?
    /// How long the setup may be STUCK before it fails honestly (track 20260722T1244).
    private let policy: BrainSetupPolicy

    public init(model: String = "base",
                status: LocalBrainStatus? = nil,
                policy: BrainSetupPolicy = .default) {
        self.modelName = model
        self.status = status
        self.policy = policy
    }

    /// Bounded, honest setup: the download is stall-watched (progress that stops
    /// ADVANCING for `stallTimeout` fails), the build is time-bounded, and a failure
    /// installs a working "Try again" on the banner — no relaunch. A slow-but-moving
    /// download is never killed.
    ///
    /// `[weak self]` matters (S6): the preparer is stored on this actor and the app
    /// re-creates the engine on every `MainTabs` remount. Capturing `self` strongly here
    /// made a cycle (engine → preparer → engine) that leaked an engine, a preparer, and
    /// any download still attached to them, every remount.
    private lazy var preparer: LocalBrainPreparer = LocalBrainPreparer(
        steps: LocalBrainPreparer.Steps(
            download: { [weak self] onProgress in
                guard let self else { throw WhisperKitSTTError.engineUnavailable }
                try await self.downloadWeights(onProgress)
            },
            build: { [weak self] in
                guard let self else { throw WhisperKitSTTError.engineUnavailable }
                try await self.buildEngine()
            }),
        policy: policy,
        status: status)

    /// WhisperKit runs wherever the app runs (iOS 17+ deployment target); the
    /// model download happens on first need (or an explicit `prewarm`).
    public nonisolated var isAvailable: Bool { true }

    /// Kick the model fetch/load NOW (call when the phone tier mounts) so the
    /// first recording isn't the first time ~150 MB downloads. Idempotent; safe to
    /// call repeatedly. Failures are surfaced on the banner, never fatal — the
    /// next transcribe retries.
    public func prewarm() async {
        _ = try? await loadEngine()
    }

    enum WhisperKitSTTError: Error, LocalizedError {
        case engineUnavailable
        public var errorDescription: String? { "the on-device speech model isn't ready" }
    }

    public func transcribe(opusFrames: [Data]) async throws -> String {
        try await PerfHook.timed("whisper-stt") {
            let samples = Self.pcm16k(from: opusFrames)
            guard !samples.isEmpty else { return "" }
            let whisper = try await self.loadEngine()
            let results = try await whisper.transcribe(audioArray: samples)
            return results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func loadEngine() async throws -> WhisperKit {
        if let engine {
            await report { $0.setReady() }
            return engine
        }
        // The preparer owns the phases, the stall watchdog, and the failure/retry
        // reporting; it throws if setup timed out, so the banner is never immortal.
        try await preparer.prepare()
        guard let engine else { throw WhisperKitSTTError.engineUnavailable }
        return engine
    }

    /// Download WITH progress into WhisperKit's default cache. Reports every real
    /// fraction so the stall watchdog can tell "slow" from "stuck".
    ///
    /// At most ONE `WhisperKit.download` for this variant is ever in flight (B2). A second
    /// caller — typically the user's "Try again" while the stalled first attempt is still
    /// alive — joins that attempt and receives its progress, rather than racing it into
    /// the same `.incomplete` file.
    private func downloadWeights(_ onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if downloadedFolder != nil { return }   // already resolved (e.g. a build-phase retry)

        let token = progressRelay.add(onProgress)
        defer { progressRelay.remove(token) }

        let task: Task<URL, any Error>
        if let existing = downloadTask {
            task = existing                      // join, never race
        } else {
            // Nothing of ours is writing the cache right now (a live task would have kept
            // `downloadTask` non-nil), so this is the only safe moment to self-heal.
            if hadDownloadFailure { Self.purgeIncompleteFiles(variant: modelName) }
            let relay = progressRelay
            let variant = modelName
            let started = Task<URL, any Error> {
                try await WhisperKit.download(
                    variant: variant,
                    progressCallback: { @Sendable progress in relay.emit(progress.fractionCompleted) })
            }
            downloadTask = started
            task = started
        }

        do {
            let folder = try await task.value
            downloadedFolder = folder
            if downloadTask == task { downloadTask = nil }
        } catch {
            hadDownloadFailure = true
            if downloadTask == task { downloadTask = nil }
            throw error
        }
    }

    /// Delete Hugging Face's resume scratch files for our variant.
    ///
    /// The poisoning this heals (B2): two concurrent writers can push an `.incomplete`
    /// past its `expectedSize`; the transfer then throws, and nothing ever removes the
    /// oversized file — `prepareCacheDestination` only creates it when ABSENT — so every
    /// later launch resumes from the bogus offset and fails identically, forever.
    ///
    /// We only ever read a path we own (WhisperKit's `downloadBase` default, which is
    /// `Documents/huggingface`) and only delete `*.incomplete` scratch files under our own
    /// repo cache: completed files have already been moved to their destination, so the
    /// most this can cost is re-fetching the partial bytes of ONE file, never the 150 MB.
    /// Deliberately called only after a failure in this process, so an ordinary
    /// cross-launch resume is left alone.
    private static func purgeIncompleteFiles(variant: String) {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let repoCache = documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download",
                                    isDirectory: true)
        guard let walker = fm.enumerator(at: repoCache,
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return }
        var removed = 0
        for case let url as URL in walker where url.pathExtension == "incomplete" {
            guard url.path.contains(variant) else { continue }
            do { try fm.removeItem(at: url); removed += 1 } catch { /* best effort */ }
        }
        if removed > 0 {
            print("[brain-setup] cleared \(removed) stale .incomplete resume file(s) for \"\(variant)\" — "
                  + "a previous attempt failed and its partial download could be corrupt")
        }
    }

    /// Build the engine from the local folder (download:false → no re-fetch).
    private func buildEngine() async throws {
        if engine != nil { return }
        let config = WhisperKitConfig(model: modelName,
                                      modelFolder: downloadedFolder?.path,
                                      download: false)
        engine = try await WhisperKit(config)
    }

    private func report(_ body: @escaping @MainActor (LocalBrainStatus) -> Void) async {
        guard let status else { return }
        await MainActor.run { body(status) }
    }

    /// Opus frames → 16 kHz mono Float samples (WhisperKit's input format).
    /// Decode at the canonical 48 kHz (the proven OpusPCMDecoder path), then
    /// resample 48k Int16 → 16k Float through AVAudioConverter.
    static func pcm16k(from opusFrames: [Data]) -> [Float] {
        let decoder = OpusPCMDecoder()
        let inFormat = decoder.format                              // 48k mono Int16
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return [] }
        var out: [Float] = []
        for frame in opusFrames {
            guard let pcm48 = decoder.decode(frame), pcm48.frameLength > 0 else { continue }
            let capacity = AVAudioFrameCount((Double(pcm48.frameLength) / 3.0).rounded(.up) + 16)
            guard let pcm16 = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { continue }
            var fed = false
            var err: NSError?
            converter.convert(to: pcm16, error: &err) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return pcm48
            }
            if err == nil, pcm16.frameLength > 0, let ch = pcm16.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(pcm16.frameLength)))
            }
        }
        return out
    }
}

/// Fans ONE download's progress out to every attempt currently joined to it (B2).
/// Lock-backed and synchronous: `HubApi` calls the progress handler from arbitrary
/// threads, and hopping to an actor there would reorder beats against the stall watchdog.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: @Sendable (Double) -> Void] = [:]
    private var nextToken = 0

    func add(_ handler: @escaping @Sendable (Double) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextToken += 1
        handlers[nextToken] = handler
        return nextToken
    }

    func remove(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        handlers[token] = nil
    }

    func emit(_ fraction: Double) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current { handler(fraction) }
    }
}
#endif
