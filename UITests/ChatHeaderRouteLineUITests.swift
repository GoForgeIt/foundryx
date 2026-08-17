// ChatHeaderRouteLineUITests — the chat header, proved on the RENDERED simulator
// surface rather than read from source. "-RemoteChat" mounts the computer-tier
// `ChatScreen` (the one carrying this header) — the phone-tier `LocalChatScreen` has no
// header at all.
//
// A GATE WAS DELETED HERE, and it is being said out loud rather than quietly dropped.
//
// This file used to assert `routeLine.elementType != .button` — "the route line
// rendered as a tappable button, not a read-only line" — as T-PHONE-CHATLAW's
// acceptance criterion that the header had "three controls and no picker". That
// assertion held. It held on a control that could not be operated: the header's model
// picker had been deleted in favour of a plain `HStack`, on the stated ground that
// setting a model "moves to Settings" — and that Settings picker was never built, in
// any checkout. So the gate was passing for the wrong reason: it was defending an inert
// control, and its passing is part of why the inert control survived to ship. Nick
// tapped the "Auto" in the corner and nothing happened.
//
// FX-5A inverts it. The header's route control MUST be tappable, it MUST open, and the
// menu it opens MUST name Kiln's router as the default rather than an unlabelled
// "Auto". The two negative assertions that outlived their subject (`privacy-picker`,
// `message-route`) go with it: `privacy-picker` no longer exists as a separate control
// because privacy is a section INSIDE this menu, and `message-route` was the
// per-message caption whose job the header's line does once instead of under every
// turn. Asserting their absence would now be asserting the absence of things nothing
// proposes to add.

import XCTest

final class ChatHeaderRouteLineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Still three controls — chat list, route control, New — and the middle one OPENS.
    func testHeaderRouteControlOpensAndNamesTheKilnRouter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-RemoteChat"]
        app.launch()

        let chatsTab = app.tabBars.buttons["Chats"].firstMatch
        XCTAssertTrue(chatsTab.waitForExistence(timeout: 15), "Chats tab present")
        chatsTab.tap()

        // `open-chats` is the chat-list button's accessibility identifier
        // (`ChatListCopy.controlAccessibilityIdentifier`, exercised by
        // ActionsProofUITests already).
        let chatList = app.buttons["open-chats"].firstMatch
        XCTAssertTrue(chatList.waitForExistence(timeout: 10), "chat-list drawer control present")

        let newChat = app.buttons["new-chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New control present")

        // THE FIX, ASSERTED: a `Menu` renders as a button. A bare HStack of an Image and
        // a Text — what shipped — does not, so this line fails on the defective build.
        let routeControl = app.buttons["route-line"].firstMatch
        XCTAssertTrue(routeControl.waitForExistence(timeout: 10),
                      "the header's route control is not a button — there is nothing to tap. "
                      + "This is the FX-5A defect: tapping it did nothing because it was "
                      + "a plain HStack with no Button and no Menu around it.")
        XCTAssertTrue(routeControl.isHittable, "the route control is not hittable")

        // It states the privacy truth in words, not just an icon.
        let routeValue = routeControl.value as? String ?? routeControl.label
        XCTAssertTrue(routeValue.contains("Open") || routeValue.contains("Private"),
                      "route control does not state the privacy truth: '\(routeValue)'")

        add(screenshot(app, named: "chat-header-route-control-closed"))

        // IT OPENS.
        routeControl.tap()

        // The default is the Kiln router, NAMED. "Auto" is not the name of anything, and
        // a header that will not name the thing choosing the model leaves the reader
        // unable to tell a working router from a broken one.
        let router = app.buttons["Kiln router"].firstMatch
        XCTAssertTrue(router.waitForExistence(timeout: 10),
                      "the opened route menu does not name the Kiln router as the default")

        // Privacy is a section INSIDE this control now, not a second header control.
        XCTAssertTrue(app.buttons["Private · stays on your Mac"].firstMatch.exists,
                      "the route menu does not offer the private route")

        add(screenshot(app, named: "chat-header-route-menu-open"))

        // Choosing the router closes the menu and leaves the header still stating a route.
        router.tap()
        XCTAssertTrue(app.buttons["route-line"].firstMatch.waitForExistence(timeout: 10),
                      "the header lost its route control after a pick")
        let afterValue = app.buttons["route-line"].firstMatch.value as? String ?? ""
        XCTAssertFalse(afterValue.isEmpty, "the header states nothing after a pick")
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
