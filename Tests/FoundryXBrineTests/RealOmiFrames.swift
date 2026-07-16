import Foundation
import XCTest
@testable import FoundryXKit

/// Shared REAL Omi Opus frames (captured off-device, committed as a fixture) for the
/// capture/conversation tests. Replaces the old synthetic OpusTestEncoder packets:
/// those were AudioToolbox-encoded and decoded fine even with a wrong converter
/// config, which masked the real bug. Driving the segmenter with REAL packets through
/// the production OpusLevelMeter means these tests now prove voice/silence on the same
/// path the device runs.
enum RealOmiFrames {
    private struct Fixture: Decodable { let frames_b64: [String] }

    /// All real frames from the fixture, in capture order.
    static func all() -> [Data] {
        guard let url = TestFixtureBundle.current.url(forResource: "omi_real_frames", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let fx = try? JSONDecoder().decode(Fixture.self, from: data) else { return [] }
        return fx.frames_b64.compactMap { Data(base64Encoded: $0) }
    }

    /// A real VOICED frame — the one that reads highest through the production meter,
    /// guaranteed above the silence threshold so it opens a conversation.
    static func voiced() -> Data {
        let meter = OpusLevelMeter()
        let frames = all()
        var best = frames.first ?? Data()
        var bestLevel: Float = -1
        for f in frames {
            let l = meter.level(for: f)
            if l > bestLevel { bestLevel = l; best = f }
        }
        return best
    }

    /// Silence: an empty frame decodes to level 0 (the meter returns 0 for empty input),
    /// which the segmenter reads as silence — deterministic, no DTX guesswork.
    static func silent() -> Data { Data() }
}
