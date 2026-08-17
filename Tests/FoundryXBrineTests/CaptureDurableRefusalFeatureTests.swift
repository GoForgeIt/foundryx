import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/capture-refuses-instead-of-discarding.feature`.
///
/// THE DEFECT THIS PINS. `CaptureWAL.flushLocked` cleared the frame buffer and advanced
/// `nextSeq` BEFORE attempting the write, then — when `performDurableMutation` returned nil
/// because the capture has no account binding — returned after a `warn` into a DoorLog that
/// buffers to memory and reaches no one. So a capture opened, reported `.recording`,
/// accepted every frame, and the audio was gone: not deferred, not retried, gone. `.blocked`
/// is reachable on a real phone (the scope's own comment describes the locked-device
/// background relaunch), so this was silent, unrecoverable audio loss in the shipped app.
///
/// The second scenario is the CONTROL. Without it, "nothing is written to the phone" would
/// pass just as happily against a WAL that is broken for some other reason; with it, the
/// only difference between the two runs is whether the capture is authorized.
final class CaptureDurableRefusalFeatureTests: XCTestCase {
    override func tearDown() {
        CaptureAccountScope.resetTestEnvironment()
        super.tearDown()
    }

    func testCaptureRefusesInsteadOfDiscardingFeature() async throws {
        let world = DurableRefusalWorld()
        defer { world.cleanup() }
        try await BrineFeatureRunner.run(
            "capture-refuses-instead-of-discarding",
            registry: StepRegistry(DurableRefusalSteps.make(world: world)))
    }
}

private final class DurableRefusalWorld: @unchecked Sendable {
    /// Small enough that one "speak" fills exactly one segment.
    static let framesPerSegment = 4

    private final class InMemoryDefaults: UserDefaults {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        init() { super.init(suiteName: nil)! }
        required init?(coder: NSCoder) { nil }
        override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
        override func set(_ value: Any?, forKey key: String) {
            lock.withLock { values[key] = value }
        }
        override func removeObject(forKey key: String) {
            _ = lock.withLock { values.removeValue(forKey: key) }
        }
        override func synchronize() -> Bool { true }
    }

    var root: URL!
    var container: URL!
    var wal: CaptureWAL!
    let captureId = "omi-durable-refusal"

    private func makeTempDir(_ label: String) throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Put the process in a REAL production state rather than faking the WAL's internals:
    /// an identity exists on the device but was never activated, which `CaptureAccountScope`
    /// resolves to `.blocked` — no scope, therefore no binding for any root.
    func startRecording(authorized: Bool) throws {
        CaptureAccountScope.resetTestEnvironment()
        container = try makeTempDir("refusal-container")
        root = try makeTempDir("refusal-root")
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setDefaultsForTests(InMemoryDefaults())
        CaptureAccountScope.setIdentityPresenceForTests(authorized ? .absent : .present)

        let binding = CaptureAccountScope.binding(forExplicitRoot: root)
        if authorized {
            guard binding != nil else {
                throw BrineStepError(
                    "the authorized control has no binding either — the fixture proves nothing")
            }
        } else {
            guard binding == nil else {
                throw BrineStepError(
                    "the unauthorized fixture still has a binding, so no write would be refused")
            }
        }
        wal = CaptureWAL(
            captureId: captureId,
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: root,
            chunkFrames: Self.framesPerSegment,
            upload: { _, _ in })
    }

    func speakOneSegment() {
        for i in 0..<Self.framesPerSegment {
            wal.appendFrame(Data([UInt8(i), 0xAA, 0xBB, 0xCC]))
        }
        wal.flushAndWait()
    }

    var segmentFilesOnDisk: [String] {
        let dir = root.appendingPathComponent(captureId, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".opus") }.sorted()
    }

    func cleanup() {
        CaptureAccountScope.resetTestEnvironment()
        for url in [root, container].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private enum DurableRefusalSteps {
    static func make(world w: DurableRefusalWorld) -> [StepDefinition] {
        [
            defineStep("a recording that is not authorized to save to this phone") { ctx, _, _ in
                try w.startRecording(authorized: false)
                return ctx
            },
            defineStep("a recording that is authorized to save to this phone") { ctx, _, _ in
                try w.startRecording(authorized: true)
                return ctx
            },
            defineStep("I speak enough to fill a segment") { ctx, _, _ in
                w.speakOneSegment()
                return ctx
            },
            defineCheck("nothing is written to the phone") { _, _, _ in
                guard w.segmentFilesOnDisk.isEmpty else {
                    throw BrineStepError(
                        "expected no audio on disk, found \(w.segmentFilesOnDisk)")
                }
            },
            defineCheck("none of the audio I spoke is discarded") { _, _, _ in
                let held = w.wal.snapshot().heldFrames
                guard held == DurableRefusalWorld.framesPerSegment else {
                    throw BrineStepError(
                        "the recording discarded the audio it could not save: "
                        + "\(held) of \(DurableRefusalWorld.framesPerSegment) frames kept")
                }
            },
            defineCheck("the recording says it cannot be saved") { _, _, _ in
                let status = w.wal.snapshot()
                guard status.durableWritesRefused else {
                    throw BrineStepError(
                        "the recording still presents itself as an ordinary recording")
                }
                guard let reason = status.lastSyncError,
                      reason.contains("cannot be saved") else {
                    throw BrineStepError(
                        "no readable reason was surfaced: \(status.lastSyncError ?? "nil")")
                }
            },
            defineCheck("the audio I spoke is on the phone") { _, _, _ in
                guard w.segmentFilesOnDisk == [CaptureWAL.segName(0)] else {
                    throw BrineStepError(
                        "expected exactly one saved segment, found \(w.segmentFilesOnDisk)")
                }
                guard w.wal.snapshot().heldFrames == 0 else {
                    throw BrineStepError("frames stayed buffered after a successful save")
                }
            },
            defineCheck("the recording does not say it cannot be saved") { _, _, _ in
                let status = w.wal.snapshot()
                guard !status.durableWritesRefused else {
                    throw BrineStepError("an authorized recording reported a refusal")
                }
            },
        ]
    }
}
