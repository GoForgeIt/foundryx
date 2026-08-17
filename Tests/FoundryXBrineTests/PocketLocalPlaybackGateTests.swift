import XCTest
import Foundation
@testable import FoundryXKit

/// The main-thread half of Step 9: working out WHERE a conversation's audio is walks a
/// directory and reads a receipt per candidate — disk, on a screen appearing.
///
/// WHY THIS IS NOT A BRINE SCENARIO. Measured on 2026-08-16 by the presence track and
/// re-confirmed here: a Brine step that `await`s `MainActor.run` inside an `async` XCTest
/// method has its continuation resumed AFTER XCTest declares the case finished, and every
/// `XCTFail` raised from it is dropped. So the thread assertions live in a `@MainActor
/// XCTestCase`, where they run on the thread being measured.
///
/// EVERY ZERO CARRIES A POSITIVE CONTROL. A counter nothing increments satisfies `== 0` on an
/// empty codebase, so the off-main zero is paired with a deliberate main-thread resolve that
/// MUST move the same counter.
@MainActor
final class PocketLocalPlaybackGateTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeRoot(_ name: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-listen-gate-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func seedHeldRecording(in root: URL, captureID: String) async throws -> URL {
        let custody = PocketRecorderFileStore(root: root)
        let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "GATE-LISTEN")
        let key = PocketRecorderFileKey(identity: identity, date: "2026-08-14",
                                        timestamp: "20260814090000")
        let writer = try await custody.beginKeeping(key)
        try writer.write(Data(repeating: 0x2A, count: 512))
        _ = try writer.commit()
        await custody.noteConversation(captureID, for: key)
        return custody.url(for: key)
    }

    func testResolvingTheHeldFileReadsStorageOffTheMainThreadOnly() async throws {
        let root = makeRoot("custody")
        let captureID = PocketCaptureImport.captureId(startedAt: 1_775_000_000,
                                                      uniqueSuffix: "gate0001")
        let expected = try await seedHeldRecording(in: root, captureID: captureID)

        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        let resolved = await Task.detached {
            PocketLocalPlayback.heldFile(forCapture: captureID, in: root)
        }.value
        let duringResolve = CaptureManager.mainThreadTranscriptDecodesForTests

        // Symlinks resolved on BOTH sides: a directory walk under `/var` hands back the
        // `/private/var` spelling of the same file, and that is not a difference worth
        // asserting about.
        XCTAssertEqual(resolved?.resolvingSymlinksInPath(),
                       expected.resolvingSymlinksInPath(),
                       "premise: the held file IS found")
        XCTAssertEqual(duringResolve, 0,
                       "resolving where a recording's audio is read storage on the main thread "
                           + "\(duringResolve) times")

        // POSITIVE CONTROL — this method is @MainActor, so this resolve IS on the main thread.
        _ = PocketLocalPlayback.heldFile(forCapture: captureID, in: root)
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 1,
                       "POSITIVE CONTROL FAILED: a deliberate main-thread resolve did not move "
                           + "the counter, so the zero above proves nothing")
    }

    /// A conversation this phone recorded is refused WITHOUT touching the disk at all — which
    /// is what keeps every non-recorder Listen tap exactly as cheap as it was before Step 9.
    func testAConversationThisPhoneMadeCostsNoDiskAtAll() async throws {
        let root = makeRoot("no-disk")
        _ = try await seedHeldRecording(in: root, captureID: "pkt-20260814-090000-gate0002")

        CaptureManager.resetMainThreadTranscriptDecodesForTests()
        // On the main thread ON PURPOSE: if this took the disk path it would move the counter.
        XCTAssertNil(PocketLocalPlayback.heldFile(forCapture: "cap-20260814-090000-micmicmi",
                                                  in: root))
        XCTAssertEqual(CaptureManager.mainThreadTranscriptDecodesForTests, 0,
                       "a phone-mic conversation walked pocket custody looking for a file that "
                           + "cannot exist for it")
    }

    /// A RECEIPT IS NOT AUDIO. A capture whose receipt survives but whose MP3 does not is not
    /// held here, and saying it is would point playback at a file that is not there.
    func testAReceiptWithoutItsAudioIsNotHeld() async throws {
        let root = makeRoot("receipt-only")
        let captureID = PocketCaptureImport.captureId(startedAt: 1_775_000_000,
                                                      uniqueSuffix: "gate0003")
        let audio = try await seedHeldRecording(in: root, captureID: captureID)
        XCTAssertNotNil(PocketLocalPlayback.heldFile(forCapture: captureID, in: root),
                        "premise: it is held while the audio is there")

        try FileManager.default.removeItem(at: audio)
        XCTAssertNil(PocketLocalPlayback.heldFile(forCapture: captureID, in: root),
                     "a receipt with no audio beside it was claimed as a held recording")
        XCTAssertEqual(PocketLocalPlayback.source(forCapture: captureID, pocketRoot: root),
                       .onTheComputer,
                       "with nothing held here, playback must fall back to the computer")
    }
}
