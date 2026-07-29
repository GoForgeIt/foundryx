import XCTest
import Foundation
import FoundryXKit

/// First-run onboarding: owner-voice sample + the present-once gate
/// (features/onboarding-voice-and-ambient.feature). The ambient toggle itself is a
/// UserDefaults write asserted at the UI layer; here we pin the durable pieces —
/// the voice store's honesty (too-short rejected, replace-not-append, state file)
/// and the pure gate rule.
final class OnboardingVoiceTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-ownervoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func frames(_ n: Int) -> [Data] {
        (0..<n).map { _ in Data([0x98, 1, 2, 3, 4, 5, 6, 7]) }
    }

    // Scenario: teaching my voice records an owner sample
    func testSavingAFullReadAloudStoresTheSample() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(OwnerVoiceStore.state(baseDir: dir), .none)

        try OwnerVoiceStore.save(frames: frames(900), baseDir: dir, now: 42)

        XCTAssertEqual(OwnerVoiceStore.state(baseDir: dir), .recorded(at: 42))
        XCTAssertEqual(OwnerVoiceStore.sampleFrames(baseDir: dir).count, 900,
                       "the sample survives round-trip for the enrollment upload")
    }

    // Scenario: the voice sample must be long enough to be usable
    func testTooShortAttemptIsRejectedAndStoresNothing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try OwnerVoiceStore.save(frames: frames(100), baseDir: dir)) {
            XCTAssertEqual($0 as? OwnerVoiceError,
                           .sampleTooShort(frames: 100, minimum: OwnerVoiceStore.minimumFrames))
        }
        XCTAssertEqual(OwnerVoiceStore.state(baseDir: dir), .none, "nothing is stored")
        XCTAssertTrue(OwnerVoiceStore.sampleFrames(baseDir: dir).isEmpty)
    }

    // Re-teaching replaces the sample (never appends).
    func testReTeachingReplacesThePriorSample() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try OwnerVoiceStore.save(frames: frames(800), baseDir: dir, now: 1)
        try OwnerVoiceStore.save(frames: frames(760), baseDir: dir, now: 2)

        XCTAssertEqual(OwnerVoiceStore.state(baseDir: dir), .recorded(at: 2))
        XCTAssertEqual(OwnerVoiceStore.sampleFrames(baseDir: dir).count, 760)
    }

    // Tier-2 confirmation flips recorded → enrolled; enrolling nothing is a no-op.
    func testEnrollmentTransition() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        OwnerVoiceStore.markEnrolled(baseDir: dir, now: 9)
        XCTAssertEqual(OwnerVoiceStore.state(baseDir: dir), .none, "no sample → no enrollment")

        try OwnerVoiceStore.save(frames: frames(800), baseDir: dir, now: 5)
        OwnerVoiceStore.markEnrolled(baseDir: dir, now: 9)
        XCTAssertEqual(OwnerVoiceStore.state(baseDir: dir), .enrolled(at: 9))
    }

    // Scenario: onboarding appears once after first sign-in / never re-prompted
    func testGatePresentsExactlyOnceAfterSignIn() {
        XCTAssertFalse(OnboardingGate.shouldPresent(signedIn: false, completed: false, hasRecordingHistory: false),
                       "never before sign-in")
        XCTAssertTrue(OnboardingGate.shouldPresent(signedIn: true, completed: false, hasRecordingHistory: false),
                      "first signed-in launch presents")
        XCTAssertFalse(OnboardingGate.shouldPresent(signedIn: true, completed: true, hasRecordingHistory: false),
                       "completed or dismissed → never again")
    }
}
