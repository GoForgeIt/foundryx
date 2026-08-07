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

#if canImport(AVFoundation)
/// `AVAudioConverter` declares its input callback `@Sendable` even though conversion
/// invokes it synchronously. Own the non-Sendable PCM reference behind a lock and
/// vend it exactly once so the callback captures only a genuinely synchronized box.
private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var wasConsumed = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            guard !wasConsumed else { return nil }
            wasConsumed = true
            return buffer
        }
    }
}
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
    /// The WHOLE conversation to this point, bounded head+tail (see
    /// `RollingTitleContext`) — the source the rolling live TITLE derives from
    /// (track 20260717T1015). `finalizedText` is a display tail (last ~80 words);
    /// this keeps the conversation's head too. Titling-only: never rendered
    /// word-by-word (that path stays bounded by `renderedSegments(maxWords:)`).
    public var titleContext: String

    public init(finalizedText: String = "", volatileTail: String = "", isComplete: Bool = false,
                titleContext: String = "") {
        self.finalizedText = finalizedText
        self.volatileTail = volatileTail
        self.isComplete = isComplete
        self.titleContext = titleContext
    }

    public static let empty = LiveTranscript()

    /// The full string to display: finalized body + the faded settling tail.
    public var displayText: String {
        if volatileTail.isEmpty { return finalizedText }
        if finalizedText.isEmpty { return volatileTail }
        return finalizedText + " " + volatileTail
    }

    public var isEmpty: Bool { finalizedText.isEmpty && volatileTail.isEmpty }

    /// Word-level render decomposition for the faded-tail effect (Feature 2). Every
    /// FINALIZED word renders at full opacity (locked in); the trailing VOLATILE words
    /// are dimmed within a bounded `fadeWindow`, the NEWEST (last) word at `floorOpacity`,
    /// ramping back up to 1.0 — so the most-recent word is faintest and each word SNAPS
    /// to full opacity the moment the recognizer finalizes it (volatile → finalized).
    /// Pure (no SwiftUI) so the `LiveTranscriptTicker` just renders the result and a
    /// brine test can assert the opacities + that no words are dropped/duplicated.
    ///
    /// `maxWords` bounds the result to the most-recent N words (the tail). The live
    /// ticker only shows ~2 lines, but the full session's `finalizedText` grows without
    /// bound during continuous capture — and the UI folds one `Text` per segment into a
    /// nested `ConcatenatedTextStorage`, whose resolve recurses once per word. Past a few
    /// hundred words that overflows the 1 MB main-thread stack (the build-89/90 SIGSEGV)
    /// and pegs the widget's CPU budget. Capping the render to a tail keeps it O(1) in
    /// session length; the authoritative full transcript still lives in Lore/Kiln. `nil`
    /// = uncapped (unchanged behavior for existing callers/tests).
    public func renderedSegments(fadeWindow: Int = 3,
                                 floorOpacity: Double = 0.35,
                                 maxWords: Int? = nil) -> [LiveTranscriptSegment] {
        let finalWords = finalizedText.split(separator: " ").map(String.init)
        let volatileWords = volatileTail.split(separator: " ").map(String.init)
        var segs = finalWords.map { LiveTranscriptSegment(text: $0, opacity: 1.0) }
        let n = volatileWords.count
        if n > 0 {
            // Newest volatile word = faintest; ramp up to full over `fadeWindow` words.
            let window = max(1, fadeWindow)
            let step = (1.0 - floorOpacity) / Double(window)
            for (i, w) in volatileWords.enumerated() {
                let fromEnd = n - 1 - i                 // 0 = newest (last) volatile word
                let opacity = fromEnd >= window ? 1.0 : min(1.0, floorOpacity + Double(fromEnd) * step)
                segs.append(LiveTranscriptSegment(text: w, opacity: opacity, volatile: true))
            }
        }
        // Bound to the most-recent `maxWords` (keep the tail — newest words + volatile).
        if let maxWords, maxWords >= 0, segs.count > maxWords {
            segs = Array(segs.suffix(maxWords))
        }
        return segs
    }
}

/// One rendered run of the live transcript: a single word plus the opacity it should
/// render at. Finalized words are opacity `1.0` (locked in); the trailing volatile
/// word(s) are dimmed (the newest faintest) and marked `volatile` so the UI can also
/// italicize the still-settling tail. Word-level, not line-level (Feature 2).
public struct LiveTranscriptSegment: Sendable, Equatable {
    /// The word, without surrounding whitespace.
    public let text: String
    /// 1.0 = locked in (finalized); < 1.0 = still settling.
    public let opacity: Double
    /// True for the still-settling volatile tail words (render dimmed + italic).
    public let volatile: Bool

