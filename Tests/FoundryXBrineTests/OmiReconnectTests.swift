import XCTest
@testable import FoundryXKit

/// The always-reconnect state machine (pure policy) + the background-restoration
/// spool (real WAL on a temp dir; a mocked frame source stands in for the central).
final class OmiReconnectTests: XCTestCase {

    // MARK: policy — didDisconnect

    func testDisconnectReissuesPendingConnect() {
        // THE fix for "walk away and it never comes back": every transient drop
        // re-issues connect() on the same peripheral — the standing pending connect.
        XCTAssertEqual(OmiReconnectPolicy.onDisconnect(autoConnect: true), .reissuePendingConnect)
    }

    func testUserSuspendedDisconnectStaysDown() {
        XCTAssertEqual(OmiReconnectPolicy.onDisconnect(autoConnect: false), .stayDown)
    }

    // MARK: policy — didFailToConnect (previously a dead end)

    func testFailedConnectRetriesAfterDelay() {
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: true),
                       .retryAfterDelay(OmiReconnectPolicy.failedConnectRetryDelay))
    }

    func testFailedConnectStaysDownWhenSuspended() {
        XCTAssertEqual(OmiReconnectPolicy.onFailToConnect(autoConnect: false), .stayDown)
    }

    // MARK: policy — willRestoreState

    func testRestoreConnectedPeripheralRediscoversServices() {
        XCTAssertEqual(OmiReconnectPolicy.onRestore(state: .connected, autoConnect: true), .discoverServices)
    }

    func testRestorePendingConnectIsLeftAlone() {
        // The classic bug is CANCELLING the pending connect at restore; the correct
        // move is to wait — it completes whenever the device is back in range.
        XCTAssertEqual(OmiReconnectPolicy.onRestore(state: .connecting, autoConnect: true), .waitForPendingConnect)
    }

    func testRestoreDisconnectedReissuesConnect() {
        XCTAssertEqual(OmiReconnectPolicy.onRestore(state: .disconnected, autoConnect: true), .reissuePendingConnect)
    }

    func testRestoreStaysDownWhenSuspended() {
        for s: OmiReconnectPolicy.RestoredPeripheralState in [.connected, .connecting, .disconnected] {
            XCTAssertEqual(OmiReconnectPolicy.onRestore(state: s, autoConnect: false), .stayDown)
        }
    }

    // MARK: restoration spool — a mocked source, a REAL WAL on disk

    private final class MockSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omi-reconnect-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func segFiles(_ base: URL, _ id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(id).path)) ?? [])
            .filter { $0.hasSuffix(".opus") }
    }

    func testDetachedSpoolCannotReopenThroughRetainedSourceCallbacks() {
        let base = tempDir()
        let source = MockSource()
        let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
        spool.attach(to: source)

        source.onState?(.streaming)
        source.onFrame?(Data([0xA1]))
        guard let captureId = spool.activeCaptureId else {
            return XCTFail("spool never opened its initial capture")
        }
        spool.detach()

        let persistedFrameCount: () -> Int = {
            self.segFiles(base, captureId).reduce(into: 0) { count, name in
                let url = base.appendingPathComponent(captureId).appendingPathComponent(name)
                count += CaptureWAL.decodeSegment((try? Data(contentsOf: url)) ?? Data()).count
            }
        }
        let framesBeforeRetainedCallbacks = persistedFrameCount()
        let spooledBeforeRetainedCallbacks = spool.spooledFrameCount

        // The source deliberately retains the closures installed by attach. Once detach
        // acknowledges closure, those stale callbacks must neither reopen a WAL nor write.
        source.onState?(.streaming)
        source.onFrame?(Data([0xB2]))
        let reopenedCaptureId = spool.activeCaptureId
        let postDetachAcceptedFrames = spool.spooledFrameCount - spooledBeforeRetainedCallbacks
        spool.detach()
        let framesAfterRetainedCallbacks = persistedFrameCount()

        XCTAssertTrue(
            reopenedCaptureId == nil
                && postDetachAcceptedFrames == 0
                && framesAfterRetainedCallbacks == framesBeforeRetainedCallbacks,
            """
            detach returned, but retained callbacks reopened \(String(describing: reopenedCaptureId)), \
            accepted \(postDetachAcceptedFrames) frame(s), and changed durable frames \
            \(framesBeforeRetainedCallbacks)->\(framesAfterRetainedCallbacks)
            """
        )
    }

    func testSpoolPersistsStreamedFramesDurably() {
        let base = tempDir()
        let source = MockSource()
        let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
        spool.attach(to: source)

        source.onState?(.streaming)
        for i in 0..<60 { source.onFrame?(Data([UInt8(i % 250), 0xAB])) }   // > one 50-frame chunk
        let opened = spool.activeCaptureId
        spool.detach()

        guard let id = opened ?? firstCaptureId(base) else {
            return XCTFail("spool never opened a capture")
        }
        XCTAssertFalse(segFiles(base, id).isEmpty, "frames must be durable on disk (WAL segments)")
        // The capture must be first-class: source-tagged omi + start stamps, so
        // resume-same-id and the conversation card treat it exactly like a live session's.
        let marker = try? String(contentsOf: CaptureManager.sourceMarkerURL(id, baseDir: base), encoding: .utf8)
        XCTAssertEqual(marker, CaptureSourceKind.omi.rawValue)
        XCTAssertNotNil(ConversationMetaStore.load(captureId: id, baseDir: base)?.startedAt)
    }

    private func firstCaptureId(_ base: URL) -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .first { !$0.hasPrefix(".") && $0.hasPrefix("omi-") }
    }

    func testSpoolResumesRecentCaptureSameId() {
        let base = tempDir()
        // Session 1: a capture interrupted seconds ago (its segments are fresh).
        let s1 = MockSource()
        let spool1 = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
        spool1.attach(to: s1)
        s1.onState?(.streaming)
        for _ in 0..<60 { s1.onFrame?(Data([1, 2, 3])) }
        let firstId = spool1.activeCaptureId
        spool1.detach()
        XCTAssertNotNil(firstId)

        // Session 2 (reconnect inside the silence gap): SAME conversation id.
        let s2 = MockSource()
        let spool2 = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
        spool2.attach(to: s2)
        s2.onState?(.streaming)
        s2.onFrame?(Data([9]))
        XCTAssertEqual(spool2.activeCaptureId, firstId,
                       "a gap inside the silence boundary resumes the same conversation (resume-same-id)")
        spool2.detach()
    }

    func testSpoolMintsNewIdPastTheSilenceGap() throws {
        let base = tempDir()
        // A capture whose newest segment is OLDER than the gap.
        let oldId = "omi-20260101-000000-aaaa1111"
        let oldDir = base.appendingPathComponent(oldId, isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let seg = oldDir.appendingPathComponent(CaptureWAL.segName(0))
        try Data([0, 0, 0, 1, 42]).write(to: seg)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)],
                                              ofItemAtPath: seg.path)
        try Data(CaptureSourceKind.omi.rawValue.utf8).write(to: CaptureManager.sourceMarkerURL(oldId, baseDir: base))

        let source = MockSource()
        let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
        spool.attach(to: source)
        source.onState?(.streaming)
        source.onFrame?(Data([7]))
        XCTAssertNotNil(spool.activeCaptureId)
        XCTAssertNotEqual(spool.activeCaptureId, oldId,
                          "a gap past the silence boundary starts a NEW conversation")
        spool.detach()
    }

    func testSpoolHonorsUserPause() {
        let base = tempDir()
        let source = MockSource()
        let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { true })
        spool.attach(to: source)
        source.onState?(.streaming)
        for _ in 0..<60 { source.onFrame?(Data([1])) }
        spool.detach()
        XCTAssertNil(spool.activeCaptureId, "a user-paused capture must NOT be recorded by a background relaunch")
        XCTAssertNil(firstCaptureId(base))
    }

    // MARK: pre-session hold (review P2 #3) — frames routed before the session WAL
    // is wired (the @MainActor hop after `.streaming`, exactly when recovered
    // offline-cache audio arrives) must be HELD and drained into setWAL, not
    // dropped — the device is advanced past that audio and it is never re-served.

    func testRouterHoldsPreSessionFramesAndDrainsIntoWAL() {
        let base = tempDir()
        let router = FrameRouter(segmenter: SilenceSegmenter(silenceGap: 120))
        let early = (0..<3).map { Data([0xE0, UInt8($0)]) }
        for f in early { router.route(f) }   // no WAL yet — previously dropped

        let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:0")!, bearer: "")
        let wal = CaptureWAL(captureId: "omi-20260717-000000-cafe0001", target: target, baseDir: base)
        router.setWAL(wal)
        let late = Data([0xA1, 0x01])
        router.route(late)
        wal.flushAndWait()

        let segURL = base.appendingPathComponent(wal.captureId).appendingPathComponent(CaptureWAL.segName(0))
        guard let seg = try? Data(contentsOf: segURL) else { return XCTFail("no segment written") }
        let frames = CaptureWAL.decodeSegment(seg)
        XCTAssertEqual(frames, early + [late], "pre-session frames drain first, in order")
    }

    func testSpoolFlushesPartialSegmentOnLinkDrop() {
        let base = tempDir()
        let source = MockSource()
        let spool = OmiRestorationSpool(baseDir: base, silenceGap: 120, paused: { false })
        spool.attach(to: source)
        source.onState?(.streaming)
        for _ in 0..<10 { source.onFrame?(Data([5, 5])) }   // < one chunk — buffered only
        let id = spool.activeCaptureId
        source.onState?(.stopped)                            // link drop → flush durably
        // The io queue processed .stopped before activeCaptureId's io.sync returns.
        XCTAssertNil(spool.activeCaptureId)
        guard let id else { return XCTFail("no capture opened") }
        XCTAssertFalse(segFiles(base, id).isEmpty, "a link drop must flush the partial segment durably")
    }
}
