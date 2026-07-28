// SyntheticTranscriptSource — the DEV-only LiveTranscriber substitute used by the
// foreground-restore UI proof (`-SyntheticTranscript`).
//
// The simulator cannot prove Apple's on-device recognizer will turn synthetic audio
// into words. This seam removes only that nondeterminism: the ambient source still
// opens a real CaptureManager conversation, decoded PCM still reaches the active
// LiveTranscribing session, and snapshots still flow through CaptureManager's real
// publisher, RecordingScreen binding, SwiftUI rendering, and foreground replacement.
//
// Each replacement session receives the next deterministic phrase. That matters for
// foreground restoration: the first session establishes visible words before the app
// switch, while the replacement emits different words that must append after the
// retained snapshot. A view stub or pre-seeded RecordingPreview could not exercise
// either binding failure.
//
// TEST-ONLY. Both the type and the launch-argument read are compiled only for DEBUG or
// PERF_HARNESS. scripts/ci-gates.sh leak proves the type exists in the PerfRelease
// negative-control binary, is absent from Release, and rejects any ungated read of the
// launch argument.

#if DEBUG || PERF_HARNESS
import AVFoundation
import Foundation
import UIKit

final class SyntheticTranscriptLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let transcript: AsyncStream<LiveTranscript>

    private let continuation: AsyncStream<LiveTranscript>.Continuation
    private let words: [String]
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var framesSinceWord = 0
    private var emittedWords: [String] = []
    private var backgroundObserver: NSObjectProtocol?

    /// Decoded Omi PCM arrives in 20 ms frames. Ten frames per word keeps the proof
    /// visibly progressive without making it slow.
    private static let framesPerWord = 10

    fileprivate init(words: [String]) {
        self.words = words
        var streamContinuation: AsyncStream<LiveTranscript>.Continuation!
        transcript = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
        // Fidelity seam for the foreground-restoration proof: iOS can retire Speech's
        // result publisher while the process is suspended. Make that interruption
        // deterministic in the simulator. The source keeps speaking, but this producer
        // cannot emit again; only RootView's foreground hook can install the next one.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.interruptForSuspension()
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    static func factory() -> LiveTranscriberFactory {
        let script = SyntheticTranscriptScript()
        return { script.makeTranscriber() }
    }

    func start() async throws {
        lock.withLock {
            started = true
        }
    }

    func append(_ pcm: AVAudioPCMBuffer) {
        let snapshot: LiveTranscript? = lock.withLock {
            guard started, !finished, emittedWords.count < words.count else { return nil }
            framesSinceWord += 1
            guard emittedWords.isEmpty || framesSinceWord >= Self.framesPerWord else {
                return nil
            }
            framesSinceWord = 0
            emittedWords.append(words[emittedWords.count])
            let text = emittedWords.joined(separator: " ")
            return LiveTranscript(
                finalizedText: text,
                volatileTail: "",
                isComplete: false,
                titleContext: text)
        }
        if let snapshot {
            continuation.yield(snapshot)
        }
    }

    func finish() async -> String {
        let settled: String = lock.withLock {
            finished = true
            return emittedWords.joined(separator: " ")
        }
        continuation.finish()
        return settled
    }

    private func interruptForSuspension() {
        let wasInterrupted = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if wasInterrupted {
            continuation.finish()
        }
    }
}

private final class SyntheticTranscriptScript: @unchecked Sendable {
    private static let phrases: [[String]] = [
        "the captured conversation keeps these live transcript words visible before switching apps",
        "and new speech continues growing after returning to foundryx",
        "the deterministic continuation remains attached to the same listening conversation",
    ].map { $0.split(separator: " ").map(String.init) }

    private let lock = NSLock()
    private var nextPhrase = 0

    func makeTranscriber() -> LiveTranscribing? {
        let phrase: [String] = lock.withLock {
            let selected = Self.phrases[nextPhrase % Self.phrases.count]
            nextPhrase += 1
            return selected
        }
        return SyntheticTranscriptLiveTranscriber(words: phrase)
    }
}
#endif
