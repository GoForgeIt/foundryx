import XCTest
import Foundation
@testable import FoundryXKit

/// WHAT `swift test` CANNOT COMPILE, HELD AS TEXT.
///
/// `App/` is not in the package, so the hostless suite cannot execute the recorder page. The
/// app-hosted lane (`Tests/FoundryXAppScenarioTests/RecorderPageFastSyncFeatureTests`) runs it
/// for real on a simulator; this file holds the two facts that are about the SOURCE and would
/// survive a green behavioural run: that the copy on that button comes from the kit rather than
/// from a literal somebody typed, and that no screen anywhere can print a speed nobody measured.
final class PocketFastSyncCompositionGateTests: XCTestCase {

    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// THE ENTRY POINT EXISTS, AND IT IS WIRED TO THE ERRAND. Before 2026-08-16 a tree-wide
    /// grep for `FastSync` under `App/` returned nothing at all, while the coordinator, its
    /// gates, its copy and eight green scenarios had shipped.
    func testTheRecorderPageStartsFastSyncThroughTheErrand() throws {
        let screen = try Self.source("App/DeviceScreen.swift")
        XCTAssertTrue(screen.contains("check.fastSync(hardwareToken:"),
                      "the recorder page has no way to start a fast sync")
        XCTAssertTrue(screen.contains("await PocketFastSyncErrand.run("),
                      "the page's fast sync action does not reach the errand — a button that "
                          + "calls nothing is the defect this whole track is about")
        XCTAssertTrue(screen.contains("manager.adoptCompletedCapture(captureId: captureID)"),
                      "a fast-synced conversation is never handed to the running app, so it "
                          + "stays invisible and un-uploaded until the next launch")
    }

    /// EVERY LINE ON THAT BUTTON COMES FROM THE KIT. A literal typed into the view is a string
    /// no scenario can hold and no gate can read.
    func testTheFastSyncCopyComesFromThePresentationType() throws {
        let screen = try Self.source("App/DeviceScreen.swift")
        XCTAssertTrue(screen.contains("PocketFastSyncPresentation.settings.primaryAction"))
        XCTAssertTrue(screen.contains("PocketFastSyncPresentation.sheetWarning"))
        XCTAssertTrue(screen.contains("PocketFastSyncPresentation.endpointUnmeasuredLine"),
                      "the page never says why fast sync cannot run, so a disabled button is "
                          + "indistinguishable from a broken one")
        for typed in ["\"Fast sync\"", "\"Use recorder WiFi\"", "\"FAST SYNC\""] {
            XCTAssertFalse(screen.contains(typed),
                           "\(typed) is typed into the view rather than taken from the kit")
        }
    }

    /// THE FIGURE THAT MUST NEVER REACH A PERSON. `~150×` is arithmetic over a number its own
    /// source tags `[GUESS — E-WIFI-RATE measures it; never rendered to users]`. Nobody has
    /// ever measured a Pocket's WiFi throughput.
    func testNoSurfaceCanPrintASpeedNobodyMeasured() throws {
        // PAIRED EXISTENCE FIRST: the population this bans over is non-empty and it is the
        // population the app actually renders.
        XCTAssertGreaterThanOrEqual(PocketFastSyncPresentation.everyLine.count, 14)
        for path in ["App/DeviceScreen.swift", "Sources/FoundryXKit/PocketFastSync.swift",
                     "Sources/FoundryXKit/PocketFastSyncErrand.swift"] {
            // COMMENTS STRIPPED, STRING LITERALS KEPT — `withoutComments`, not `code`. The
            // literal IS the thing being held here: a rendered speed arrives as a string. And
            // a file that RECORDS in prose why `~150×` may never be printed is the opposite of
            // a file that prints it, so a gate that could not tell those apart would make the
            // reason undocumentable.
            let source = AppSourceTree.withoutComments(of: try Self.source(path))
            for claim in ["150×", "150x", "about a minute", "in about a", "MB/s\"", "KB/s\""] {
                XCTAssertFalse(source.contains(claim),
                               "\(path) can render \"\(claim)\" — a speed nobody has measured")
            }
        }
        for line in PocketFastSyncPresentation.everyLine {
            XCTAssertFalse(line.contains(where: \.isNumber),
                           "\"\(line)\" renders a number")
        }
    }

    /// THE ENTITLEMENT IS PRESENT AND IT IS THE RIGHT ONE. Without it iOS refuses the join —
    /// and the profile that carries it is a separate change: a missing profile entitlement
    /// fails at SIGNING, not at runtime.
    func testTheHotspotEntitlementIsDeclared() throws {
        let entitlements = try Self.source("App/FoundryX.entitlements")
        XCTAssertTrue(entitlements.contains("com.apple.developer.networking.HotspotConfiguration"),
                      "the app cannot join an access point, so fast sync can never run on a "
                          + "phone no matter what the coordinator does")
    }

    /// THE ADDRESS IS STILL UNMEASURED, AND THE APP SAYS SO RATHER THAN GUESSING. The reference
    /// decode's own words are "IP: Likely 192.168.4.1 … HTTP endpoint: TBD".
    func testNoEndpointIsInventedWhileNobodyHasMeasuredOne() {
        XCTAssertNil(PocketFastSyncEndpoint.measured,
                     "an endpoint was shipped that nobody has confirmed. Every failure would "
                         + "then look like a broken recorder instead of an unanswered question.")
        XCTAssertEqual(PocketFastSyncPresentation.message(for: .unavailable(.endpoint)),
                       PocketFastSyncPresentation.endpointUnmeasuredLine)
        XCTAssertFalse(PocketFastSyncEvidence.asMeasured().endpointHardwareProvenance)
        XCTAssertFalse(PocketFastSyncEvidence.asMeasured().measuredRate,
                       "a rate was claimed as measured — that is what unlocks the ETA copy")
        // AND THE GATES THAT ARE ANSWERED ARE ANSWERED. Otherwise this passes on a value that
        // simply says no to everything.
        XCTAssertTrue(PocketFastSyncEvidence.asMeasured().stockControlTrace)
        XCTAssertTrue(PocketFastSyncEvidence.asMeasured(endpoint: URL(string: "http://192.0.2.1/x")!)
                        .endpointHardwareProvenance)
    }
}
