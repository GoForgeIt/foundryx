// LiveTranscriber — the FAST / PROVISIONAL on-device live-transcription layer.
//
// This runs ALONGSIDE the durable capture pipeline and is deliberately additive:
// it is a side-effect-only consumer of already-decoded PCM (see FrameRouter.onPCM),
// it NEVER touches the WAL/upload critical path, and every failure is non-fatal to
// capture. The authoritative transcript still comes from Kiln (door → Lore → Kiln);
// the live transcript is an ephemeral PREVIEW shown while you speak, then replaced
// by Kiln's text when it lands.
//
// On iOS/macOS 26 the real implementation uses Apple's on-device SpeechAnalyzer /
// SpeechTranscriber (long-form, fully on-device). On older OSes the factory returns
// nil and capture proceeds exactly as before — no live preview. See the design doc
// `foundryx-hearth/proposals/20260626T0800_on_device_live_transcription.md`.

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

/// A display snapshot of the live, on-device PROVISIONAL transcript for ONE
/// conversation: the stable finalized body plus the still-settling volatile tail
/// (rendered dimmed/faded so the user sees it building as they speak).
public struct LiveTranscript: Sendable, Equatable {
    /// Stable, append-only finalized text.
    public var finalizedText: String
    /// The still-settling partial at the end (render faded/italic).
    public var volatileTail: String
    /// The session has finished (conversation closed).
    public var isComplete: Bool

    public init(finalizedText: String = "", volatileTail: String = "", isComplete: Bool = false) {
        self.finalizedText = finalizedText
        self.volatileTail = volatileTail
        self.isComplete = isComplete
    }

    public static let empty = LiveTranscript()

    /// The full string to display: finalized body + the faded settling tail.
    public var displayText: String {
        if volatileTail.isEmpty { return finalizedText }
        if finalizedText.isEmpty { return volatileTail }
        return finalizedText + " " + volatileTail
    }

    public var isEmpty: Bool { finalizedText.isEmpty && volatileTail.isEmpty }
}

/// One live, on-device transcription session for ONE conversation. Side-effect-only:
/// consumes already-decoded PCM, never touches the WAL/upload path. Created per
/// `beginSession()`, finished per `endSession()`. All failures are non-fatal to
/// capture (the owner just disables live preview for the session + logs).
public protocol LiveTranscribing: AnyObject, Sendable {
    /// Continuously-updated display transcript (finalized body + volatile tail).
    var transcript: AsyncStream<LiveTranscript> { get }

    /// Begin the session. Throws if the model/locale is unavailable (caller disables
    /// live preview + logs; capture is unaffected).
    func start() async throws

    /// Feed one decoded PCM buffer (from the shared Opus decode in FrameRouter).
    /// Non-blocking: enqueues and returns; drops on overflow. NEVER throws into the
    /// frame path.
    func append(_ pcm: AVAudioPCMBuffer)

    /// Flush + finalize at conversation close; returns the settled provisional text.
    func finish() async -> String
}

/// A factory the CaptureManager uses to make one transcriber per conversation.
/// Returns nil when live transcription is unavailable (older OS, capability gate),
/// in which case capture proceeds with no live preview.
public typealias LiveTranscriberFactory = @Sendable () -> LiveTranscribing?

/// Supplies the contextual vocabulary that biases the on-device recognizer toward our
/// domain terms + the user's entities/people/topics (so it hears "Kiln" not "kill in",
/// "Lore" not "lower"). Async so it can fetch a Lore-derived "top terms" list from the
/// door later; today it returns a hardcoded seed.
public typealias LiveVocabularyProvider = @Sendable () async -> [String]

/// Domain vocabulary biasing (Feature 1.B). Seeds the recognizer with our known proper
/// nouns so common homophones don't win. Applied via SpeechAnalyzer's `AnalysisContext`
/// (iOS 26) and `SFSpeechRecognitionRequest.contextualStrings` (the fallback).
public enum LiveVocabulary {
    /// Hardcoded seed of our domain proper nouns. Works today with no network.
    ///
    /// TODO: fetch the REAL, user-specific list (entities / people / topics) from a
    /// Lore-derived "top terms" door route when it exists, and merge it with this seed.
    /// The injectable `LiveVocabularyProvider` seam is where that fetch plugs in.
    public static let seed: [String] = [
        "FoundryX", "Foundry", "Kiln", "Lore", "Anvil", "Temper", "Omi",
        "Prometheus", "Prometheus Group", "Conductor", "GoForgeIt", "Hearth",
        "Grain", "Brine", "Crucible",
    ]

