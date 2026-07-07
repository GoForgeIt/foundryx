import XCTest
import Foundation
import FoundryXKit

/// Phases 6/7 (track 20260705T1100): the sign-in-first routing rule and the
/// connect-a-brain replay-seed. Switching brains is additive, never destructive.
final class BrainMigrationTests: XCTestCase {

    // MARK: RootGate — sign in first, whole without a brain

    func testSignInGatesEverything() {
        XCTAssertEqual(RootGate.destination(signedIn: false, splashElapsed: true,
                                            brain: .justMyPhone, hostResolved: true),
                       .signInGate, "nothing is reachable before the forced login")
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: false,
                                            brain: .justMyPhone, hostResolved: false),
                       .signInGate, "the branded splash still shows briefly")
    }

    func testPhoneBrainNeedsNoHost() {
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: true,
                                            brain: .justMyPhone, hostResolved: false),
                       .phoneBrain, "the app is WHOLE without a desktop or host")
    }

    func testComputerBrainRequiresAResolvedHostElseDegradesToPhone() {
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: true,
                                            brain: .myComputer, hostResolved: true),
                       .computerBrain)
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: true,
                                            brain: .myComputer, hostResolved: false),
                       .phoneBrain,
                       "an unreachable computer degrades to local-only — everything stays readable")
    }

    // MARK: BrainStore — migration-safe defaults

    func testFreshInstallDefaultsToJustMyPhone() {
        let d = UserDefaults(suiteName: "brain-\(UUID().uuidString)")!
        XCTAssertEqual(BrainStore(defaults: d).choice, .justMyPhone)
    }

    func testPairedDesktopInstallStaysOnComputer() {
        let d = UserDefaults(suiteName: "brain-\(UUID().uuidString)")!
        XCTAssertEqual(BrainStore(defaults: d, hasPairedDesktop: true).choice, .myComputer,
                       "an install that already paired must NOT silently switch tiers")
    }

    func testExplicitChoicePersistsOverTheDefault() {
        let d = UserDefaults(suiteName: "brain-\(UUID().uuidString)")!
        BrainStore(defaults: d).select(.myComputer)
        XCTAssertEqual(BrainStore(defaults: d, hasPairedDesktop: false).choice, .myComputer)
    }

    // MARK: BrainSeeder — replay-seed on connect

    private func seedLocalCapture(_ id: String, dir: URL, confirmed: Bool) throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        try CaptureWAL.encodeSegment([Data([1, 2])]).write(to: cdir.appendingPathComponent(CaptureWAL.segName(0)))
        try Data().write(to: cdir.appendingPathComponent("seg-000000000000.ack"))
        try Data("5".utf8).write(to: cdir.appendingPathComponent(".upload-watermark"))
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "local words", title: nil, summary: nil, fetchedAt: 1),
            captureId: id, baseDir: dir, markConfirmed: confirmed)
    }

    func testRearmRequeuesLocalCapturesButNeverLoreConfirmedOnes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try seedLocalCapture("local-1", dir: dir, confirmed: false)   // phone-only
        try seedLocalCapture("lore-1", dir: dir, confirmed: true)     // already in Lore

        let rearmed = BrainSeeder.rearmForDoorSeed(baseDir: dir)
        XCTAssertEqual(rearmed, 1, "only the phone-only capture is re-queued")

        let localDir = dir.appendingPathComponent("local-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("seg-000000000000.ack").path),
                       "fake local ACKs are dropped so the drain re-uploads")
        XCTAssertFalse(FileManager.default.fileExists(atPath: localDir.appendingPathComponent(".upload-watermark").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent(".needs-finalize").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent(CaptureWAL.segName(0)).path),
                      "the audio itself is never touched")

        let loreDir = dir.appendingPathComponent("lore-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loreDir.appendingPathComponent("seg-000000000000.ack").path),
                      "a Lore-confirmed capture is left completely alone")

        // Additive & idempotent: nothing new on a second pass.
        XCTAssertEqual(BrainSeeder.rearmForDoorSeed(baseDir: dir), 1,
                       "re-arm is repeatable until Lore confirms (marker still absent)")
        let kinds = CaptureEventLog.events(baseDir: dir).map(\.kind)
        XCTAssertTrue(kinds.contains("brain_seed_rearmed"))
    }

    func testLocalTranscriptDoesNotClaimLoreConfirmed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-seed2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        TranscriptCacheStore.save(
            CachedTranscript(transcript: "t", title: nil, summary: nil, fetchedAt: 1),
            captureId: "c", baseDir: dir, markConfirmed: false)
        XCTAssertTrue(TranscriptCacheStore.hasCachedTranscript(captureId: "c", baseDir: dir))
        XCTAssertFalse(TranscriptCacheStore.isConfirmedInLore(captureId: "c", baseDir: dir),
                       "an on-phone transcript must never claim Lore confirmed it")
    }
}
