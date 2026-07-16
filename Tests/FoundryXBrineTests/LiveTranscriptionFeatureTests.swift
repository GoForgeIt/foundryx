import XCTest
import Foundation
import AVFoundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/live-transcription.feature. Drives the REAL live-preview
/// seams the unit tests exercise: the INJECTED `LiveTranscribing` factory wired into
/// `CaptureManager` (per-session lifecycle, the volatile→final stream republished into
/// `liveTranscript`, cleared on close, absent with no factory), plus the pure
/// `LiveTranscript.renderedSegments` word-opacity ramp and the bounded recent-words
/// window. Hermetic — the transcriber is faked (SpeechAnalyzer needs a device); no network.
final class LiveTranscriptionFeatureTests: XCTestCase {
    func testLiveTranscriptionFeature() async throws {
        try await BrineFeatureRunner.run("live-transcription",
                                         registry: StepRegistry(LiveTranscriptionSteps.make(world: .init())))
    }
}

private final class FakeLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let transcript: AsyncStream<LiveTranscript>
    private let cont: AsyncStream<LiveTranscript>.Continuation
    private let q = DispatchQueue(label: "foundryx.fake-live-transcriber")   // async-safe (NSLock.lock/unlock banned in async)
    private var _started = false, _finished = false
    var started: Bool { q.sync { _started } }
    var finished: Bool { q.sync { _finished } }
    init() {
        var c: AsyncStream<LiveTranscript>.Continuation!
        transcript = AsyncStream { c = $0 }
        cont = c
    }
    func start() async throws { q.sync { _started = true } }
    func append(_ pcm: AVAudioPCMBuffer) {}
    func finish() async -> String { q.sync { _finished = true }; cont.finish(); return "" }
    func emit(_ t: LiveTranscript) { cont.yield(t) }
}

private final class FakeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeLiveTranscriber] = []
    func make() -> LiveTranscribing? { let f = FakeLiveTranscriber(); lock.lock(); made.append(f); lock.unlock(); return f }
    var last: FakeLiveTranscriber? { lock.lock(); defer { lock.unlock() }; return made.last }
}

@MainActor
private final class LiveTranscriptionWorld: @unchecked Sendable {
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    var dir: URL!
    var src: TestSource!
    var factory: FakeFactory!
    var mgr: CaptureManager!
    var preview = LiveTranscript.empty

