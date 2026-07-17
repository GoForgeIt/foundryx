// WaitingExperienceProofUITests — the simulator proof for the honest-wait experience
// (perf track WS-C). Drives the REAL app through the `-Screen waiting <kind>` harness
// for each of the five wait sites, asserts the plain-language headline renders, and
// attaches a screenshot of each state to the .xcresult.

import XCTest

final class WaitingExperienceProofUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func proof(_ kind: String, headline: String, index: Int) {
        let app = XCUIApplication()
        app.launchArguments = ["-Screen", "waiting", kind]
        app.launch()
        XCTAssertTrue(app.staticTexts[headline].waitForExistence(timeout: 8),
                      "\(kind) wait names itself: \(headline)")
        shoot(app, String(format: "%02d-waiting-%@", index, kind))
        app.terminate()
    }

    func testEveryWaitSiteNamesItselfHonestly() throws {
        proof("recap", headline: "Summarizing on your iPhone", index: 1)
        proof("title", headline: "Naming this conversation", index: 2)
        proof("transcription", headline: "Transcribing locally", index: 3)
        proof("door", headline: "Fetching from your Mac", index: 4)
        proof("sync", headline: "Copying to your computer", index: 5)
    }
}
