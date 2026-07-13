import XCTest
import Foundation
import FoundryXKit

/// Rung 3 (track 20260705T1100 §5): a hosted Foundry CELL as the brain, reached over
/// its direct public HTTPS door. Routing is additive — a chosen-but-unpaired cloud
/// brain degrades to the phone brain, and a paired cell never breaks the other rungs.
final class CellBrainTests: XCTestCase {

    // MARK: RootGate — Foundry Cloud resolves to the cell brain only when paired

    func testFoundryCloudRequiresAPairedCellElseDegradesToPhone() {
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: true,
                                            brain: .foundryCloud, hostResolved: false,
                                            cellPaired: true),
                       .cellBrain, "a paired cloud cell is the active brain")
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: true,
                                            brain: .foundryCloud, hostResolved: false,
                                            cellPaired: false),
                       .phoneBrain,
                       "an unpaired cloud choice degrades to local-only — everything stays readable")
    }

    func testCellBrainStillGatedBySignIn() {
        XCTAssertEqual(RootGate.destination(signedIn: false, splashElapsed: true,
                                            brain: .foundryCloud, hostResolved: false,
                                            cellPaired: true),
                       .signInGate, "nothing is reachable before the forced login")
    }

    func testComputerBrainWinsWhenBothPathsAvailable() {
        // A resolved computer takes precedence over a paired cell only when the choice
        // is .myComputer; the two rungs never collide because they key off `brain`.
        XCTAssertEqual(RootGate.destination(signedIn: true, splashElapsed: true,
                                            brain: .myComputer, hostResolved: true,
                                            cellPaired: true),
                       .computerBrain)
    }

    // MARK: BrainStore — the Foundry Cloud choice persists

    func testFoundryCloudChoiceLabelAndRawValue() {
        XCTAssertEqual(BrainChoice.foundryCloud.rawValue, "cloud")
        XCTAssertEqual(BrainChoice.foundryCloud.label, "Foundry Cloud")
        XCTAssertTrue(BrainChoice.allCases.contains(.foundryCloud))
    }

    // MARK: CellBackend — the door target is built from the cell URL + resolved grant

    func testCellBackendRejectsNonHTTPS() {
        XCTAssertThrowsError(try CellBackend.makeTarget(cellURL: "http://foundry-cell-acme.fly.dev",
                                                        bearer: "abc")) { err in
            // A cell must be reached over HTTPS (public internet, verified grant).
            XCTAssertEqual(err as? CellBackendError, .insecureScheme)
        }
    }

    func testCellBackendBuildsHTTPSTargetWithBearer() throws {
        let target = try CellBackend.makeTarget(cellURL: "https://foundry-cell-acme.fly.dev",
                                                bearer: "door-token-123")
        XCTAssertEqual(target.bearer, "door-token-123")
        XCTAssertNil(target.relay, "rung 3 is direct HTTPS — no relay in the path")
        XCTAssertEqual(target.baseURL.scheme, "https")
        XCTAssertEqual(target.baseURL.host, "foundry-cell-acme.fly.dev")
    }

    func testResolveTargetIdTokenModeRequiresAToken() {
        let cfg = CellConfig(url: "https://foundry-cell-acme.fly.dev", auth: .idToken)
        XCTAssertThrowsError(try CellBackend.resolveTarget(config: cfg, idToken: nil)) { err in
            XCTAssertEqual(err as? CellBackendError, .missingAuth)
        }
        XCTAssertNoThrow(try CellBackend.resolveTarget(config: cfg, idToken: "signed-in-id-token"))
    }

    func testResolveTargetBearerModeUsesStoredBearer() throws {
        let cfg = CellConfig(url: "https://foundry-cell-acme.fly.dev", auth: .bearer("pasted-door-token"))
        let target = try CellBackend.resolveTarget(config: cfg, idToken: nil)
        XCTAssertEqual(target.bearer, "pasted-door-token", "the bearer grant needs no sign-in token")
    }
}
