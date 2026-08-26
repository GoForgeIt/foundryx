import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// The seam scenarios: what crosses the wire, asserted on the crossing itself.
///
/// ⚠ THESE DRIVE THE REAL `DoorClient`. A step that recorded its own crossing would be
/// asserting about the test, which is the shape that let the original defect through — the
/// journey scenarios seeded their own reading and never saw production's default.
///
/// The requests here FAIL at the transport (no door is listening on a reserved-invalid
/// address), and that is deliberate: the claim under test is that the request WAS MADE and
/// on WHICH LEG, not that it succeeded. A seam record written only on success cannot
/// distinguish "never sent" from "sent and refused" — and "never sent" was the actual bug.
final class SeamCrossingFeatureTests: XCTestCase {

    private static let conversationsPath = "/foundryx/conversations"

    private final class World: @unchecked Sendable {
        var target: DoorTarget?
    }

    private static func relayTarget() -> DoorTarget {
        DoorTarget(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            bearer: "seam-test",
            relay: RelayConfig(
                relayURL: URL(string: "ws://127.0.0.1:1")!,
                tunnelId: "seam-test-tunnel",
                staticPrivate: Data(repeating: 1, count: 32),
                expectedDoorStatic: Data(repeating: 2, count: 32)))
    }

    private static func directTarget() -> DoorTarget {
        DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "seam-test")
    }

    func testSeamCrossingScenarios() async throws {
        let w = World()

        let registry = StepRegistry([
            defineStep("a phone whose computer is reachable") { ctx, _, _ in
                DoorSeam.reset()
                w.target = Self.relayTarget()
                return ctx
            },
            defineStep("a phone whose computer is reachable only on this network") { ctx, _, _ in
                DoorSeam.reset()
                w.target = Self.directTarget()
                return ctx
            },
            defineStep("the phone asks the computer for its list") { ctx, _, _ in
                guard let target = w.target else {
                    throw BrineStepError("no target was established")
                }
                // The REAL client. The throw is expected and irrelevant — the seam record
                // is written before the transport is attempted, which is the whole point.
                _ = try? await DoorClient(target: target).conversationPage(query: "", limit: 50)
                return ctx
            },

            defineCheck("a request for the conversation list crosses the seam") { _, _, _ in
                try expect(
                    DoorSeam.legFor(path: Self.conversationsPath) != nil,
                    "no request for \(Self.conversationsPath) crossed the seam. This is the "
                    + "exact shape of the 2026-08-26 defect: the phone was connected, the "
                    + "code was correct, and nothing was ever sent.")
            },
            defineCheck("that request crosses on the relay leg") { _, _, _ in
                let leg = DoorSeam.legFor(path: Self.conversationsPath)
                try expect(leg == .relay,
                           "the request crossed on \(leg.map(\.rawValue) ?? "no") leg, not the "
                           + "relay. A route with only a direct leg cannot reach a Mac the "
                           + "phone is not on the network with, and fails silently.")
            },
            defineCheck("that request crosses on the direct leg") { _, _, _ in
                let leg = DoorSeam.legFor(path: Self.conversationsPath)
                try expect(leg == .direct,
                           "expected the direct leg with no relay configured, got "
                           + "\(leg.map(\.rawValue) ?? "no crossing")")
            },
            defineCheck("no request for the conversation list has crossed the seam") { _, _, _ in
                // The NEGATIVE control. Without it every check above is satisfied by a
                // recorder that reports a crossing unconditionally.
                try expect(DoorSeam.legFor(path: Self.conversationsPath) == nil,
                           "a crossing was recorded when the phone had asked for nothing — "
                           + "the recorder is reporting requests that were never made")
            },
            defineCheck("the recorded crossing carries no query string") { _, _, _ in
                let recorded = DoorSeam.recorded.map(\.path)
                try expect(recorded.allSatisfy { !$0.contains("?") },
                           "a seam record leaked a query string: \(recorded). The record is "
                           + "evidence of a crossing, not a transcript of the owner's search.")
            },
        ])

        let result = try await BrineFeatureRunner.run(
            "the-phone-asks-the-computer-across-the-seam", registry: registry)
        XCTAssertEqual(result.passed, 5, "every seam scenario must run and pass")
    }
}

/// Local mirror of the same helper the other feature suites use — `private` there, so it
/// cannot be shared without moving it, and moving it is not this change's business.
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw BrineStepError(message) }
}
