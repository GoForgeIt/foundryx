import XCTest
import Foundation
@testable import FoundryXKit

/// Slice 2 (phone) of the ambient playbook-routing + full-context grading track
/// (foundryx-hearth 20260710T2030 v3.4). Pins the two testable seams: the door's
/// SELECTED playbook decodes onto the route outcome, and full-context grading
/// defaults ON for the enrolled owner / OFF for everyone else, with an explicit
/// user choice always winning. (The seed text + Settings row are App-target UI,
/// exercised in Xcode/CI.)
final class AmbientPlaybookRouteTests: XCTestCase {

    func testRouteOutcomeDecodesTheSelectedPlaybook() throws {
        // The door returns the concrete playbook + reason so the phone can seed the
        // chat naming WHAT and WHY.
        let json = #"{"route":"playbook","playbook":{"kind":"weekly-review","reason":"they committed to reviewing Q3 before Friday"}}"#
        let out = try JSONDecoder().decode(AmbientRouteOutcome.self, from: Data(json.utf8))
        XCTAssertEqual(out.route, "playbook")
        XCTAssertEqual(out.playbook?.kind, "weekly-review")
        XCTAssertEqual(out.playbook?.reason, "they committed to reviewing Q3 before Friday")

        // A route with no selected playbook decodes to nil → the phone offers a
        // plain confirm card (never a nameless playbook).
        let plain = try JSONDecoder().decode(AmbientRouteOutcome.self, from: Data(#"{"route":"todo"}"#.utf8))
        XCTAssertNil(plain.playbook)
    }

    func testFullContextGradingDefaultsOnForEnrolledOwnerOffOtherwise() throws {
        let fm = FileManager.default

        // No enrolled owner → grading OFF by default.
        let empty = fm.temporaryDirectory.appendingPathComponent("owner-none-\(UUID().uuidString)")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let noPref = UserDefaults(suiteName: "grading-\(UUID().uuidString)")!
        XCTAssertFalse(AmbientPrefs.fullContextGrading(defaults: noPref, ownerVoiceBaseDir: empty),
                       "no enrolled owner → grading OFF by default")

        // Enrolled owner → grading ON by default (record a sample, then enroll it
        // via the real store API).
        let owned = fm.temporaryDirectory.appendingPathComponent("owner-yes-\(UUID().uuidString)")
        try fm.createDirectory(at: owned, withIntermediateDirectories: true)
        try OwnerVoiceStore.save(frames: Array(repeating: Data([0, 1, 2, 3]),
                                               count: OwnerVoiceStore.minimumFrames),
                                 baseDir: owned)
        try OwnerVoiceStore.markEnrolled(baseDir: owned)
        guard case .enrolled = OwnerVoiceStore.state(baseDir: owned) else {
            return XCTFail("owner voice should be enrolled after save + markEnrolled")
        }
        let noPref2 = UserDefaults(suiteName: "grading-\(UUID().uuidString)")!
        XCTAssertTrue(AmbientPrefs.fullContextGrading(defaults: noPref2, ownerVoiceBaseDir: owned),
                      "enrolled owner → grading ON by default")

        // An explicit user choice WINS over the owner default, both directions.
        let off = UserDefaults(suiteName: "grading-\(UUID().uuidString)")!
        off.set(false, forKey: AmbientPrefs.gradingKey)
        XCTAssertFalse(AmbientPrefs.fullContextGrading(defaults: off, ownerVoiceBaseDir: owned),
                       "owner turned it OFF → honored despite enrolled owner")
        let on = UserDefaults(suiteName: "grading-\(UUID().uuidString)")!
        on.set(true, forKey: AmbientPrefs.gradingKey)
        XCTAssertTrue(AmbientPrefs.fullContextGrading(defaults: on, ownerVoiceBaseDir: empty),
                      "non-owner opted IN → honored despite no enrolled owner")
    }
}