    public init(text: String, opacity: Double, volatile: Bool = false) {
        self.text = text
        self.opacity = opacity
        self.volatile = volatile
    }
}

/// The single shared bound for the EPHEMERAL live-transcript buffer. FoundryX captures
/// continuously, and the on-device transcribers accumulate finalized text for the life of
/// a conversation — unbounded, that growth fed the build-89/90 main-thread stack overflow
/// (rendering one styled run per word) and grows memory during a long session. The live
/// preview is display-only; Kiln's `provisionalTranscript` is the authoritative full
/// transcript. So both backends store only a rolling tail of the most-recent words.
public enum LiveTranscriptBuffer {
    /// Words retained in the live buffer. ≥ the ticker's render cap (48) so the visible
    /// preview is never starved by the bound; the rest is Kiln's job, not the phone's.
    public static let maxRetainedWords = 80

    /// Keep only the most-recent `maxWords` words of an (ever-growing) live transcript.
    /// Both transcriber backends route their `finalizedText` through this, so the
    /// ephemeral buffer — and everything derived from it — stays O(1) in session length.
    public static func boundedTail(_ text: String, maxWords: Int = maxRetainedWords) -> String {
        let words = text.split(separator: " ")
        guard words.count > maxWords else { return text }
        return words.suffix(maxWords).joined(separator: " ")
    }
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
    // The whole-conversation titling context (bounded head+tail) — accumulated
    // alongside the bounded display tail, mutated only on the results task.
    private var titleCtx = RollingTitleContext()

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
                        // Bound the retained buffer to a rolling tail — the live preview is
                        // ephemeral (Kiln is authoritative); unbounded growth is what fed
                        // the build-89/90 stack overflow.
                        self.finalizedText = LiveTranscriptBuffer.boundedTail(
                            self.appendSentence(self.finalizedText, piece))
                        // The titling context keeps the conversation's HEAD as well as the
                        // tail (bounded, see RollingTitleContext) — the rolling title reads
                        // the whole conversation, not the display tail.
                        self.titleCtx.ingest(final: piece)
                        self.publish.yield(LiveTranscript(finalizedText: self.finalizedText,
                                                          volatileTail: "",
                                                          titleContext: self.titleCtx.text))
                    } else {
                        self.publish.yield(LiveTranscript(finalizedText: self.finalizedText,
                                                          volatileTail: piece,
                                                          titleContext: self.titleCtx.text))
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
        publish.yield(LiveTranscript(finalizedText: text, volatileTail: "", isComplete: true,
                                     titleContext: titleCtx.text))
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
        let boxedInput = ConverterInputBox(input)
        var err: NSError?
        let status = converter.convert(to: output, error: &err) { _, outStatus in
            guard let input = boxedInput.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
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
    // Whole-conversation titling context (bounded head+tail; see RollingTitleContext).
    private var titleCtx = RollingTitleContext()

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
            // SFSpeech revises the WHOLE utterance each callback, so it also grows
            // unbounded over a long session — bound the retained tail (see
            // LiveTranscriptBuffer; the live preview is ephemeral, Kiln is authoritative).
            let text = LiveTranscriptBuffer.boundedTail(result.bestTranscription.formattedString)
            if result.isFinal {
                self.finalizedText = text
                // The titling context keeps the head too: feed it the UNBOUNDED revision
                // (RollingTitleContext bounds head+tail itself) — the rolling title reads
                // the whole conversation, not the display tail.
                self.titleCtx.replaceAll(result.bestTranscription.formattedString)
                self.publish.yield(LiveTranscript(finalizedText: text, volatileTail: "",
                                                  titleContext: self.titleCtx.text))
            } else {
                // SFSpeech revises the WHOLE utterance each partial; render it as the
                // volatile tail so it visibly self-corrects (the "guess then fix" feel).
                self.publish.yield(LiveTranscript(finalizedText: self.finalizedText, volatileTail: text,
                                                  titleContext: self.titleCtx.text))
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
        publish.yield(LiveTranscript(finalizedText: text, volatileTail: "", isComplete: true,
                                     titleContext: titleCtx.text))
        publish.finish()
        return text
    }
}

enum LiveTranscriberError: Error { case notAuthorized, unavailable, noOnDeviceModel }
#endif
