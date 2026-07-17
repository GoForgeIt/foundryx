import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/capture-audio-playback.feature` against REAL seams:
///  • `DoorClient.captureAudio(captureId:)` over a URLProtocol stub — 200 ⇒ bytes arrive
///    (loads → plays), 404 ⇒ `nil` (pruned on the computer), a transport failure ⇒ a
///    thrown `URLError` (computer unreachable).
///  • `AudioPlaybackPresentation.failurePresentation(for:)` / `.copy(for:)` — the honest
///    outcome + human copy each failure maps to (never raw NSError text), and the
///    pruned-vs-unreachable distinctness.
///  • `AudioPlaybackPresentation.playbackDisabledReason(isRecording:)` — the gate copy
///    that disables BOTH the Listen row and the "Hear this voice" row while recording.
///
/// The AVAudioSession / AVAudioPlayer / SwiftUI row rendering is not driven here (no
/// FoundryXKit seam for it — it's an AVFoundation concern in the views); this pins the
/// pure decisions the views consume.
final class AudioPlaybackHonestyTests: XCTestCase {

    func testCaptureAudioPlaybackHonestyFeature() async throws {
        let world = PlaybackWorld()
        let registry = StepRegistry(PlaybackSteps.make(world: world))

        let parsed = parseFeatureText(try Self.featureText())
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })
        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "capture-audio-playback scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }

    private static func featureText() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("features/capture-audio-playback.feature"))
    }
}

/// A URLProtocol stub scoped to THIS test: either returns a (status, body) reply or
/// fails the request with a `URLError` so the DoorClient throws a genuine transport
/// error (the "computer unreachable" path). Kept private so it never races the shared
/// `StubURLProtocol` used elsewhere.
final class PlaybackStubProtocol: URLProtocol {
    /// `.success(status, body)` or `.failure(URLError)`.
    nonisolated(unsafe) static var reply: Result<(Int, Data), URLError>?

    static func reset() { reply = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch PlaybackStubProtocol.reply {
        case .success(let (status, body)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "audio/ogg"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .none:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}

private final class PlaybackWorld: @unchecked Sendable {
    enum AudioMode { case available, pruned, unreachable }

    var mode: AudioMode = .available
    var isRecording = false

    // Results captured by the When steps for the Then steps to assert.
    var played = false
    var outcome: AudioPlaybackPresentation.Outcome?
    var presentedText: String?          // the exact copy the row would show (title[/subtitle])
    var disabledReason: String?

    // Whole-conversation scrubber (GAP b232): the elapsed readout + fill the playing row
    // renders, from the pure formatter the SwiftUI transport consumes.
    var elapsedReadout: String?
    var scrubberFraction: Double?

    func reset() {
        mode = .available; isRecording = false
        played = false; outcome = nil; presentedText = nil; disabledReason = nil
        elapsedReadout = nil; scrubberFraction = nil
    }

    func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PlaybackStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// The real Listen tap: fetch the whole-capture audio through DoorClient over the
    /// stub, then classify exactly as the view does (nil ⇒ unavailable; a thrown error ⇒
    /// failurePresentation; bytes ⇒ play).
    func tapListen() async {
        PlaybackStubProtocol.reset()
        switch mode {
        case .available:   PlaybackStubProtocol.reply = .success((200, Data([0x4f, 0x67, 0x67, 0x53])))
        case .pruned:      PlaybackStubProtocol.reply = .success((404, Data()))
        case .unreachable: PlaybackStubProtocol.reply = .failure(URLError(.cannotConnectToHost))
        }
        let client = DoorClient(
            target: DoorTarget(baseURL: URL(string: "http://door.test")!, bearer: "tok"),
            session: session())
        do {
            if let bytes = try await client.captureAudio(captureId: "cap-listen"), !bytes.isEmpty {
                played = true
            } else {
                setOutcome(.unavailable)          // 404 / nil — pruned on the computer
            }
        } catch {
            setOutcome(AudioPlaybackPresentation.failurePresentation(for: error))
        }
    }

    private func setOutcome(_ o: AudioPlaybackPresentation.Outcome) {
        outcome = o
        let copy = AudioPlaybackPresentation.copy(for: o)
        presentedText = [copy.title, copy.subtitle].compactMap { $0 }.joined(separator: " — ")
    }
}

private enum PlaybackSteps {
    static func make(world w: PlaybackWorld) -> [StepDefinition] {
        [
            defineStep("a recorded conversation whose audio is available on the computer") { ctx, _, _ in
                w.reset(); w.mode = .available; return ctx
            },
            defineStep("a recorded conversation whose audio has been pruned from the computer") { ctx, _, _ in
                w.reset(); w.mode = .pruned; return ctx
            },
            defineStep("the computer that holds the audio can't be reached") { ctx, _, _ in
                w.reset(); w.mode = .unreachable; return ctx
            },
            defineStep("a recording is in progress") { ctx, _, _ in
                w.reset(); w.isRecording = true; return ctx
            },
            defineStep("no recording is in progress") { ctx, _, _ in
                w.reset(); w.isRecording = false; return ctx
            },
            defineStep("playback is {int} seconds into a {int} second recording") { ctx, p, _ in
                w.reset()
                let cur = Double(try p.requireInt(0))
                let dur = Double(try p.requireInt(1))
                // The exact readout + fill the playing row shows, from the pure formatter.
                w.elapsedReadout = AudioPlaybackPresentation.elapsed(currentSeconds: cur, durationSeconds: dur)
                w.scrubberFraction = AudioPlaybackPresentation.progressFraction(currentSeconds: cur, durationSeconds: dur)
                return ctx
            },
            defineStep("I tap {string}") { ctx, p, _ in
                _ = try p.requireString(0)   // "Listen"
                await w.tapListen(); return ctx
            },
            defineStep("I look at a conversation's Listen row") { ctx, _, _ in
                w.disabledReason = AudioPlaybackPresentation.playbackDisabledReason(isRecording: w.isRecording)
                return ctx
            },
            defineStep("I look at a speaker's {string} row") { ctx, p, _ in
                _ = try p.requireString(0)   // "Hear this voice"
                w.disabledReason = AudioPlaybackPresentation.playbackDisabledReason(isRecording: w.isRecording)
                return ctx
            },
            defineCheck("the audio loads and then plays") { _, _, _ in
                guard w.played, w.outcome == nil else {
                    throw BrineStepError("expected the audio to play; outcome=\(String(describing: w.outcome))")
                }
            },
            defineCheck("I see {string}") { _, p, _ in
                let expected = try p.requireString(0)   // "Audio no longer available"
                guard w.outcome == .unavailable else {
                    throw BrineStepError("expected .unavailable, got \(String(describing: w.outcome))")
                }
                guard AudioPlaybackPresentation.copy(for: .unavailable).title == expected else {
                    throw BrineStepError("pruned title is not '\(expected)'")
                }
            },
            defineCheck("I do not see any raw error text") { _, _, _ in
                // The row renders ONLY the helper's fixed human copy — never the error's
                // description. Prove it: the presented text equals the helper copy exactly.
                guard let o = w.outcome, let shown = w.presentedText else {
                    throw BrineStepError("no failure was presented")
                }
                let copy = AudioPlaybackPresentation.copy(for: o)
                let expected = [copy.title, copy.subtitle].compactMap { $0 }.joined(separator: " — ")
                guard shown == expected else {
                    throw BrineStepError("presented text '\(shown)' is not the helper copy '\(expected)'")
                }
                // And it carries none of the tell-tale raw-error tokens.
                for token in ["Error Domain", "NSError", "URLError", "Code=", "cannotConnectToHost"] {
                    guard !shown.contains(token) else {
                        throw BrineStepError("presented text leaks raw error token '\(token)': \(shown)")
                    }
                }
            },
            defineCheck("I see that the computer can't be reached") { _, _, _ in
                guard w.outcome == .unreachable else {
                    throw BrineStepError("expected .unreachable, got \(String(describing: w.outcome))")
                }
                guard AudioPlaybackPresentation.copy(for: .unreachable).title == "Can't reach your computer" else {
                    throw BrineStepError("unreachable title is not 'Can't reach your computer'")
                }
            },
            defineCheck("the unreachable message is distinct from the pruned-audio message") { _, _, _ in
                let unreachable = AudioPlaybackPresentation.copy(for: .unreachable)
                let pruned = AudioPlaybackPresentation.copy(for: .unavailable)
                guard unreachable != pruned, unreachable.title != pruned.title else {
                    throw BrineStepError("unreachable and pruned copy are not distinct")
                }
            },
            defineCheck("playback is disabled with the reason {string}") { _, p, _ in
                let reason = try p.requireString(0)
                guard w.disabledReason == reason else {
                    throw BrineStepError("expected disabled reason '\(reason)', got \(String(describing: w.disabledReason))")
                }
            },
            defineCheck("playback is allowed") { _, _, _ in
                guard w.disabledReason == nil else {
                    throw BrineStepError("expected playback allowed, but it was disabled: \(w.disabledReason!)")
                }
            },
            defineCheck("the elapsed readout reads {string}") { _, p, _ in
                let expected = try p.requireString(0)
                guard w.elapsedReadout == expected else {
                    throw BrineStepError("elapsed readout '\(w.elapsedReadout ?? "nil")' != '\(expected)'")
                }
            },
            defineCheck("the scrubber is filled to that position") { _, _, _ in
                // 12s / 245s ≈ 0.04898 — a real, in-range fill (not 0, not full).
                guard let f = w.scrubberFraction, f > 0, f < 1,
                      abs(f - 12.0 / 245.0) < 1e-9 else {
                    throw BrineStepError("scrubber fraction \(String(describing: w.scrubberFraction)) is not 12/245")
                }
            },
            defineCheck("the scrubber is filled to the end") { _, _, _ in
                // A clock tick past the end clamps to a full (never overshooting) track.
                guard let f = w.scrubberFraction, f == 1 else {
                    throw BrineStepError("expected the scrubber clamped to 1.0, got \(String(describing: w.scrubberFraction))")
                }
            },
        ]
    }
}
