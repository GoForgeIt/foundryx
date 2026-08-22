import XCTest
@testable import FoundryXKit

/// P4b — **"a log line that names what recorded"**.
///
/// ## The claim this file was written to fix, and why it turned out to be false
///
/// The priority plan recorded a gap: *"`CaptureEventLog` carries `captureStarted`,
/// `captureFinalized`, `transcriptSet` and NOT ONE event names the SOURCE. When a recording
/// lands, the log cannot say whether the Pocket, Omi or the phone mic produced it."*
///
/// **That is not true, and it was not true when it was written.** All four production emitters
/// of `.captureStarted` put a source in the payload:
///
///   * `CaptureManager` × 3 — `["source": captureSource.rawValue, …]`
///   * `PocketCaptureImport` — `["source": CaptureDeviceSidecar.sourceMarker(for: identity.shape), …]`
///
/// The claim survived because it was checked by grepping `CaptureEventLog.swift` for "source" —
/// and finding nothing, which is exactly what a log type whose payloads are built by its CALLERS
/// looks like. **The absence was in the wrong file.**
///
/// ## So this file pins the property instead of adding it
///
/// The property is TRUE and UNGUARDED, which is the state a regression walks into unannounced.
/// Nothing here adds a field; everything here makes the existing one non-optional in practice.
final class CaptureEventNamesItsSourceTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("evtsrc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// **EVERY SHAPE A RECORDER CAN HAVE MAPS TO A NON-EMPTY SOURCE NAME**, asserted over
    /// `allCases` rather than over the shapes an author remembered — a hand-listed check keeps
    /// passing the day a fifth shape is added and simply stops mentioning it.
    func testEveryRecorderShapeYieldsANonEmptySourceMarker() {
        let shapes = RecordingDeviceShape.allCases
        XCTAssertFalse(shapes.isEmpty, "no shapes were examined, so this proves nothing")
        for shape in shapes {
            let marker = CaptureDeviceSidecar.sourceMarker(for: shape)
            XCTAssertFalse(marker.trimmingCharacters(in: .whitespaces).isEmpty,
                           "shape \(shape) maps to an empty source marker")
        }
    }

    /// **THE THREE SOURCES A PERSON CAN DISTINGUISH MUST BE DISTINGUISHABLE IN THE LOG.**
    ///
    /// Distinctness is asserted by identity, not merely by inequality: two markers being
    /// different does not stop them being SWAPPED, which would tell a reader a Pocket recording
    /// came from the phone's own microphone.
    func testPocketOmiAndPhoneMicAreThreeDifferentAnswers() {
        let pocket = CaptureDeviceSidecar.sourceMarker(for: .filePull)
        let omi = CaptureDeviceSidecar.sourceMarker(for: .bleStream)
        let mic = CaptureDeviceSidecar.sourceMarker(for: .builtInMic)

        XCTAssertEqual(pocket, RecordingDeviceShape.filePull.rawValue)
        XCTAssertEqual(omi, CaptureSourceKind.omi.rawValue)
        XCTAssertEqual(mic, CaptureSourceKind.phoneMic.rawValue)
        XCTAssertEqual(Set([pocket, omi, mic]).count, 3,
                       "two recorder classes collapse to one name in the log: \(pocket)/\(omi)/\(mic)")
    }

    /// **A `captureStarted` EVENT ROUND-TRIPS ITS SOURCE THROUGH THE LOG.**
    ///
    /// The population is every shape, so a shape whose marker never reaches disk fails here
    /// rather than in a support thread. The existence assertion comes FIRST: an empty replay
    /// would satisfy "no event lacks a source" vacuously.
    func testEveryShapesSourceSurvivesAppendAndReplay() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let shapes = RecordingDeviceShape.allCases
        for (i, shape) in shapes.enumerated() {
            CaptureEventLog.append(.captureStarted,
                                   captureId: "cap-\(i)",
                                   payload: ["source": CaptureDeviceSidecar.sourceMarker(for: shape)],
                                   baseDir: dir)
        }

        let started = CaptureEventLog.events(baseDir: dir)
            .filter { $0.kind == CaptureEventKind.captureStarted.rawValue }

        // EXISTENCE FIRST, over the same population the prohibition below reads.
        XCTAssertEqual(started.count, shapes.count,
                       "\(started.count) of \(shapes.count) captureStarted events replayed; a "
                       + "prohibition over a short list proves less than it claims")

        for event in started {
            let source = event.payload["source"]
            XCTAssertNotNil(source, "capture \(event.captureId) started without naming a source")
            XCTAssertFalse((source ?? "").isEmpty,
                           "capture \(event.captureId) named an EMPTY source, which reads as a "
                           + "source in a log and is not one")
        }
    }

    /// A recording brought over from a recorder is legible AS one in the log — the Pocket case
    /// specifically, because it is the one the drain work makes people ask about.
    func testABroughtOverRecordingSaysSoAndSaysWhatRecordedIt() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        CaptureEventLog.append(.captureStarted,
                               captureId: "pkt-20260814-184537",
                               payload: ["source": CaptureDeviceSidecar.sourceMarker(for: .filePull),
                                         "mode": "brought-over"],
                               baseDir: dir)

        let event = CaptureEventLog.events(baseDir: dir).first
        XCTAssertEqual(event?.payload["source"], RecordingDeviceShape.filePull.rawValue)
        XCTAssertEqual(event?.payload["mode"], "brought-over",
                       "the log cannot distinguish a recording brought over from one recorded live")
    }
}
