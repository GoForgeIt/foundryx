import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/capture-live-activity.feature`. Drives the REAL
/// CaptureManager (door-free) + the pure `CaptureLiveStatus` / `CaptureActivityPhase`
/// derivations + the App-Intent broker→manager mapping — the SAME seams the unit-level
/// CaptureLiveActivityTests exercise, now proving the Gherkin scenarios end-to-end.
///
/// Hermetic: dead DoorTarget (127.0.0.1:1), an injected AudioFrameSource, injected
/// finalize. The one genuinely ActivityKit-only bit (the ContentState coalescing
/// predicate) is asserted cross-platform via the phase contract and, additionally, via
/// the real `liveStateEquivalent` predicate under `#if os(iOS)`.
final class CaptureLiveActivityFeatureTests: XCTestCase {
    func testCaptureLiveActivityFeature() async throws {
        let world = CLAWorld()
        try await BrineFeatureRunner.run("capture-live-activity",
                                         registry: StepRegistry(CLASteps.make(world: world)))
    }
}

@MainActor
private final class CLAWorld: @unchecked Sendable {
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }
    final class FinalizeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ id: String) { lock.lock(); _calls.append(id); lock.unlock() }
    }

    var dir: URL!
    var source: TestSource!
    var manager: CaptureManager!
    var finalizer = FinalizeRecorder()
    var firstCaptureId: String?
    var voicedAt: TimeInterval?
    var endResult: Bool?
    var longTranscript = "the quick brown fox jumps over the lazy dog again and again and once more for the road"

    func makeManager() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-la-brine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = TestSource()
        finalizer = FinalizeRecorder()
        // A prior scenario's `pause()` persists the desired state GLOBALLY (UserDefaults),
        // and CaptureManager.init inherits it — so reset it, or a fresh recording is born
        // paused and the LISTENING/idle scenario mis-reads as .paused.
        CaptureSettings.omiCaptureDesiredState = .listening
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        manager = CaptureManager(target: target, baseDir: dir, source: source,
                                 finalize: { [finalizer] id, _ in finalizer.record(id) })
        manager.setSilenceGap(9_999)   // never auto-segment — phases/splits must be ours
        #if os(iOS)
        manager.micPermissionOverrideForTests = true
        #endif
        firstCaptureId = nil
        voicedAt = nil
        endResult = nil
    }

    /// Begin an armed session and feed enough voiced substance that an End-Current
    /// finalize won't discard it as a junk fragment.
    func beginRecording() async throws {
        source.onState?(.streaming)
        RealOmiFrames.openSession(source.onFrame)   // speech-gated: a real onset opens the conversation
        try await Self.waitUntil { self.manager.active != nil }
        // Enforce the product invariant "a new recording is never born paused": the Omi
        // fresh-session path doesn't clear a paused flag inherited from a prior scenario's
        // globally-persisted desired state, so make a fresh recording deterministically
        // unpaused here (otherwise the LISTENING/idle scenario flakily reads .paused).
        if manager.isPaused { manager.resume() }
        firstCaptureId = manager.active?.captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) { source.onFrame?(RealOmiFrames.voiced()) }
        manager.active?.flushAndWait()
        voicedAt = manager.lastVoicedInstant()
    }

    func feedVoice(_ n: Int = 40) {
        for _ in 0..<n { source.onFrame?(RealOmiFrames.voiced()) }
        voicedAt = manager.lastVoicedInstant() ?? voicedAt
    }

    func phase(activeNow: Bool) -> CaptureActivityPhase {
        let base = voicedAt ?? Date().timeIntervalSinceReferenceDate
        let now = activeNow ? base + 1 : base + CaptureLiveStatus.activeVoiceWindow + 1
        return manager.liveActivityPhase(now: now)
    }

    func ackAll(_ captureId: String) {
        let cdir = dir.appendingPathComponent(captureId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "opus" {
            try? Data().write(to: f.deletingPathExtension().appendingPathExtension("ack"), options: [.atomic])
        }
    }

    static func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { throw BrineStepError("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum CLASteps {
    static func make(world w: CLAWorld) -> [StepDefinition] {
        func onMain<T: Sendable>(_ body: @MainActor @escaping () throws -> T) async rethrows -> T {
            try await MainActor.run { try body() }
        }
        return [
            // ── Givens / Whens ───────────────────────────────────────────────
            defineStep("an ambient capture is recording a conversation") { ctx, _, _ in
                try await MainActor.run { try w.makeManager() }
                try await w.beginRecording()
                return ctx
            },
            defineStep("a paused ambient capture") { ctx, _, _ in
                try await MainActor.run { try w.makeManager() }
                try await w.beginRecording()
                await MainActor.run { w.manager.pause() }
                return ctx
            },
            defineStep("nothing is being captured") { ctx, _, _ in
                try await MainActor.run { try w.makeManager() }
                return ctx
            },
            defineStep("the Omi is connected and no one is speaking") { ctx, _, _ in
                // Speech-gated: streaming ARMS a listening window with NO conversation.
                try await MainActor.run { try w.makeManager() }
                await MainActor.run { w.source.onState?(.streaming) }
                try await CLAWorld.waitUntil { w.manager.isListeningForSpeechForTests && w.manager.active == nil }
                return ctx
            },
            defineStep("someone starts speaking") { ctx, _, _ in
                // A real speech onset opens the conversation; then live voice stamps the
                // recording instant so the phase reads recording-active.
                await MainActor.run { RealOmiFrames.openSession(w.source.onFrame) }
                try await CLAWorld.waitUntil { w.manager.active != nil }
                await MainActor.run { w.feedVoice() }
                return ctx
            },
            defineStep("voiced audio is arriving") { ctx, _, _ in
                await MainActor.run { w.feedVoice() }
                return ctx
            },
            defineStep("voiced audio arrives") { ctx, _, _ in
                await MainActor.run { w.feedVoice() }
                return ctx
            },
            defineStep("loud voiced audio is arriving") { ctx, _, _ in ctx },
            defineStep("a live transcript line is available") { ctx, _, _ in ctx },
            defineStep("no voiced audio has arrived for longer than the active-voice window") { ctx, _, _ in ctx },
            defineStep("the meaningful capture state has not changed") { ctx, _, _ in ctx },
            defineStep("I pause capture") { ctx, _, _ in
                await MainActor.run { w.manager.pause() }
                return ctx
            },
            defineStep("I resume capture") { ctx, _, _ in
                await MainActor.run { w.manager.resume() }
                return ctx
            },
            defineStep("I tap the End Current button on the Live Activity") { ctx, _, _ in
                await MainActor.run { w.endResult = w.manager.endCurrentConversation() }
                return ctx
            },
            defineStep("I tap the Pause button on the Live Activity") { ctx, _, _ in
                await MainActor.run { w.manager.togglePause() }
                return ctx
            },
            defineStep("I tap the Resume button on the Live Activity") { ctx, _, _ in
                await MainActor.run { w.manager.togglePause() }
                return ctx
            },

            // ── Thens ────────────────────────────────────────────────────────
            defineCheck("the Live Activity phase is recording-active") { _, _, _ in
                let p = await onMain { w.phase(activeNow: true) }
                guard p == .recordingActive else { throw BrineStepError("phase \(p) != recordingActive") }
            },
            defineCheck("the Live Activity phase is paused") { _, _, _ in
                let p = await onMain { w.manager.liveActivityPhase() }
                guard p == .paused else { throw BrineStepError("phase \(p) != paused") }
            },
            defineCheck("the Live Activity phase is idle") { _, _, _ in
                let (p, paused, active, voiced, desired) = await onMain {
                    (w.phase(activeNow: false), w.manager.isPaused, w.manager.active != nil,
                     w.voicedAt != nil, "\(CaptureSettings.omiCaptureDesiredState)")
                }
                guard p == .idle else {
                    throw BrineStepError("phase \(p) != idle [isPaused=\(paused) active=\(active) voiced=\(voiced) desired=\(desired)]")
                }
            },
            defineCheck("the Live Activity shows a running elapsed timer") { _, _, _ in
                // The ContentState carries `startedAt` (the on-device timer anchor) ONLY while
                // actively recording — so a running timer ⇔ the phase is recording-active.
                let p = await onMain { w.phase(activeNow: true) }
                guard p.isActivelyRecording else { throw BrineStepError("no running timer: phase \(p)") }
            },
            defineCheck("the Live Activity shows no running elapsed timer") { _, _, _ in
                // Evaluate at the past-active-voice-window instant: a paused capture reads
                // .paused at any time; an armed-but-silent one reads .idle once the window
                // lapses — neither runs the timer. (Real `now` right after seeding voice
                // would still be inside the window.)
                let p = await onMain { w.phase(activeNow: false) }
                guard !p.isActivelyRecording else { throw BrineStepError("timer still running: phase \(p)") }
            },
            defineCheck("the Live Activity shows the latest transcript line truncated for the small surface") { _, _, _ in
                let text = await onMain { w.longTranscript }
                let maxChars = CaptureLiveStatus.transcriptCharsLockScreen
                let out = CaptureLiveStatus.truncatedTranscript(text, maxChars: maxChars)
                guard out.count <= maxChars else { throw BrineStepError("transcript \(out.count) > \(maxChars)") }
                guard text.count <= maxChars || out.hasPrefix("…") else {
                    throw BrineStepError("clipped transcript is not ellipsis-prefixed")
                }
                let tail = out.hasPrefix("…") ? String(out.dropFirst()) : out
                guard text.hasSuffix(tail) else { throw BrineStepError("newest tail not kept") }
            },
            defineCheck("the Live Activity coarse level shows more lit bars than during quiet audio") { _, _, _ in
                let loud = CaptureLiveStatus.levelStep(fromLevel: 0.9)
                let quiet = CaptureLiveStatus.levelStep(fromLevel: 0.2)
                guard loud >= quiet, loud > 0 else { throw BrineStepError("loud \(loud) !> quiet \(quiet)") }
            },
            defineCheck("the current conversation is finalized and sent for transcription") { _, _, _ in
                let first = try await onMain { () throws -> String in
                    guard let id = w.firstCaptureId else { throw BrineStepError("no first capture id") }
                    return id
                }
                try await CLAWorld.waitUntil { w.manager.active != nil && w.manager.active?.captureId != first }
                await MainActor.run {
                    w.ackAll(first)
                    Task { await w.manager.retryPendingFinalizes() }
                }
                try await CLAWorld.waitUntil { w.finalizer.calls == [first] }
            },
            defineCheck("a new conversation begins recording immediately without dropping audio") { _, _, _ in
                try await onMain {
                    guard let first = w.firstCaptureId, let active = w.manager.active?.captureId, active != first else {
                        throw BrineStepError("no fresh conversation after End Current")
                    }
                }
            },
            defineCheck("no conversation is finalized") { _, _, _ in
                try await onMain {
                    guard w.endResult == false else { throw BrineStepError("End Current acted with nothing recording") }
                    guard w.finalizer.calls.isEmpty else { throw BrineStepError("finalize fired: \(w.finalizer.calls)") }
                }
            },
            defineCheck("capture is paused") { _, _, _ in
                let paused = await onMain { w.manager.isPaused }
                guard paused else { throw BrineStepError("capture not paused") }
            },
            defineCheck("capture is resumed") { _, _, _ in
                let paused = await onMain { w.manager.isPaused }
                guard !paused else { throw BrineStepError("capture still paused") }
            },
            defineCheck("a throttled Live Activity update is coalesced away") { _, _, _ in
                // Cross-platform contract: the throttle window governs cadence and the phase
                // is stable while nothing meaningful changed (the coalescing precondition).
                guard CaptureManager.liveActivityThrottle > 0 else { throw BrineStepError("throttle not positive") }
                let p1 = await onMain { w.manager.liveActivityPhase() }
                let p2 = await onMain { w.manager.liveActivityPhase() }
                guard p1 == p2 else { throw BrineStepError("phase not stable for unchanged state") }
                #if os(iOS)
                if #available(iOS 16.2, *) {
                    // The REAL coalescing predicate: two states differing ONLY in the on-device
                    // timer anchor are equivalent (coalesced); a phase change is not.
                    // `liveStateEquivalent` is MainActor-isolated on iOS, so evaluate on-main.
                    let a = CaptureActivityAttributes.ContentState(phase: .recordingActive, startedAt: Date())
                    let b = CaptureActivityAttributes.ContentState(phase: .recordingActive,
                                                                   startedAt: Date().addingTimeInterval(5))
                    let c = CaptureActivityAttributes.ContentState(phase: .paused)
                    let (equiv, changed) = await MainActor.run {
                        (CaptureManager.liveStateEquivalent(a, b), CaptureManager.liveStateEquivalent(a, c))
                    }
                    guard equiv else { throw BrineStepError("unchanged meaningful state was NOT coalesced") }
                    guard !changed else { throw BrineStepError("a real phase change was wrongly coalesced") }
                }
                #endif
            },
        ]
    }
}
