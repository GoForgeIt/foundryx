import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

@MainActor
final class CaptureFinalizeRecoveryFeatureTests: SignedOutListeningCaptureTestCase {
    func testCaptureFinalizeRecoveryFeature() async throws {
        try await BrineFeatureRunner.run(
            "capture-finalize-recovery",
            registry: StepRegistry(CaptureFinalizeRecoverySteps.make(world: RecoveryWorld())))
    }
}

@MainActor
private final class RecoveryWorld: @unchecked Sendable {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _finalized = 0
        private var _uploads = 0
        private var _uploadedSeqs: [UInt64] = []
        func finalize() { lock.lock(); _finalized += 1; lock.unlock() }
        func upload(_ seq: UInt64) { lock.lock(); _uploads += 1; _uploadedSeqs.append(seq); lock.unlock() }
        func reset() { lock.lock(); _finalized = 0; _uploads = 0; _uploadedSeqs = []; lock.unlock() }
        var values: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (_finalized, _uploads) }
        var uploadedSeqs: [UInt64] { lock.lock(); defer { lock.unlock() }; return _uploadedSeqs }
    }
    final class Source: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    var root: URL!
    var captureId = "omi-20260714-163759-recovery"
    var manager: CaptureManager!
    var doorSeqs: [UInt64] = []
    var uploadFails = false
    var sawRetrying = false
    let recorder = Recorder()

    func seed(old: Bool) throws {
        recorder.reset()
        DeletionRecorder.shared.clear()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-finalize-recovery-\(UUID().uuidString)", isDirectory: true)
        let captureDir = root.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        for seq in 0..<3 {
            try Data([1, 2, 3, 4]).write(to: captureDir.appendingPathComponent(
                String(format: "seg-%012llu.opus", UInt64(seq))))
        }
        let marker = captureDir.appendingPathComponent(".needs-finalize")
        try Data().write(to: marker)
        if old {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -(8 * 24 * 60 * 60))],
                ofItemAtPath: marker.path)
        }
    }

    func seedIncomplete() throws {
        try seed(old: true)
        let reason = "incomplete: 3 segments unrecovered; audio kept on phone"
        try Data(reason.utf8).write(to: incompleteMarker, options: [.atomic])
        try? FileManager.default.removeItem(at: captureDir.appendingPathComponent(".needs-finalize"))
    }

    func build(uploadFails: Bool) async {
        self.uploadFails = uploadFails
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let seqs = doorSeqs
        let recorder = recorder
        manager = CaptureManager(
            target: target, baseDir: root, source: Source(),
            finalize: { _, _ in recorder.finalize() },
            fetchSegments: { _ in seqs },
            uploadSegment: { [weak self] _, seq, _ in
                recorder.upload(seq)
                if let manager = await self?.manager {
                    let retrying = await MainActor.run { manager.isManualRecoveryInProgress(self?.captureId ?? "") }
                    if retrying { await MainActor.run { self?.sawRetrying = true } }
                }
                if uploadFails { throw DoorError.http(503) }
            })
        manager.setAutoFinalizeForTests(false)
        await manager.hydration?.value
    }

    var captureDir: URL { root.appendingPathComponent(captureId, isDirectory: true) }
    var incompleteMarker: URL { captureDir.appendingPathComponent(".incomplete") }
    var opusCount: Int {
        ((try? FileManager.default.contentsOfDirectory(at: captureDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "opus" }.count
    }
}

private enum CaptureFinalizeRecoverySteps {
    static func make(world w: RecoveryWorld) -> [StepDefinition] {
        [
            defineStep("a closed recording has segments waiting for acknowledgement") { ctx, _, _ in
                try await MainActor.run { try w.seed(old: false) }
                return ctx
            },
            defineStep("the computer reports that every segment is already durable") { ctx, _, _ in
                await MainActor.run { w.doorSeqs = [0, 1, 2] }
                await w.build(uploadFails: false)
                return ctx
            },
            defineStep("a closed recording has waited beyond the recovery window") { ctx, _, _ in
                try await MainActor.run { try w.seed(old: true) }
                return ctx
            },
            defineStep("some segments are still only on the phone") { ctx, _, _ in
                await MainActor.run { w.doorSeqs = [] }
                await w.build(uploadFails: true)
                return ctx
            },
            defineStep("an incomplete recording has waited beyond the recovery window") { ctx, _, _ in
                try await MainActor.run { try w.seedIncomplete() }
                return ctx
            },
            defineStep("its segments are still only on the phone") { ctx, _, _ in
                await MainActor.run { w.doorSeqs = [] }
                await w.build(uploadFails: false)
                return ctx
            },
            defineStep("the computer cannot accept its segments") { ctx, _, _ in
                await MainActor.run { w.doorSeqs = [] }
                await w.build(uploadFails: true)
                return ctx
            },
            defineStep("the computer already holds some of its segments") { ctx, _, _ in
                await MainActor.run { w.doorSeqs = [0] }
                await w.build(uploadFails: false)
                return ctx
            },
            defineStep("pending recordings are recovered") { ctx, _, _ in
                await w.manager.drainPending()
                await w.manager.retryPendingFinalizes()
                return ctx
            },
            defineStep("I choose {string}") { ctx, match, _ in
                guard try match.requireString(0) == "Send to computer" else {
                    throw BrineStepError("unexpected recovery action")
                }
                await w.manager.recoverIncompleteCapture(w.captureId)
                return ctx
            },
            defineStep("I choose {string} repeatedly while other recordings sync") { ctx, match, _ in
                guard try match.requireString(0) == "Send to computer" else {
                    throw BrineStepError("unexpected recovery action")
                }
                async let first: Void = w.manager.recoverIncompleteCapture(w.captureId)
                async let second: Void = w.manager.recoverIncompleteCapture(w.captureId)
                async let drain: Void = w.manager.drainPending()
                _ = await (first, second, drain)
                return ctx
            },
            defineCheck("the recording is finalized without uploading those segments again") { _, _, _ in
                let result = w.recorder.values
                guard result == (1, 0) else { throw BrineStepError("finalized/uploads was \(result)") }
            },
            defineCheck("the recording is marked incomplete with the unrecovered segment count") { _, _, _ in
                let text = try await MainActor.run { try String(contentsOf: w.incompleteMarker) }
                guard text.contains("3") else { throw BrineStepError("incomplete reason lacks count: \(text)") }
            },
            defineCheck("its audio remains on the phone") { _, _, _ in
                let count = await MainActor.run { w.opusCount }
                guard count == 3 else { throw BrineStepError("only \(count) audio segments remain") }
            },
            defineCheck("it is not finalized") { _, _, _ in
                let finalized = w.recorder.values.0
                guard finalized == 0 else { throw BrineStepError("unsafe finalize was called") }
            },
            defineCheck("the recording card says {string}") { _, match, _ in
                let expected = try match.requireString(0)
                let actual = await MainActor.run { () -> String in
                    let status = w.manager.captures.first!.snapshot()
                    return CaptureCardPresentation.make(
                        status: status, meta: nil, card: nil, pollerStage: .stored,
                        pollerTitle: nil, pollerSummary: nil, droppedReason: nil,
                        hasCachedTranscript: false, local: false, categoryName: nil,
                        categoryAutoFiled: false, waveform: []).statusWord
                }
                guard actual == expected else { throw BrineStepError("card says '\(actual)'") }
            },
            defineCheck("the card says the recording is being sent") { _, _, _ in
                guard await MainActor.run(body: { w.sawRetrying }) else {
                    throw BrineStepError("card never entered the retrying state")
                }
            },
            defineCheck("the expired recovery window does not stop the upload") { _, _, _ in
                guard w.recorder.values.1 == 3 else { throw BrineStepError("expired capture did not upload") }
            },
            defineCheck("the recording finalizes through the normal path") { _, _, _ in
                guard w.recorder.values.0 == 1 else { throw BrineStepError("normal finalize was not called") }
            },
            defineCheck("the recording returns to incomplete with the failure reason") { _, _, _ in
                let text = try await MainActor.run { try String(contentsOf: w.incompleteMarker) }
                guard text.contains("manual recovery failed") else { throw BrineStepError("missing failure reason: \(text)") }
            },
            defineCheck("I can choose {string} again") { _, match, _ in
                guard try match.requireString(0) == "Send to computer",
                      await MainActor.run(body: { w.manager.canManuallyRecover(w.captureId) }) else {
                    throw BrineStepError("manual recovery action was lost")
                }
            },
            defineCheck("the failed recovery outcome is written to diagnostics") { _, _, _ in
                guard DeletionRecorder.shared.recorded().contains(where: {
                    $0.contains("capture_manual_recovery") && $0.contains("failed")
                }) else { throw BrineStepError("failed recovery was absent from diagnostics") }
            },
            defineCheck("only the outstanding segments are uploaded once") { _, _, _ in
                guard w.recorder.uploadedSeqs.sorted() == [1, 2] else {
                    throw BrineStepError("uploaded seqs were \(w.recorder.uploadedSeqs)")
                }
            }
        ]
    }
}