    /// The default provider (the seed list). Swap in a door-fetching provider later.
    public static func seedProvider() -> LiveVocabularyProvider { { seed } }
}

/// Device / OS / locale / model gate. `.ready` only when live STT can actually run.
public enum LiveTranscriptCapability: Equatable, Sendable {
    case ready
    case needsDownload
    case unsupportedLocale
    case unsupportedOS
    case unavailable(String)
}

/// Entry point for building the on-device live transcriber + checking capability.
public enum LiveTranscription {
    /// The default factory: builds the SpeechAnalyzer-backed transcriber on iOS/macOS
    /// 26 (the fast on-device long-form path), and falls back to an SFSpeechRecognizer
    /// on-device transcriber on iOS 16–25 / macOS 13–25. The App wires this into the
    /// CaptureManager; tests inject their own fake factory.
    public static func defaultFactory(locale: Locale = .current,
                                      vocabulary: @escaping LiveVocabularyProvider = LiveVocabulary.seedProvider())
        -> LiveTranscriberFactory {
        return {
            #if canImport(Speech)
            if #available(iOS 26.0, macOS 26.0, *) {
                return SpeechAnalyzerLiveTranscriber(locale: locale, vocabulary: vocabulary)
            }
            return SFSpeechLiveTranscriber(locale: locale, vocabulary: vocabulary)
            #else
            return nil
            #endif
        }
    }

    /// Capability probe (locale supported? model installed?). iOS/macOS 26 only;
    /// `.unsupportedOS` otherwise.
    public static func check(locale: Locale = .current) async -> LiveTranscriptCapability {
        #if canImport(Speech)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
                return .unsupportedLocale
            }
            let transcriber = SpeechTranscriber(locale: locale,
                                                transcriptionOptions: [],
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [])
            do {
                // A non-nil install request means the model isn't on the device yet.
                if try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) != nil {
                    return .needsDownload
                }
                return .ready
            } catch {
                return .unavailable((error as NSError).localizedDescription)
            }
        }
        #endif
        return .unsupportedOS
    }
}

