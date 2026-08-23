import XCTest
@testable import FoundryXKit

/// **THE INVARIANT: the derivation the tests grade is the derivation the phone runs.**
///
/// MEASURED 2026-08-23. There are **two** functions that turn a `/status` response into a
/// `RecordingJourneyReading`, and they are not the same function:
///
/// | derivation | production callers | test call sites |
/// |---|---|---|
/// | `CaptureStatusPoller.journey(stage:transcribed:title:droppedReason:transcribeWindows:)` | **1** — `CaptureStatusPoller.swift:480`, the poller itself | 2 |
/// | `RecordingJourneyReading.fromStatus(_:vault:offTheRecorder:)` | **0** | **4** |
///
/// So `RecordingJourneyFeatureTests` — the file carrying this track's headline assertions, including
/// *"a transcribed untitled capture does not claim naming is running"* — grades a function
/// **the phone never calls.** Fix a stage-mapping bug in one and the other keeps it, with a green
/// suite either way. Neither is dead code exactly; each is reachable. They are simply free to drift,
/// and nothing was watching.
///
/// **This test is what stops them drifting.** It does not pick a winner: `fromStatus` accepts
/// richer inputs (`vault`, `offTheRecorder`) that no production caller supplies today, and
/// `journey` is the one whose doc sets the bar — *"this function may only produce a claim it can
/// point at a source for."* Both are legitimate; what is not legitimate is two answers to one
/// question with no comparison between them.
///
/// ⚠ SCOPE. It compares the fields both derive from the same inputs — `transcript` and `naming`.
/// It says nothing about `toTheVault` or `offTheRecorder`, which only `fromStatus` takes and which
/// **no production code supplies** (`VaultUploadReading` is constructed nowhere in `Sources` or
/// `App`). That absence is the subject of AC8's blocker, not of this test.
final class TheTwoJourneyDerivationsAgreeTests: XCTestCase {

    /// Every stage string the door can send, paired with the readings that vary the outcome.
    private static let stages = ["recording", "stored", "transcribing", "transcribed",
                                 "in_lore", "organized", "failed"]

    func testBothDerivationsReadTheSameStatusTheSameWay() {
        var compared = 0
        var disagreements: [String] = []

        for stage in Self.stages {
            for transcribed in [false, true] {
                for title in [nil, "", "Kitchen table, Thursday"] as [String?] {
                    for dropped in [nil, "noise"] as [String?] {
                        for windows in [nil,
                                        CaptureStatusResponse.TranscribeWindowsPayload(windowsDone: 2, windowCount: 20),
                                        CaptureStatusResponse.TranscribeWindowsPayload(windowsDone: 0, windowCount: 0)] {
                            let status = CaptureStatusResponse(
                                stage: stage, loreCaptureId: "c001a016",
                                transcribed: transcribed, title: title,
                                droppedReason: dropped, transcribeWindows: windows)

                            let viaFromStatus = RecordingJourneyReading.fromStatus(status)
                            let viaPoller = CaptureStatusPoller.journey(
                                stage: CaptureLifecycleStage(wire: stage),
                                transcribed: transcribed,
                                title: title,
                                droppedReason: dropped,
                                transcribeWindows: windows)

                            compared += 1
                            let label = "stage=\(stage) transcribed=\(transcribed) "
                                + "title=\(title.map { "\"\($0)\"" } ?? "nil") "
                                + "dropped=\(dropped ?? "nil") "
                                + "windows=\(windows.map { "\($0.windowsDone)/\($0.windowCount)" } ?? "nil")"

                            if viaFromStatus.naming != viaPoller.naming {
                                disagreements.append(
                                    "  naming: fromStatus=\(viaFromStatus.naming) "
                                        + "poller=\(viaPoller.naming)  [\(label)]")
                            }
                            if viaFromStatus.transcript != viaPoller.transcript {
                                disagreements.append(
                                    "  transcript: fromStatus=\(viaFromStatus.transcript) "
                                        + "poller=\(viaPoller.transcript)  [\(label)]")
                            }
                        }
                    }
                }
            }
        }

        // NON-VACUITY. A loop that compared nothing would report perfect agreement, which is the
        // failure mode this whole file exists to catch one level up.
        XCTAssertGreaterThan(compared, 100,
                             "only \(compared) status shapes were compared — the matrix collapsed, "
                                 + "and an agreement claim over almost nothing is not an agreement")

        XCTAssertEqual(disagreements, [],
                       "the two journey derivations disagree on \(disagreements.count) of "
                           + "\(compared) status shapes. The phone runs "
                           + "CaptureStatusPoller.journey; RecordingJourneyFeatureTests grades "
                           + "RecordingJourneyReading.fromStatus. Where they differ, the tested "
                           + "behaviour is not the shipped behaviour:\n"
                           + disagreements.joined(separator: "\n"))
    }
}
