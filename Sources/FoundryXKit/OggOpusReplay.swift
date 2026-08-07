// OggOpusReplay — make the door's Ogg-Opus replay audio actually PLAYABLE on iOS.
// AVAudioPlayer cannot decode an Ogg-Opus container (the long-standing replay TODO:
// "fetches, then nothing plays"), but the phone already decodes raw Opus packets
// (OpusPCMDecoder, AudioToolbox kAudioFormatOpus). So: parse the Ogg pages back
// into packets → decode to 48 kHz mono Int16 PCM → wrap in a WAV header —
// AVAudioPlayer plays WAV everywhere.
//
// Plus a small replay cache (spec: "shouldn't have to download from the computer
// every time" — keep while the app is open, or a day, whichever is smaller): an
// in-memory store keyed by capture+range holding the CONVERTED wav, 1-day TTL,
// bounded entries. In-memory ⇒ cleared when the app closes, satisfying both bounds.

import Foundation

public enum OggOpusReplay {
    /// Parse an Ogg container into its raw packets (RFC 3533 paging: 27-byte page
    /// header + segment lacing table; packets span pages via 255-lace continuation).
    /// Skips the OpusHead/OpusTags header packets. Pure — unit-testable.
    public static func packets(fromOgg data: Data) -> [Data] {
        var packets: [Data] = []
        var pending = Data()
        let i = data.startIndex
        let bytes = [UInt8](data)
        var idx = 0
        _ = i
        while idx + 27 <= bytes.count {
            // Page header: "OggS" magic.
            guard bytes[idx] == 0x4F, bytes[idx + 1] == 0x67,
                  bytes[idx + 2] == 0x67, bytes[idx + 3] == 0x53 else {
                idx += 1
                continue
            }
            let segCount = Int(bytes[idx + 26])
            let laceStart = idx + 27
            guard laceStart + segCount <= bytes.count else { break }
            var body = laceStart + segCount
            for l in 0..<segCount {
                let lace = Int(bytes[laceStart + l])
                guard body + lace <= bytes.count else { return packets }
                pending.append(contentsOf: bytes[body..<(body + lace)])
                body += lace
                if lace < 255 {
                    // Packet complete.
                    let isHeader = pending.starts(with: Array("OpusHead".utf8))
                        || pending.starts(with: Array("OpusTags".utf8))
                    if !isHeader, !pending.isEmpty {
                        packets.append(pending)
                    }
                    pending = Data()
                }
            }
            idx = body
        }
        return packets
    }

    /// Decode an Ogg-Opus container to a playable WAV (48 kHz mono Int16).
    /// nil when nothing decodes (junk/empty input) — callers surface "unavailable".
    public static func wav(fromOggOpus ogg: Data) -> Data? {
        let opusPackets = packets(fromOgg: ogg)
        guard !opusPackets.isEmpty else { return nil }
        let decoder = OpusPCMDecoder()
        var pcm = Data()
        for packet in opusPackets {
            guard let buf = decoder.decode(packet),
                  let ch = buf.int16ChannelData else { continue }
            let n = Int(buf.frameLength)
            ch[0].withMemoryRebound(to: UInt8.self, capacity: n * 2) { p in
                pcm.append(p, count: n * 2)
            }
        }
        guard !pcm.isEmpty else { return nil }
        return wavWrap(pcm16: pcm, sampleRate: 48_000, channels: 1)
    }

    /// Minimal RIFF/WAV header around raw little-endian Int16 PCM.
    public static func wavWrap(pcm16: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        var d = Data()
        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcm16.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(channels)
        le32(sampleRate); le32(byteRate); le16(blockAlign); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}

/// In-memory replay cache: converted WAV by capture+range key. Lives for the app
/// session, entries expire after a day, bounded to the most recent 16 clips.
public actor AudioReplayCache {
    public static let shared = AudioReplayCache()
    private var store: [String: (wav: Data, at: Date)] = [:]
    private let ttl: TimeInterval = 24 * 3600
    private let maxEntries = 16

    public func key(captureId: String, startMs: Int?, endMs: Int?) -> String {
        "\(captureId):\(startMs ?? -1):\(endMs ?? -1)"
    }

    public func get(_ key: String) -> Data? {
        guard let hit = store[key], Date().timeIntervalSince(hit.at) < ttl else {
            store[key] = nil
            return nil
        }
        return hit.wav
    }

    public func put(_ key: String, wav: Data) {
        store[key] = (wav, Date())
        if store.count > maxEntries {
            // Drop the oldest entry (tiny N — a scan is fine).
            if let oldest = store.min(by: { $0.value.at < $1.value.at })?.key {
                store[oldest] = nil
            }
        }
    }
}