#if canImport(Speech)
/// The real iOS/macOS 26 implementation: streams already-decoded PCM into Apple's
/// on-device SpeechAnalyzer + SpeechTranscriber and republishes volatile (settling)
/// and finalized results as a `LiveTranscript` stream.
@available(iOS 26.0, macOS 26.0, *)
public final class SpeechAnalyzerLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    public let transcript: AsyncStream<LiveTranscript>
    private let publish: AsyncStream<LiveTranscript>.Continuation

    private let locale: Locale
    private let vocabulary: LiveVocabularyProvider
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // Format conversion (Omi-decoded PCM → the analyzer's required format). Created
    // lazily from the first appended buffer's format. AVAudioConverter is not
    // thread-safe, but `append` is called serially off FrameRouter's serial source
    // queue, so a single converter is safe here.
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    // Accumulated display state, mutated only on the results task.
    private var finalizedText = ""

    public init(locale: Locale = .current,
                vocabulary: @escaping LiveVocabularyProvider = LiveVocabulary.seedProvider()) {
        self.locale = locale
        self.vocabulary = vocabulary
        var cont: AsyncStream<LiveTranscript>.Continuation!
        self.transcript = AsyncStream { cont = $0 }
        self.publish = cont
    }

    public func start() async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        self.transcriber = transcriber

        // One-time on-device model install if needed (the feature is opt-in by being
        // on a supported device; the asset is downloaded over the system's policy).
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }

        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Domain vocabulary biasing (Feature 1.B): seed the analysis context with our
        // proper nouns + (later) the user's entities so homophones don't win.
        let words = await vocabulary()
        if !words.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = words
            try? await analyzer.setContext(ctx)
        }

        // Bounded input stream: drop oldest on overflow so a slow analyzer never
        // backs up the (serial) frame path — provisional text missing a beat is fine.
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        self.inputBuilder = inputBuilder

        // Drain results: volatile (settling) vs finalized, republished as LiveTranscript.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText = self.appendSentence(self.finalizedText, piece)
                        self.publish.yield(LiveTranscript(finalizedText: self.finalizedText,
                                                          volatileTail: ""))
                    } else {
                        self.publish.yield(LiveTranscript(finalizedText: self.finalizedText,
                                                          volatileTail: piece))
                    }
                }
            } catch {
                // Mid-stream failure → stop publishing; capture is unaffected.
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
    }

    public func append(_ pcm: AVAudioPCMBuffer) {
        guard let analyzerFormat, let inputBuilder else { return }
        let buffer: AVAudioPCMBuffer
        if pcm.format == analyzerFormat {
            buffer = pcm
        } else {
            if converter == nil || converter?.inputFormat != pcm.format {
                converter = AVAudioConverter(from: pcm.format, to: analyzerFormat)
            }
            guard let converter, let out = Self.convert(pcm, with: converter, to: analyzerFormat) else { return }
            buffer = out
        }
        inputBuilder.yield(AnalyzerInput(buffer: buffer))
    }

    public func finish() async -> String {
        inputBuilder?.finish()
        inputBuilder = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        let text = finalizedText
        publish.yield(LiveTranscript(finalizedText: text, volatileTail: "", isComplete: true))
        publish.finish()
        return text
    }

    private func appendSentence(_ body: String, _ piece: String) -> String {
        let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return body }
        return body.isEmpty ? p : body + " " + p
    }

    /// Convert one PCM buffer to the analyzer's format. Best-effort: nil on failure
    /// (the frame is simply dropped from the provisional stream).
    private static func convert(_ input: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        final class Once { var fed = false }
        let once = Once()
        var err: NSError?
        let status = converter.convert(to: output, error: &err) { _, outStatus in
            if once.fed { outStatus.pointee = .noDataNow; return nil }
            once.fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || output.frameLength == 0 { return nil }
        return output
    }
}

/// The iOS 16–25 / macOS 13–25 fallback: on-device transcription via the classic
/// `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest`. Lower-fidelity than
/// SpeechAnalyzer and tuned for shorter utterances, but it still streams partial
/// (volatile) results we render in the fade ticker, and it honors `contextualStrings`
/// for the same domain-vocabulary biasing. Forces `requiresOnDeviceRecognition` so
/// nothing leaves the phone. Still PROVISIONAL — Kiln remains authoritative.
public final class SFSpeechLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    public let transcript: AsyncStream<LiveTranscript>
    private let publish: AsyncStream<LiveTranscript>.Continuation

    private let locale: Locale
    private let vocabulary: LiveVocabularyProvider
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalizedText = ""

    public init(locale: Locale = .current,
                vocabulary: @escaping LiveVocabularyProvider = LiveVocabulary.seedProvider()) {
        self.locale = locale
        self.vocabulary = vocabulary
        var cont: AsyncStream<LiveTranscript>.Continuation!
        self.transcript = AsyncStream { cont = $0 }
        self.publish = cont
    }

    public func start() async throws {
        let authorized: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
        guard authorized else { throw LiveTranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LiveTranscriberError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw LiveTranscriberError.noOnDeviceModel }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true          // volatile stream as you speak
        request.requiresOnDeviceRecognition = true         // never leaves the phone
        request.contextualStrings = await vocabulary()      // domain vocabulary biasing
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                self.finalizedText = text
                self.publish.yield(LiveTranscript(finalizedText: text, volatileTail: ""))
            } else {
                // SFSpeech revises the WHOLE utterance each partial; render it as the
                // volatile tail so it visibly self-corrects (the "guess then fix" feel).
                self.publish.yield(LiveTranscript(finalizedText: self.finalizedText, volatileTail: text))
            }
        }
    }

    public func append(_ pcm: AVAudioPCMBuffer) {
        request?.append(pcm)
    }

    public func finish() async -> String {
        request?.endAudio()
        task?.finish()
        let text = finalizedText
        publish.yield(LiveTranscript(finalizedText: text, volatileTail: "", isComplete: true))
        publish.finish()
        return text
    }
}

enum LiveTranscriberError: Error { case notAuthorized, unavailable, noOnDeviceModel }
#endif
