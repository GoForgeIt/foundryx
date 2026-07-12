import XCTest
import Foundation
import FoundryXKit

/// Ambient-intelligence Tier-1 lane (track 20260710T2030 v3, features/
/// ambient-intelligence.feature): OPT-IN rolling on-device transcript + a
/// default-NO gate over the newest window, every decision logged. Off = OFF —
/// zero processing. STT + gate are faked (WhisperKit / Foundation Models are the
/// real engines on-device, not runnable in CI).
final class AmbientLaneTests: XCTestCase {

    final class FakeSTT: LocalSTT, @unchecked Sendable {
        var available = true
        var calls = 0
        var textPerCall: [String] = []
        var isAvailable: Bool { available }
        func transcribe(opusFrames: [Data]) async throws -> String {
            let text = textPerCall.indices.contains(calls) ? textPerCall[calls] : "words"
            calls += 1
            return text
        }
    }

    final class FakeGate: AmbientGate, @unchecked Sendable {
        var available = true
        var calls = 0
        var windows: [String] = []
        /// The candidate to surface when the window contains `triggerPhrase`.
        var triggerPhrase: String?
        var isAvailable: Bool { available }
        func evaluate(window: String) async throws -> AmbientCandidate? {
            calls += 1
            windows.append(window)
            if let phrase = triggerPhrase, window.contains(phrase) {
                return AmbientCandidate(
                    utterance: phrase, summary: "look it up", confidence: 0.9)
            }
            return nil   // the default answer is NO
        }
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-ambient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seed a capture with `frames` opus frames split across WAL segments of 120.
    private func seedFrames(_ id: String, dir: URL, count: Int, startSeg: UInt64 = 0) throws {
        let cdir = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        var remaining = count
        var seg = startSeg
        while remaining > 0 {
            let n = min(120, remaining)
            let frames = (0..<n).map { _ in Data([0x98, 0, 0, 0, 0, 0, 0, 0]) }
            try CaptureWAL.encodeSegment(frames)
                .write(to: cdir.appendingPathComponent(CaptureWAL.segName(seg)))
            seg += 1
            remaining -= n
        }
    }

    // Scenario: disabled means zero ambient processing
    func testDisabledMeansZeroProcessing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedFrames("cap-off", dir: dir, count: 300)
        let stt = FakeSTT(); let gate = FakeGate()
        let lane = AmbientLane(baseDir: dir, stt: stt, gate: gate, isEnabled: { false })

        let candidate = await lane.tick(captureId: "cap-off")

        XCTAssertNil(candidate)
        XCTAssertEqual(stt.calls, 0, "no transcript is produced")
        XCTAssertEqual(gate.calls, 0, "no gate evaluation occurs")
        let decisions = await lane.decisions()
        XCTAssertTrue(decisions.isEmpty, "no ambient decision is recorded")
        let transcript = await lane.transcript(captureId: "cap-off")
        XCTAssertEqual(transcript, "")
    }

    // Scenario: while enabled, new audio grows the rolling transcript and is gated
    func testEnabledGrowsTranscriptAndGatesEachNewChunk() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedFrames("cap-on", dir: dir, count: 150)
        let stt = FakeSTT(); stt.textPerCall = ["first minute of speech", "second minute"]
        let gate = FakeGate()
        let lane = AmbientLane(baseDir: dir, stt: stt, gate: gate, isEnabled: { true })

        _ = await lane.tick(captureId: "cap-on")
        var transcript = await lane.transcript(captureId: "cap-on")
        XCTAssertEqual(transcript, "first minute of speech")
        XCTAssertEqual(gate.calls, 1, "the gate evaluates the newest window")

        // A minute later: more frames arrive → ONLY the new ones transcribe.
        try seedFrames("cap-on", dir: dir, count: 150, startSeg: 10)
        _ = await lane.tick(captureId: "cap-on")
        transcript = await lane.transcript(captureId: "cap-on")
        XCTAssertEqual(transcript, "first minute of speech second minute",
                       "the rolling transcript grows")
        XCTAssertEqual(stt.calls, 2)
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.count, 2, "each evaluation is recorded")
        XCTAssertEqual(decisions.map(\.outcome), [.gatedNo, .gatedNo])
    }

    // Scenario: an ordinary conversation produces no candidates
    func testOrdinaryConversationIsAllGatedNo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stt = FakeSTT()
        stt.textPerCall = ["so how was the weekend", "pretty good we hiked", "nice nice"]
        let gate = FakeGate()   // no trigger phrase — never a candidate
        let lane = AmbientLane(baseDir: dir, stt: stt, gate: gate, isEnabled: { true })

        for i in 0..<3 {
            try seedFrames("cap-ordinary", dir: dir, count: 150, startSeg: UInt64(i * 10))
            let candidate = await lane.tick(captureId: "cap-ordinary")
            XCTAssertNil(candidate, "no candidate is surfaced")
        }
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.count, 3)
        XCTAssertTrue(decisions.allSatisfy { $0.outcome == .gatedNo },
                      "every window is gated NO")
    }

    // Scenario: an actionable moment becomes a candidate
    func testActionableMomentSurfacesACandidate() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedFrames("cap-act", dir: dir, count: 150)
        let stt = FakeSTT()
        stt.textPerCall = ["I'll have to look up what we decided about the relay"]
        let gate = FakeGate(); gate.triggerPhrase = "look up what we decided"
        let lane = AmbientLane(baseDir: dir, stt: stt, gate: gate, isEnabled: { true })

        let candidate = await lane.tick(captureId: "cap-act")

        XCTAssertNotNil(candidate, "the gate surfaces a candidate")
        XCTAssertEqual(candidate?.confidence, 0.9)
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.last?.outcome, .candidate)
        XCTAssertEqual(decisions.last?.candidate?.confidence, 0.9,
                       "the candidate is recorded with its confidence")
    }

    // Scenario: a busy or failing engine skips silently
    func testUnavailableEngineSkipsSilentlyAndRecordsIt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedFrames("cap-skip", dir: dir, count: 150)
        let stt = FakeSTT(); stt.available = false
        let gate = FakeGate()
        let lane = AmbientLane(baseDir: dir, stt: stt, gate: gate, isEnabled: { true })

        let candidate = await lane.tick(captureId: "cap-skip")

        XCTAssertNil(candidate)
        XCTAssertEqual(gate.calls, 0)
        let decisions = await lane.decisions()
        XCTAssertEqual(decisions.count, 1, "the skip is recorded")
        XCTAssertEqual(decisions.last?.outcome, .skipped)
        XCTAssertEqual(decisions.last?.skipReason, "stt_unavailable")
    }

    // Ephemerality: ending a capture drops its lane state.
    func testEndCaptureDropsRollingState() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedFrames("cap-end", dir: dir, count: 150)
        let stt = FakeSTT(); stt.textPerCall = ["ephemeral words"]
        let lane = AmbientLane(baseDir: dir, stt: stt, gate: FakeGate(), isEnabled: { true })
        _ = await lane.tick(captureId: "cap-end")
        var transcript = await lane.transcript(captureId: "cap-end")
        XCTAssertEqual(transcript, "ephemeral words")

        await lane.endCapture(captureId: "cap-end")
        transcript = await lane.transcript(captureId: "cap-end")
        XCTAssertEqual(transcript, "", "the rolling buffer is ephemeral by design")
    }
}
