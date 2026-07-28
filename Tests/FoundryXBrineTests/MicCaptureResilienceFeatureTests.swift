import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/mic-capture-resilience.feature`. The AVAudioSession
/// interruption/route-change observers live inside `MicFrameSource` (real hardware, not
/// hermetically drivable), but the feature's USER-FACING promise — audio captured before
/// an interruption is durable, and capture continues into the SAME conversation — is a
/// CaptureManager/CaptureWAL contract that IS testable door-free.
///
/// An OS interruption never finalizes the capture (MicFrameSource stays "open" and does
/// NOT emit `.stopped`), so at the manager seam an interruption is simply: frames pause,
/// then resume — the session/captureId is unchanged and the already-WAL'd audio stays on
/// disk. "App closed before resume" is proven by a fresh manager on the same dir still
/// finding every segment (the CaptureResumeTests durability model).
final class MicCaptureResilienceFeatureTests: ProcessGlobalStateTestCase {
    func testMicCaptureResilienceFeature() async throws {
        let world = MicResWorld()
        try await BrineFeatureRunner.run("mic-capture-resilience",
                                         registry: StepRegistry(MicResSteps.make(world: world)))
    }
}

@MainActor
private final class MicResWorld: @unchecked Sendable {
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    var dir: URL!
    var omi: TestSource!
    var mic: TestSource!
    var manager: CaptureManager!
    var captureId: String?
    var segCountAtInterruption = 0

    func startMicRecording(seconds30: Bool = false) async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-micres-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        omi = TestSource(); mic = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        manager = CaptureManager(target: target, baseDir: dir, source: omi, micSource: mic,
                                 finalize: { _, _ in })
        manager.setSilenceGap(9_999)   // an interruption gap must NOT auto-close the capture
        #if os(iOS)
        manager.micPermissionOverrideForTests = true
        #endif
        manager.startMicRecording()
        mic.onState?(.streaming)
        try await Self.waitUntil { self.manager.active != nil }
        captureId = manager.active?.captureId
        let frames = seconds30 ? (CaptureManager.minVoicedFramesToUpload + 60) : 60
        for _ in 0..<frames { mic.onFrame?(RealOmiFrames.voiced()) }
        manager.active?.flushAndWait()
    }

    func countOpus(_ id: String) -> Int {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "opus" }.count
    }

    /// Simulate an OS interruption / route change: frames pause but the session is NOT
    /// finalized (MicFrameSource does not emit `.stopped`). Snapshot the durable audio.
    func interrupt() {
        segCountAtInterruption = captureId.map(countOpus) ?? 0
    }

    static // Deadline is generous ON PURPOSE. The `flake` gate runs this suite a second time
    // under deliberately induced CPU load, where a capture session can be starved for
    // seconds. A 3s bound there tested the SCHEDULER, not the behaviour — it made the
    // flake gate fail ~70% of the time on a clean main, which trains everyone to ignore
    // the one gate whose job is catching real flakiness (track 20260726T0030).
    // The assertion is unchanged: the condition must still become true.
    func waitUntil(timeout: TimeInterval = 300, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { throw BrineStepError("waitUntil timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum MicResSteps {
    static func make(world w: MicResWorld) -> [StepDefinition] {
        return [
            defineStep("I am recording a conversation with the phone microphone") { ctx, _, _ in
                try await w.startMicRecording(); return ctx
            },
            defineStep("I am recording with the phone microphone") { ctx, _, _ in
                try await w.startMicRecording(); return ctx
            },
            defineStep("thirty seconds of audio has been captured") { ctx, _, _ in
                // Feed a longer run and flush so it's durably on disk before the interruption.
                await MainActor.run {
                    for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 60) { w.mic.onFrame?(RealOmiFrames.voiced()) }
                    w.manager.active?.flushAndWait()
                    w.segCountAtInterruption = w.captureId.map(w.countOpus) ?? 0
                }
                return ctx
            },
            defineStep("a phone call interrupts the audio session") { ctx, _, _ in
                await MainActor.run { w.interrupt() }; return ctx
            },
            defineStep("the audio route changes") { ctx, _, _ in
                await MainActor.run { w.interrupt() }; return ctx
            },
            defineStep("the recording is interrupted and the app is closed before it resumes") { ctx, _, _ in
                await MainActor.run {
                    w.manager.active?.flushAndWait()
                    w.segCountAtInterruption = w.captureId.map(w.countOpus) ?? 0
                    w.manager = nil   // the app process goes away; the WAL stays on disk
                }
                return ctx
            },
            defineCheck("the audio already captured is kept") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.captureId else { throw BrineStepError("no capture id") }
                    let kept = w.countOpus(id)
                    guard kept > 0, kept >= w.segCountAtInterruption else {
                        throw BrineStepError("audio lost: \(kept) < \(w.segCountAtInterruption)")
                    }
                    guard w.manager.active?.captureId == id else {
                        throw BrineStepError("interruption killed the session")
                    }
                }
            },
            defineCheck("when the call ends, recording resumes automatically into the same conversation") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.captureId else { throw BrineStepError("no capture id") }
                    for _ in 0..<80 { w.mic.onFrame?(RealOmiFrames.voiced()) }
                    w.manager.active?.flushAndWait()
                    guard w.manager.active?.captureId == id else { throw BrineStepError("resumed into a DIFFERENT conversation") }
                    guard w.countOpus(id) > w.segCountAtInterruption else { throw BrineStepError("no audio appended after resume") }
                }
            },
            defineCheck("the thirty seconds is still saved when I reopen the app") { _, _, _ in
                let id = try await MainActor.run { () throws -> String in
                    guard let id = w.captureId else { throw BrineStepError("no capture id") }
                    return id
                }
                // Reopen: a fresh manager hydrates the same dir; the pre-close audio survives.
                try await MainActor.run {
                    let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
                    w.manager = CaptureManager(target: target, baseDir: w.dir, source: w.omi,
                                               micSource: w.mic, finalize: { _, _ in })
                    #if os(iOS)
                    w.manager.micPermissionOverrideForTests = true
                    #endif
                }
                if let h = await MainActor.run(body: { w.manager.hydration }) { await h.value }
                try await MainActor.run {
                    let kept = w.countOpus(id)
                    guard kept > 0, kept >= w.segCountAtInterruption else {
                        throw BrineStepError("reopen lost audio: \(kept) < \(w.segCountAtInterruption)")
                    }
                }
            },
            defineCheck("recording continues without losing the conversation") { _, _, _ in
                try await MainActor.run {
                    guard let id = w.captureId else { throw BrineStepError("no capture id") }
                    guard w.manager.active?.captureId == id else { throw BrineStepError("route change lost the conversation") }
                    for _ in 0..<40 { w.mic.onFrame?(RealOmiFrames.voiced()) }
                    w.manager.active?.flushAndWait()
                    guard w.countOpus(id) >= w.segCountAtInterruption else { throw BrineStepError("audio lost across route change") }
                }
            },
        ]
    }
}
