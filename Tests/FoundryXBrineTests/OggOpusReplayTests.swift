import XCTest
import Foundation
import FoundryXKit

/// Ogg-Opus replay decode path (the "fetches but nothing plays" fix): the Ogg
/// demuxer must recover the raw packets (skipping OpusHead/OpusTags), and the WAV
/// wrapper must produce a well-formed RIFF header. (The Opus→PCM decode itself is
/// AudioToolbox — exercised on-device, not in CI.)
final class OggOpusReplayTests: XCTestCase {

    /// Build one Ogg page holding the given packets (each < 255 bytes for lace
    /// simplicity — mirrors the door's small-packet layout).
    private func page(_ packets: [Data], granule: UInt64 = 960) -> Data {
        var d = Data("OggS".utf8)
        d.append(0)                       // version
        d.append(0)                       // header type
        withUnsafeBytes(of: granule.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [1, 0, 0, 0])   // serial
        d.append(contentsOf: [0, 0, 0, 0])   // page seq
        d.append(contentsOf: [0, 0, 0, 0])   // crc (parser doesn't verify)
        d.append(UInt8(packets.count))       // segment count
        for p in packets { d.append(UInt8(p.count)) }
        for p in packets { d.append(p) }
        return d
    }

    func testDemuxSkipsHeadersAndRecoversPackets() {
        let head = Data("OpusHead".utf8) + Data([1, 1, 0, 0])
        let tags = Data("OpusTags".utf8) + Data([0, 0, 0, 0])
        let a = Data([0x98, 1, 2, 3]), b = Data([0x98, 9, 8])
        var ogg = page([head]); ogg.append(page([tags])); ogg.append(page([a, b]))

        let packets = OggOpusReplay.packets(fromOgg: ogg)
        XCTAssertEqual(packets, [a, b], "audio packets recovered; headers skipped")
    }

    func testDemuxToleratesJunkAndTruncation() {
        XCTAssertTrue(OggOpusReplay.packets(fromOgg: Data("not ogg at all".utf8)).isEmpty)
        var ogg = page([Data([0x98, 1, 2, 3])])
        ogg.removeLast(2)   // torn tail → intact prefix only, never a crash
        XCTAssertTrue(OggOpusReplay.packets(fromOgg: ogg).isEmpty)
        XCTAssertTrue(OggOpusReplay.packets(fromOgg: Data()).isEmpty)
    }

    func testWavWrapProducesWellFormedRIFF() {
        let pcm = Data([0, 1, 2, 3, 4, 5])   // 3 samples
        let wav = OggOpusReplay.wavWrap(pcm16: pcm, sampleRate: 48_000, channels: 1)
        XCTAssertTrue(wav.starts(with: Data("RIFF".utf8)))
        XCTAssertEqual(wav.count, 44 + pcm.count, "44-byte canonical header + data")
        XCTAssertEqual(Array(wav[36..<40]), Array(Data("data".utf8)))
    }
}