    func makeRecording(withFactory: Bool) async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-live-feat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        src = TestSource()
        factory = FakeFactory()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        mgr = withFactory
            ? CaptureManager(target: target, baseDir: dir, source: src, finalize: { _, _ in },
                             liveTranscriber: { [factory] in factory!.make() })
            : CaptureManager(target: target, baseDir: dir, source: src, finalize: { _, _ in })
        #if os(iOS)
        mgr.micPermissionOverrideForTests = true
        #endif
        src.onState?(.streaming)
        try await Self.waitUntil { self.mgr.active != nil }
    }

    static func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { throw BrineStepError("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum LiveTranscriptionSteps {
    static func make(world w: LiveTranscriptionWorld) -> [StepDefinition] {
        [
            defineStep("an ambient capture is recording a conversation") { ctx, _, _ in
                try await w.makeRecording(withFactory: true)
                try await LiveTranscriptionWorld.waitUntil { w.factory.last != nil }
                if let fake = await MainActor.run(body: { w.factory.last }) {
                    try await LiveTranscriptionWorld.waitUntil { fake.started }
                }
                return ctx
            },
            defineCheck("on-device live transcription is available") { _, _, _ in
                let available = await MainActor.run { w.factory?.last != nil }
                guard available else { throw BrineStepError("no live transcriber was created (unavailable)") }
            },

            // MARK: tentative words appear, then correct on finalize
            defineStep("the recognizer reports tentative words as I speak") { ctx, _, _ in
                let fake = try await MainActor.run { () throws -> FakeLiveTranscriber in
                    guard let f = w.factory.last else { throw BrineStepError("no transcriber") }; return f
                }
                fake.emit(LiveTranscript(finalizedText: "", volatileTail: "kiln"))
                try await LiveTranscriptionWorld.waitUntil { w.mgr.liveTranscript.volatileTail == "kiln" }
                await MainActor.run { w.preview = w.mgr.liveTranscript }
                return ctx
            },
            defineCheck("I see those words appear as a faded live preview under the capture meter") { _, _, _ in
                let preview = await MainActor.run { w.preview }
                let segs = preview.renderedSegments()
                guard !preview.volatileTail.isEmpty, let last = segs.last, last.volatile, last.opacity < 1.0 else {
                    throw BrineStepError("tentative words are not shown as a faded preview")
                }
            },
            defineStep("a tentative word is later finalized into a corrected form") { ctx, _, _ in
                let fake = try await MainActor.run { () throws -> FakeLiveTranscriber in
                    guard let f = w.factory.last else { throw BrineStepError("no transcriber") }; return f
                }
                fake.emit(LiveTranscript(finalizedText: "", volatileTail: "kiln"))
                try await LiveTranscriptionWorld.waitUntil { w.mgr.liveTranscript.volatileTail == "kiln" }
                fake.emit(LiveTranscript(finalizedText: "Kiln", volatileTail: ""))
                try await LiveTranscriptionWorld.waitUntil {
                    w.mgr.liveTranscript.finalizedText == "Kiln" && w.mgr.liveTranscript.volatileTail.isEmpty
                }
                await MainActor.run { w.preview = w.mgr.liveTranscript }
                return ctx
            },
            defineCheck("the live preview updates the word to its corrected, finalized form") { _, _, _ in
                let preview = await MainActor.run { w.preview }
                guard preview.finalizedText == "Kiln", preview.volatileTail.isEmpty else {
                    throw BrineStepError("preview did not update to the corrected finalized form")
                }
            },

            // MARK: opacity ramp (pure rendering seam)
            defineStep("the recognizer reports tentative trailing words as I speak") { ctx, _, _ in
                await MainActor.run { w.preview = LiveTranscript(finalizedText: "", volatileTail: "alpha beta gamma") }
                return ctx
            },
            defineCheck("the newest word is shown faintest and the words just before it ramp up to full") { _, _, _ in
                let preview = await MainActor.run { w.preview }
                let segs = preview.renderedSegments(fadeWindow: 3, floorOpacity: 0.4)
                guard segs.map(\.text) == ["alpha", "beta", "gamma"],
                      segs[2].opacity < segs[1].opacity, segs[1].opacity < segs[0].opacity else {
                    throw BrineStepError("the volatile tail did not ramp newest-faintest → brighter")
                }
            },
            defineCheck("each word snaps to full opacity the moment the recognizer finalizes it") { _, _, _ in
                let segs = LiveTranscript(finalizedText: "alpha beta gamma", volatileTail: "").renderedSegments()
                guard segs.count == 3, segs.allSatisfy({ abs($0.opacity - 1.0) < 0.0001 && !$0.volatile }) else {
                    throw BrineStepError("finalized words did not snap to full opacity")
                }
            },

            // MARK: provisional preview never replaces Kiln; cleared on close
            defineStep("a conversation showed a live on-device preview while recording") { ctx, _, _ in
                try await w.makeRecording(withFactory: true)
                try await LiveTranscriptionWorld.waitUntil { w.factory.last != nil }
                let fake = try await MainActor.run { () throws -> FakeLiveTranscriber in
                    guard let f = w.factory.last else { throw BrineStepError("no transcriber") }; return f
                }
                fake.emit(LiveTranscript(finalizedText: "hello", volatileTail: "wor"))
                try await LiveTranscriptionWorld.waitUntil { !w.mgr.liveTranscript.isEmpty }
                return ctx
            },
            defineStep("the conversation ends and Kiln returns its authoritative transcript") { ctx, _, _ in
                await MainActor.run { w.src.onState?(.stopped) }
                try await LiveTranscriptionWorld.waitUntil { w.mgr.isAwaitingReconnect }
                await MainActor.run {
                    w.mgr.resolveReconnectGrace(now: Date().timeIntervalSince1970 + CaptureManager.reconnectGraceWindow + 1)
                }
                try await LiveTranscriptionWorld.waitUntil { w.mgr.active == nil }
                if let fake = await MainActor.run(body: { w.factory.last }) {
                    try await LiveTranscriptionWorld.waitUntil { fake.finished }
                }
                return ctx
            },
            defineCheck("the authoritative transcript is what is stored and shown afterward") { _, _, _ in
                // The ephemeral preview is cleared on close, so it can never override the
                // authoritative Kiln transcript that loads from the durable pipeline.
                let cleared = await MainActor.run { w.mgr.liveTranscript.isEmpty }
                guard cleared else { throw BrineStepError("the provisional preview persisted and could shadow Kiln's transcript") }
            },
            defineCheck("the live preview is cleared when the conversation closes") { _, _, _ in
                let cleared = await MainActor.run { w.mgr.liveTranscript.isEmpty }
                guard cleared else { throw BrineStepError("the live preview was not cleared on close") }
            },

            // MARK: unsupported device — no preview, capture unchanged
            defineStep("a device that does not support on-device live transcription") { ctx, _, _ in
                try await w.makeRecording(withFactory: false)
                return ctx
            },
            defineStep("an ambient capture records a conversation") { ctx, _, _ in
                await MainActor.run {
                    for _ in 0..<40 { w.src.onFrame?(RealOmiFrames.voiced()) }
                    w.mgr.active?.flushAndWait()
                }
                return ctx
            },
            defineCheck("no live preview is shown and capture proceeds unchanged") { _, _, _ in
                let ok = await MainActor.run { () -> Bool in
                    (w.mgr.active?.snapshot().totalSegments ?? 0) > 0 && w.mgr.liveTranscript.isEmpty
                }
                guard ok else { throw BrineStepError("preview shown, or capture did not proceed, without a transcriber") }
            },

            // MARK: long conversation — bounded preview
            defineStep("the conversation has run long enough to accumulate over a thousand words") { ctx, _, _ in
                let body = (1...1200).map { "word\($0)" }.joined(separator: " ")
                await MainActor.run { w.preview = LiveTranscript(finalizedText: body, volatileTail: "settling now") }
                return ctx
            },
            defineCheck("the live preview still shows only its most recent handful of words") { _, _, _ in
                let preview = await MainActor.run { w.preview }
                let segs = preview.renderedSegments(maxWords: 48)
                guard segs.count <= 48, segs.suffix(2).map(\.text) == ["settling", "now"] else {
                    throw BrineStepError("the preview was not capped to its most-recent words")
                }
                // The shared buffer bound keeps the retained text flat regardless of length.
                let bounded = LiveTranscriptBuffer.boundedTail(preview.finalizedText)
                guard bounded.split(separator: " ").count <= LiveTranscriptBuffer.maxRetainedWords else {
                    throw BrineStepError("the retained buffer was not bounded")
                }
            },
            defineCheck("rendering the preview stays bounded so the app does not crash") { _, _, _ in
                let preview = await MainActor.run { w.preview }
                let count = preview.renderedSegments(maxWords: 48).count
                guard count <= 48 else { throw BrineStepError("render was unbounded (\(count) segments)") }
            },
        ]
    }
}
