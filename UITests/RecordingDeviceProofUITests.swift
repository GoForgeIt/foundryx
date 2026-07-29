// RecordingDeviceProofUITests — the simulator proof that the app NAMES THE DEVICE THAT
// RECORDED A CONVERSATION, on the conversation row and again in the detail header.
//
// WHY THIS FILE EXISTS (track 20260725T2306, review round 12 finding H12-2).
//
// This is the one fact the device-agnostic recording track exists to deliver, and until now
// nothing could observe it. `swift test` compiles the SPM package only — it cannot see
// `App/` — so both halves were held by source-text searches in
// `RecordingSurfaceRenderingLedgerTests`, and round 12 showed exactly what a source-text
// search is worth here. Two mutations, each of which deletes the rendering outright:
//
//   * MUT-R12-C — delete the five-line `.task` in `CaptureCard` that invokes
//     `loadAttribution`. `attribution` stays `nil` for the life of the row, `metaLine`
//     returns its base unchanged, and NO CONVERSATION ROW EVER NAMES ITS RECORDER AGAIN.
//     15 tests, 0 failures. The ledger's `loadAttribution: { [weak manager] in` check still
//     passed, because handing a loader over is not the same as invoking it.
//   * MUT-R12-D — pass `attribution: nil` at the detail push site. The
//     `conversation-device` capsule never renders. 15 tests, 0 failures. The ledger's
//     `CaptureAttributionPresentation.attribution(captureId:` check still passed, because
//     the same call also occurs inside the ROW's loader closure — the detail-header caller
//     was held by nothing at all.
//
// Naming a call site proves handover, not invocation. This proof reads the RENDERED SCREEN,
// so both mutations red it. It drives the real app over the `-MainPreview` demo library,
// whose newest conversation (`omi-demo-1`) `DemoSeed` now gives a real
// `.capture-device.json` naming "Proof Recorder Alpha".

import XCTest

final class RecordingDeviceProofUITests: XCTestCase {

    /// The `displayName` inside the seeded device record (`DemoSeed.proofRecorderName`).
    /// Nothing else in the app can produce this string, so finding it on screen means the
    /// seeded record was read, resolved and drawn — not that something coincided.
    private let seededRecorder = "Proof Recorder Alpha"

    /// A device name that was never seeded. The same query that finds the one above must NOT
    /// find this one, or the query is satisfied by anything and proves nothing.
    private let neverSeededRecorder = "Recorder That Was Never Seeded"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(in app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    func testTheRecorderIsNamedOnTheConversationRowAndInItsDetail() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-FreshActionState"]
        app.launch()

        // 1. The list is up, over the seeded demo library.
        let card = app.staticTexts["Launch deck and relay numbers"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20),
                      "the demo conversation card never appeared — the proof never reached "
                          + "the surface it is about")

        // 2. THE ROW NAMES ITS RECORDER. `CaptureCard` loads the attribution off disk in a
        //    `.task` and composes it into the row's meta line; if that load never runs, the
        //    line is its base and this name is nowhere on screen.
        let recorderOnRow = element(in: app, labelContaining: seededRecorder)
        XCTAssertTrue(
            recorderOnRow.waitForExistence(timeout: 15),
            "no conversation row names \"\(seededRecorder)\", the device whose record "
                + "`DemoSeed` wrote beside this conversation. Either the row never loads the "
                + "attribution (the `.task` that invokes `loadAttribution` in `CaptureCard`) "
                + "or it never composes it into the meta line — in both cases the app is back "
                + "to telling nobody which device recorded their conversations")

        // 2b. NEGATIVE CONTROL for the query itself.
        XCTAssertFalse(
            element(in: app, labelContaining: neverSeededRecorder).exists,
            "the row query matches a device name that was never seeded, so it cannot fail — "
                + "the assertion above is not a measurement")
        shoot(app, "01-recorder-named-on-the-conversation-row")

        // 3. THE DETAIL HEADER NAMES IT TOO, in the capsule that carries the a11y id. This is
        //    a SECOND call site with its own read (`conversationDetail(_:)` passes it into
        //    `ConversationFacesView`) — the row's loader says nothing about it.
        card.tap()

        let capsule = app.descendants(matching: .any)
            .matching(identifier: "conversation-device")
            .firstMatch
        XCTAssertTrue(
            capsule.waitForExistence(timeout: 15),
            "the conversation detail renders no `conversation-device` capsule. The header "
                + "shows the recorder only when it is HANDED one; a detail pushed with "
                + "`attribution: nil` compiles, passes every source-text gate, and silently "
                + "drops the one fact this screen gained")
        XCTAssertTrue(
            capsule.label.contains(seededRecorder),
            "the detail's recorder capsule says \"\(capsule.label)\" rather than naming "
                + "\"\(seededRecorder)\" — the capsule renders, but not from this "
                + "conversation's own device record")
        shoot(app, "02-recorder-named-in-the-detail-header")
    }
}
