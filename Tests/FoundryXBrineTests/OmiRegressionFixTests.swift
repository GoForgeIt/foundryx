import XCTest
import Foundation
@testable import FoundryXKit

/// Regression coverage for the build #76 capture-source-registry Omi breakages:
///   1. PRIMARY — a connected source's frames reach the WAL through the active-source
///      path (the frame routing must survive the registry's source switching).
///   2. Auto-connect — a discovered SAVED device auto-connects (no manual tap); an
///      unsaved device does not (first pairing stays explicit).
///   3. Toggle-off — disabling a source removes it from the capture-visible set and
///      drives its lifecycle owner off (the Omi truly leaves the capture surface).
@MainActor
final class OmiRegressionFixTests: SignedOutListeningCaptureTestCase {

    /// A source the test drives directly (start/stop count invocations; the test fires
    /// the onFrame/onState closures CaptureManager installs).
    final class TestSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    // MARK: 1 — frames from the active source reach the WAL

    func testConnectedSourceFramesReachTheWAL() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-omifix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let omi = TestSource()
        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
        let mgr = CaptureManager(target: target, baseDir: dir, source: omi)

        // The Omi "connects" → ambient capture ARMS; a real speech onset opens the
        // session (no manual Record button).
        omi.onState?(.streaming)
        try await waitUntil { mgr.isListeningForSpeechForTests }
        RealOmiFrames.openSession(omi.onFrame)
        try await waitUntil { mgr.active != nil }
        let wal = try XCTUnwrap(mgr.active)

        // Frames delivered by the connected source must land in the WAL — the wiring the
        // registry refactor must not break.
        for _ in 0..<60 { omi.onFrame?(Data(repeating: 7, count: 40)) }
        wal.flushAndWait()
        XCTAssertGreaterThan(wal.snapshot().totalSegments, 0,
                             "a connected source's frames must reach the WAL via the active-source path")
    }

    // MARK: 2 — auto-connect decision (the "stuck on scanning" fix)

    func testAutoConnectsOnlyToTheSavedDevice() {
        let saved = UUID()
        let other = UUID()
        // A discovered device that IS the saved one → auto-connect.
        XCTAssertTrue(OmiAutoConnect.shouldAutoConnect(discoveredId: saved, savedId: saved))
        // A different nearby Omi → never auto-grabbed.
        XCTAssertFalse(OmiAutoConnect.shouldAutoConnect(discoveredId: other, savedId: saved))
        // No saved device yet (first pairing) → stay an explicit tap.
        XCTAssertFalse(OmiAutoConnect.shouldAutoConnect(discoveredId: other, savedId: nil))
    }

    // MARK: 3 — toggle-off removes the source from the capture-visible set + drives its owner

    func testTogglingOmiOffRemovesItFromCaptureVisibleAndNotifiesOwner() {
        let reg = CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                                        discovery: CaptureSourceRegistryTests.FakeAudioInputDiscovery())
        var enabledEvents: [(CaptureSourceCategory, Bool)] = []
        reg.onSourceEnabledChanged = { enabledEvents.append(($0, $1)) }

        // Both built-ins start enabled + capture-visible.
        XCTAssertTrue(reg.captureVisibleSources.contains { $0.category == .omi })

        // Toggle the Omi OFF.
        reg.setEnabled(CaptureSourceDescriptor.omiId, false)

        // It's gone from the capture-visible set...
        XCTAssertFalse(reg.captureVisibleSources.contains { $0.category == .omi },
                       "a toggled-off Omi must be removed from the capture-visible set")
        XCTAssertFalse(reg.isCaptureVisible(CaptureSourceDescriptor.omiId))
        // ...and its lifecycle owner was told to turn off (so the BLE link is dropped).
        XCTAssertEqual(enabledEvents.map(\.0), [.omi])
        XCTAssertEqual(enabledEvents.map(\.1), [false])

        // Toggling back on re-notifies the owner to resume.
        reg.setEnabled(CaptureSourceDescriptor.omiId, true)
        XCTAssertTrue(reg.isCaptureVisible(CaptureSourceDescriptor.omiId))
        XCTAssertEqual(enabledEvents.last?.1, true)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ cond: @MainActor () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("waitUntil timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
