// ChatHeaderRouteLineUITests — T-PHONE-CHATLAW's header acceptance criterion, proved on
// the RENDERED simulator surface, not read from source: "the header has three controls
// and no picker" (tracks.md, T-PHONE-CHATLAW). "-RemoteChat" mounts the computer-tier
// `ChatScreen` (the one carrying the header this track changed) — the phone-tier
// `LocalChatScreen` has no header at all.

import XCTest

final class ChatHeaderRouteLineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHeaderHasThreeControlsNoPickerAndARouteLine() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview", "-RemoteChat"]
        app.launch()

        let chatsTab = app.tabBars.buttons["Chats"].firstMatch
        XCTAssertTrue(chatsTab.waitForExistence(timeout: 15), "Chats tab present")
        chatsTab.tap()

        // The three controls that must exist: the chat-list drawer button, the
        // read-only route line, and "New". `open-chats` is the chat-list button's
        // accessibility identifier (`ChatListCopy.controlAccessibilityIdentifier`,
        // exercised by ActionsProofUITests already).
        let chatList = app.buttons["open-chats"].firstMatch
        XCTAssertTrue(chatList.waitForExistence(timeout: 10), "chat-list drawer control present")

        // `.any` rather than a guessed element type: SwiftUI's accessibility-element
        // classification for a plain HStack + Text/Image (no Button/Menu) is an
        // implementation detail this test should not have to predict.
        let routeLine = app.descendants(matching: .any)["route-line"].firstMatch
        XCTAssertTrue(routeLine.waitForExistence(timeout: 10),
                      "the non-interactive route line is not on screen")
        XCTAssertNotEqual(routeLine.elementType, .button,
                          "the route line rendered as a tappable button, not a read-only line")

        let newChat = app.buttons["new-chat"].firstMatch
        XCTAssertTrue(newChat.exists, "New control present")

        // The old interactive controls this track removed must not exist on the shipped
        // surface — not "we didn't add a test for them," an ACTUAL absence.
        XCTAssertFalse(app.buttons["model-picker"].exists,
                       "the interactive model picker still renders in the header")
        XCTAssertFalse(app.buttons["privacy-picker"].exists,
                       "the interactive privacy picker still renders in the header")
        XCTAssertFalse(app.staticTexts["message-route"].exists,
                       "the superseded per-message route caption still renders")

        // The route line states the privacy truth in words — not just an icon.
        let routeValue = routeLine.value as? String ?? ""
        XCTAssertTrue(routeValue.contains("Open") || routeValue.contains("Private"),
                      "route line does not state the privacy truth: '\(routeValue)'")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "chat-header-three-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
