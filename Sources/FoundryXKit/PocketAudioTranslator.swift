// PocketAudioTranslator — THE TRANSLATOR, and the only thing this leg was allowed to invent.
//
// A Pocket hands over an MP3. The recording pipeline speaks raw Opus packets, 48 kHz mono,
// 960 samples each — that is what an Omi notification carries, what `OpusEncoder48k` turns
// phone-mic PCM into, what `CaptureWAL.encodeSegment` length-frames onto disk, and what the
// door's `mux_ogg_opus` re-containerises for Lore. So the whole job on this side of the
// boundary is: turn one representation into the other. Past that hand-off, a brought-over
// recording is indistinguishable from any other, because it IS the same bytes in the same
// shape going through the same functions.
//
// WHY IT STREAMS, WITH THE ARITHMETIC. Pocket fw-1.6 records 32 kbps CBR — 4,000 bytes per
// second, the constant `StoredFileDevicePresentation.duration` already divides by. Two hours
// is ~29 MB of MP3, which decodes to 2 h × 48,000 samples/s × 2 bytes = **691 MB of PCM**.
// `PocketMP3Decoding.decode(_ mp3: Data) async throws -> PocketPCM` — the shape this replaces —
// takes the whole file as one `Data` and returns the whole decode as another. Doing that on a
// phone is not slow, it is a crash. So nothing here ever holds more than one read block:
//
//     read buffer      8192 frames × Float32 mono                      ≈  32 KB
//     converted block  8192 × (48000/16000) + 1024 samples × 2 bytes   ≈  50 KB
//     packer tail      < 2 × 960 samples × 2 bytes                     ≈   4 KB
//     one Opus packet  ≤ 4000 bytes                                    ≈   4 KB
//                                                                      ---------
//                                                                       < 100 KB
//
// which is FLAT in the length of the recording. A two-hour file and a two-second file cost the
// same peak. The emitted packets are handed to the caller one at a time and are never
// accumulated here either — `PocketCaptureImport` pumps each straight into the WAL, which
// flushes a segment to disk every 50 frames.
//
// WHAT IT DOES NOT DO. It does not mint a capture, write a marker, upload, or finalize. It
// converts audio and counts it. Everything after that is the existing pipeline's, unchanged.

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// What one translation produced. Counts, not audio — the audio went to the caller's sink as
/// it was produced, because holding it is the bug this file exists to avoid.
public struct PocketTranslatedAudio: Sendable, Equatable {
    /// Opus packets emitted, each one 20 ms.
    public let opusPackets: Int
    /// 48 kHz mono samples decoded (before the tail was zero-padded to a frame boundary).
    public let samples: Int
    public init(opusPackets: Int, samples: Int) {
        self.opusPackets = opusPackets
        self.samples = samples
    }
    public var durationSeconds: Double { Double(samples) / 48_000 }
}

/// Why a file a recorder handed over could not be turned into pipeline frames.
public enum PocketTranslationFailure: Error, Sendable, Equatable {
    /// CoreAudio would not open it as audio at all — the bytes are not a recording this build
    /// can read, whatever the first two of them looked like.
    case notReadableAudio
    /// The system Opus encoder or the resampler could not be built. A fault in THIS phone, not
    /// in the file — the recorder still has the only other copy and nothing may be discarded.
    case encoderUnavailable
    /// It opened and read as audio, and there was no audio in it.
    case noAudio
    /// A read failed partway through a file that had opened cleanly.
    case decodeFailed
}

public enum PocketAudioTranslator {

    /// Frames read per pass. ~0.5 s at the recorder's 16 kHz, small enough that peak footprint
    /// is a rounding error and large enough that a two-hour file is ~14,000 reads, not millions.
    public static let readBlockFrames: AVAudioFrameCount = 8192

    /// The format everything downstream already speaks. Not a choice made here — it is
    /// `OpusEncoder48k`'s input, verbatim.
    public static let pipelineSampleRate: Double = 48_000

    /// Decode `url` and hand the caller ONE Opus packet at a time, in order.
    ///
    /// - Parameter emit: called on this thread, once per 20 ms packet. It may throw to abort
    ///   the translation (a WAL that cannot write, an account scope that went away); the throw
    ///   propagates unchanged so the caller sees its own error, not a translation failure.
    /// - Returns: what was produced, so a caller can refuse a file that decoded to nothing.
    @discardableResult
    public static func translate(fileAt url: URL,
                                 emit: (Data) throws -> Void) throws -> PocketTranslatedAudio {
        #if canImport(AVFoundation)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // The bytes are not audio CoreAudio can open. `PocketBLEClient.download` only ever
            // checked for an `0xFF 0xF3` sync WORD, which two arbitrary bytes can satisfy — so
            // this is the first point in the whole leg where "is it a recording" is actually
            // answered rather than guessed at.
            throw PocketTranslationFailure.notReadableAudio
        }
        guard file.length > 0 else { throw PocketTranslationFailure.noAudio }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: pipelineSampleRate,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: readBlockFrames)
        else { throw PocketTranslationFailure.encoderUnavailable }

        let packer = Opus48kFramePacker()
        guard packer.isReady else { throw PocketTranslationFailure.encoderUnavailable }

        let ratio = pipelineSampleRate / file.processingFormat.sampleRate
        var samples = 0

        // ONE PASS, ONE BLOCK AT A TIME. `framePosition < length` rather than "read until zero
        // frames": `AVAudioFile.read` THROWS at EOF on some inputs instead of returning an
        // empty buffer, which would turn a completely successful translation into a decode
        // failure on the very last block.
        while file.framePosition < file.length {
            do {
                try file.read(into: readBuffer, frameCount: readBlockFrames)
            } catch {
                throw PocketTranslationFailure.decodeFailed
            }
            guard readBuffer.frameLength > 0 else { break }

            let capacity = AVAudioFrameCount(Double(readBuffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { throw PocketTranslationFailure.encoderUnavailable }

            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return readBuffer
            }
            guard status != .error else { throw PocketTranslationFailure.decodeFailed }
            guard converted.frameLength > 0, let channel = converted.int16ChannelData else { continue }

            let count = Int(converted.frameLength)
            samples += count
            // THE SHARED FRAMER. Not a second framing rule for files — the same object the
            // phone microphone puts its PCM through.
            var thrown: Error?
            packer.append(UnsafeBufferPointer(start: channel[0], count: count)) { packet in
                guard thrown == nil else { return }
                do { try emit(packet) } catch { thrown = error }
            }
            if let thrown { throw thrown }
        }

        // THE TAIL, WHICH A LIVE STREAM DOES NOT HAVE. A file's last partial frame is real
        // audio somebody recorded; dropping it because it is under 20 ms is a quiet loss.
        var tailError: Error?
        packer.flush { packet in
            guard tailError == nil else { return }
            do { try emit(packet) } catch { tailError = error }
        }
        if let tailError { throw tailError }

        guard packer.packetsEmitted > 0 else { throw PocketTranslationFailure.noAudio }
        return PocketTranslatedAudio(opusPackets: packer.packetsEmitted, samples: samples)
        #else
        throw PocketTranslationFailure.encoderUnavailable
        #endif
    }
}
