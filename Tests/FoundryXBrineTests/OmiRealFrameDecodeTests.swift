import XCTest
import Foundation
@testable import FoundryXKit

/// Ground-truth decode test against REAL Omi Opus frames (captured off the device,
/// extracted from a synced WAL segment — TOC byte 0xb8 = CELT-only / Wideband / 20ms
/// / mono). The synthetic AudioToolbox-encoded test packets decoded fine even with
/// the wrong ASBD, which masked the real bug; these are the actual packets the
/// on-device meter sees. The decoder MUST turn them into PCM (the inverse of the
/// on-device `pcm=0` / flat-bars symptom). This is the CQRS-style fixture that lets
/// the decoder be fixed locally instead of guess-ship-guess through TestFlight.
final class OmiRealFrameDecodeTests: XCTestCase {

    private struct Fixture: Decodable { let source: String; let frames_b64: [String] }

    private func realFrames() throws -> [Data] {
        let url = try XCTUnwrap(TestFixtureBundle.current.url(forResource: "omi_real_frames", withExtension: "json"),
                                "omi_real_frames fixture missing from the test bundle")
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return fx.frames_b64.map { Data(base64Encoded: $0)! }
    }

    func testRealOmiFramesDecodeToPCM() throws {
        let frames = try realFrames()
        XCTAssertGreaterThan(frames.count, 0, "fixture has frames")
        let meter = OpusLevelMeter()
        var pcmCount = 0
        var maxLevel: Float = 0
        for f in frames {
            let level = meter.level(for: f)
            if meter.lastPCMFrames > 0 { pcmCount += 1 }
            maxLevel = max(maxLevel, level)
        }
        // The exact device failure was status=noErr (0) but pcm=0 for every frame.
        XCTAssertEqual(meter.lastStatus, 0, "decode status should be noErr")
        // EVERY real packet must decode (the bug decoded only the first, then EOS-stalled).
        XCTAssertEqual(pcmCount, frames.count,
            "every real Omi packet must decode to PCM (decoded \(pcmCount)/\(frames.count); "
            + "cookieStatus=\(meter.lastCookieStatus))")
        // Real voiced frames must clear the segmenter's voice threshold so the bars
        // move AND conversations auto-open on speech.
        XCTAssertGreaterThan(maxLevel, SilenceSegmenter().silenceThreshold,
            "real voiced frames should read above the silence threshold (got max \(maxLevel))")
    }
}
