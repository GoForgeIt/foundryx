import XCTest
import Foundation
@testable import FoundryXKit

/// WHAT THE RECORDER PAGE OFFERS FOR WHAT A RECORDER IS HOLDING, HELD AS A POPULATION.
///
/// THIS FILE REPLACES `PocketFastSyncCompositionGateTests`, which held the fast-sync button UP —
/// it asserted the recorder page started a fast sync through the errand and that every line of
/// copy on that button came from the kit. On 2026-08-20 the button, the coordinator, the errand
/// and the presentation were all removed. The address a Pocket serves files from was never
/// measured, and six joins from a phone and a Mac established that the recorder's access point
/// drops a client roughly eight seconds after the WPA2 handshake completes — 7.8s, 8.03s, 8.1s,
/// 8.1s and 8.28s, including one run that issued the file selection and the begin-transfer over
/// Bluetooth with the phone still attached and a real DHCP lease held. Twenty minutes of audio
/// does not cross an eight-second link.
///
/// WHY THIS IS NOT A GREP FOR THE ABSENCE. `XCTAssertFalse(source.contains("fastSync"))` is
/// satisfied by a page with no controls at all, by a rename, and by a `VStack` somebody emptied.
/// It is the shape `PocketRecorderDeleteGate` refuses for the delete verb, and it is the shape
/// that let fast sync sit under `App/` unreachable for months while eight scenarios went green.
/// So the POPULATION comes first — it is non-empty, it is exactly what the kit declares, every
/// member is drawn, and the view walks it — and the ban is a consequence of that rather than a
/// claim standing on its own.
///
/// `features/a-recorders-page-offers-what-it-can-deliver.feature` states the same two facts in
/// the words a person would use.
final class RecorderShelfControlsGateTests: XCTestCase {

    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheShelfBandOffersExactlyTheDeclaredControls() throws {
        // 1. PAIRED EXISTENCE, FIRST. Empty is the FAILING state, not the passing one: a shelf
        //    band that offers a person nothing is the defect `RecorderPageLayout` exists about,
        //    and it is what every rule below would otherwise pass on.
        XCTAssertFalse(RecorderPageLayout.shelfBandOffersNothing,
                       "the shelf band offers no controls at all")
        XCTAssertEqual(RecorderPageLayout.shelfControlOrder, [.bringOver, .removalReport],
                       "the controls a person is offered for what a recorder is holding have "
                           + "changed; that is a decision, not a refactor")

        // 2. EVERY DECLARED CONTROL IS DRAWN. One named and never laid out ships nowhere.
        XCTAssertEqual(RecorderPageLayout.shelfControlsNotLaidOut, [],
                       "a control is declared and the band never draws it")

        // 3. THE VIEW WALKS THE DECLARED POPULATION rather than writing its own statements into
        //    a `VStack` — the half that makes 1 and 2 describe what is actually on screen.
        let screen = try Self.source("App/DeviceScreen.swift")
        XCTAssertTrue(screen.contains("RecorderPageLayout.shelfControlOrder"),
                      "the shelf band does not walk the kit's control order, so the array "
                          + "above is a decision nothing obeys")

        // 4. AND ONLY THEN, THE BAN — over COMPOSITION rather than spelling. What is gone is
        //    the page's ability to START one, which no rename survives.
        XCTAssertFalse(screen.contains("check.fastSync(hardwareToken:"),
                       "the recorder page can still start a fast sync over an access point "
                           + "that drops a client after eight seconds")
        XCTAssertFalse(screen.contains("PocketFastSyncErrand.run("),
                       "the page still reaches the fast-sync errand")
    }

    /// THE SPEED NOBODY MEASURED STILL MAY NOT REACH A PERSON, and now it matters MORE rather
    /// than less. Fast sync is gone, so every recording crosses Bluetooth — and the drain rate
    /// of that link is the number the continuous-pull design turns on. Pocket audio is 32 kbps
    /// CBR, exactly 4,000 bytes per second of wall-clock recording; a link that pulls slower
    /// than that can never catch up. `PocketMeasuredFigures` still carries the figure as an
    /// open planning guess, which is the honest state until somebody times one file.
    func testNoSurfaceCanPrintARateNobodyMeasured() throws {
        for path in ["App/DeviceScreen.swift", "Sources/FoundryXKit/PocketBringOver.swift"] {
            // COMMENTS STRIPPED, STRING LITERALS KEPT — a rendered speed arrives as a string,
            // and a file that RECORDS in prose why a rate may not be printed is the opposite of
            // a file that prints it.
            let source = AppSourceTree.withoutComments(of: try Self.source(path))
            for claim in ["150×", "150x", "about a minute", "in about a", "MB/s\"", "KB/s\""] {
                XCTAssertFalse(source.contains(claim),
                               "\(path) can render \"\(claim)\" — a speed nobody has measured")
            }
        }
    }
}
