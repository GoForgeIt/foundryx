// SpeakerConfirmProofUITests — the simulator interaction proof for LOCAL-FIRST speaker
// save (track 20260717T1600_speaker_confirm_local_first). Drives the REAL app over the
// demo-seeded library (`-MainPreview`, omi-demo-2 carries the inferred "Nick") with the
// deterministic `-ConfirmProof` door stub, and attaches screenshots of the flow Nick
// asked for on b232:
//   inline save (offline-then-ack): idle → instant "Saved Nick" + the subtle pending
//   glyph (waiting to sync) → the drain ACKs and the glyph CLEARS (synced).
//   tag sheet: open → save → instant flash → the sheet dismisses ITSELF (never waits on
//   the wire), the saved name in the conversation carrying the pending glyph.
//
// This is the visual proof that a save now succeeds on the phone the INSTANT it is
// tapped and reaches the computer on its own — a momentary disconnect never blocks the
// user nor throws the "couldn't connect to the computer" error Nick hit.

import XCTest

final class SpeakerConfirmProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }

    /// The pending "waiting to sync" glyph (icloud.and.arrow.up) next to the name. Queried
    /// type-agnostically: SwiftUI may surface the symbol as an image OR fold it into the
    /// row's accessibility element (a button), so match on the identifier across any type.
    private func pendingGlyph(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "speaker-sync-pending").firstMatch
    }

    private func launchTranscript(proof: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-Screen", "detail",
                               "-Capture", "omi-demo-2", "-Face", "transcript",
                               "-ConfirmProof", proof]
        app.launch()
        return app
    }

    // ── inline save: instant local success + pending glyph → drain ACK clears it ──

    func testInlineSaveIsInstantThenSyncsInBackground() throws {
        // offline-then-ack: the interactive ship fails (offline) so the save is purely
        // local; the 5s drain then ACKs, clearing the glyph — the local-first proof.
        let app = launchTranscript(proof: "offline-then-ack")
        let confirm = app.buttons["Confirm: Nick"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "inline save affordance renders")
        shoot(app, "01-inline-idle")

        confirm.tap()
        // Within a frame the save has landed LOCALLY — "Saved Nick", never a spinner that
        // waits on the wire. (The confirmed check dwells briefly then clears to the row.)
        XCTAssertTrue(app.staticTexts["Saved Nick"].waitForExistence(timeout: 2),
                      "the save answers instantly with a local success")
        shoot(app, "02-inline-saved-instant")

        // The subtle pending glyph shows the change is waiting to sync to the computer.
        XCTAssertTrue(pendingGlyph(app).waitForExistence(timeout: 4),
                      "a pending-sync glyph rides next to the saved name")
        shoot(app, "03-inline-pending-glyph")

        // The drain ACKs (the DEBUG stub) → the glyph disappears. NO error ever surfaces.
        XCTAssertTrue(waitGone(pendingGlyph(app), timeout: 20),
                      "the glyph clears once the computer acknowledges the change")
        shoot(app, "04-inline-synced-glyph-cleared")
        app.terminate()
    }

    // ── tag sheet: save is instant + the sheet dismisses itself, no live response ──

    func testSheetSaveIsInstantAndSelfDismissesOffline() throws {
        // Pure-offline stub: the sheet must STILL save instantly and dismiss itself —
        // this is the exact case Nick hit ("couldn't connect to the computer").
        let app = launchTranscript(proof: "fail")
        let notThem = app.buttons["Not them"]
        XCTAssertTrue(notThem.waitForExistence(timeout: 10))
        notThem.tap()   // opens the tag sheet for the inferred speaker

        let sheetTitle = app.staticTexts["Tag speaker"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5), "tag sheet opens")
        shoot(app, "05-sheet-open")

        app.buttons["Confirm Nick"].tap()
        // The sheet flashes the saved beat then dismisses ITSELF — even offline, it never
        // waits on the wire nor shows the "couldn't connect" error.
        XCTAssertTrue(waitGone(sheetTitle, timeout: 5),
                      "the sheet dismisses itself on the instant local save, offline")
        shoot(app, "06-sheet-self-dismissed-offline")

        // Back in the conversation the saved name carries the pending-sync glyph (the
        // change is safe on the phone, syncing in the background).
        XCTAssertTrue(pendingGlyph(app).waitForExistence(timeout: 5),
                      "the saved change waits to sync with a subtle glyph, not an error")
        shoot(app, "07-conversation-pending-after-offline-save")
        app.terminate()
    }
}
