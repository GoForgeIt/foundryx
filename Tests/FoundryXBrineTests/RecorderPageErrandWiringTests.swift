// THE WIRING THE APP-HOSTED LANE CANNOT SEE, HELD OVER THE SOURCE.
//
// `Tests/FoundryXAppScenarioTests` drives `PocketRecorderCheckModel` inside the shipping app
// and proves what the MODEL does. What it cannot do is dismiss a SwiftUI view: that lane is
// explicit that it does not render (`AppScenarioHost`, "WHAT IT DELIBERATELY IS NOT"), so the
// step that stands in for leaving the page calls `check.cancel()` directly. That leaves one
// link unheld — whether the VIEW calls it — and an unheld link is exactly how `PocketBLEClient
// .download` shipped complete, covered and callerless.
//
// So this file holds the three claims that are about the file's SHAPE rather than its
// behaviour, and each is paired with an existence assertion over the same population: a
// prohibition alone passes vacuously on a file that has been deleted.
//
// STATED LIMIT: this is `AppSourceTree`'s lexer, not a compiler. It knows nothing of `#if`, so
// code behind a false branch still counts. That is the safe direction for every claim here.

import XCTest
@testable import FoundryXKit

final class RecorderPageErrandWiringTests: XCTestCase {

    private static let path = "App/DeviceScreen.swift"

    private func source() throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(Self.path)
        return try String(contentsOf: url)
    }

    /// EXISTENCE FIRST. Every prohibition below is over this population, and a population of
    /// zero satisfies all of them.
    func testTheRecorderPageExistsAndOwnsTheCheckModel() throws {
        let code = AppSourceTree.code(of: try source())
        XCTAssertTrue(code.contains("final class PocketRecorderCheckModel"),
                      "\(Self.path) no longer declares the model these gates are about")
        // OWNERSHIP, IN TWO HALVES, BECAUSE THE DECLARATION ALONE STOPPED BEING ENOUGH.
        //
        // This used to pin ONE SPELLING — `@StateObject private var check =
        // PocketRecorderCheckModel()` — and Step 10 legitimately changed it: the model became
        // an init parameter so the simulator proof can mount the page with an answered shelf,
        // which a device with no radio cannot otherwise reach. The gate went red for a change
        // that did not break the property it is about.
        //
        // So the property is asserted instead of the spelling, and it is asserted on BOTH
        // halves. The view must still OWN the model with `@StateObject` (an `@ObservedObject`
        // here is the recreated-every-body-pass defect that loses a running errand), and
        // PRODUCTION must still get a real one without asking — a seam whose default was
        // removed would hand every live call site whatever the last test passed.
        XCTAssertTrue(code.contains("@StateObject private var check"),
                      "no view owns the check model, so nothing on this page can reach a recorder")
        XCTAssertTrue(code.contains("_check = StateObject(wrappedValue: check)")
                        || code.contains("@StateObject private var check = PocketRecorderCheckModel()"),
                      "the check model is declared but never initialised into the view's own "
                        + "storage, so the page holds no errand across a body pass")
        XCTAssertTrue(code.contains("check: PocketRecorderCheckModel = PocketRecorderCheckModel()")
                        || code.contains("@StateObject private var check = PocketRecorderCheckModel()"),
                      "the model is injectable with NO production default, so a live recorder "
                        + "page depends on every call site remembering to build one")
    }

    /// THE LINK THE APP-HOSTED LANE STANDS IN FOR. `cancel()` proven to stop the errand is
    /// worth nothing if leaving the page never calls it.
    func testLeavingTheRecorderPageCancelsTheErrand() throws {
        let code = AppSourceTree.code(of: try source())
        XCTAssertTrue(code.contains(".onDisappear { check.cancel() }"),
                      """
                      the recorder page does not cancel the errand when it goes away. \
                      `PocketRecorderCheckModel.cancel()` can be perfect and the radio still \
                      stays connected to a device nobody is looking at.
                      """)
        XCTAssertTrue(code.contains("@Environment(\\.scenePhase) private var scenePhase"),
                      "the page cannot notice being backgrounded")
        XCTAssertTrue(code.contains(".onChange(of: scenePhase)"),
                      """
                      backgrounding the app does not stop the errand. `onDisappear` does NOT \
                      fire when the app goes to the background with this page on top — which \
                      is precisely what a person does while a slow transfer runs.
                      """)
    }

    /// A SCREENSHOT IS NOT A DEPARTURE, AND THE VIEW MUST NOT DECIDE THAT FOR ITSELF.
    ///
    /// The shipped line was `.onChange(of: scenePhase) { phase in if phase != .active {
    /// check.cancel() } }`. iOS reports `.inactive` for a screenshot, Control Center, the app
    /// switcher and a notification banner — so the one comparison killed a transfer for four
    /// things that are not somebody leaving, which is exactly what Nick hit on his own phone.
    ///
    /// Both halves are here on purpose. The PROHIBITION is over the comparison; the
    /// EXISTENCE half is that the phase still reaches the model, because a page that stopped
    /// observing scene changes altogether would satisfy the prohibition and lose the
    /// background-time release the model now owns.
    func testAMomentaryInterruptionDoesNotCancelTheErrand() throws {
        let code = AppSourceTree.code(of: try source())
        let collapsed = code.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertFalse(collapsed.contains("if phase != .active { check.cancel() }"),
                       """
                       the recorder page still cancels the errand for ANY phase that is not \
                       .active. iOS reports .inactive for a screenshot, Control Center, the \
                       app switcher and a notification banner, and none of those is the owner \
                       leaving — so taking a picture of the progress kills the transfer.
                       """)
        XCTAssertFalse(collapsed.contains("phase != .active"),
                       """
                       the recorder page still decides what a scene phase means with a raw \
                       comparison. That decision belongs to \
                       `PocketErrandScenePhasePolicy`, where `swift test` can hold it: nothing \
                       in this repository can execute a SwiftUI body.
                       """)
        XCTAssertTrue(code.contains("check.sceneChanged(to: PocketErrandScenePhase(phase))"),
                      """
                      the page no longer hands the scene phase to the model, so nothing \
                      releases the background time an errand is holding when the app is \
                      actually put away.
                      """)
    }

    /// A TRANSFER THAT SURVIVES BACKGROUNDING NEEDS THE SYSTEM'S PERMISSION TO.
    ///
    /// Declining to cancel is not continuing: iOS suspends a backgrounded process within
    /// seconds, and a suspended app's Bluetooth callbacks and Task continuations stop dead. So
    /// the model must TAKE background time when an errand starts, and give it back when the
    /// errand ends — and both must happen at the errand choke points rather than at one of the
    /// five entry points somebody remembered.
    func testTheErrandHoldsBackgroundTimeAndGivesItBack() throws {
        let model = try checkModelBody()
        XCTAssertTrue(model.contains("PocketBackgroundLease("),
                      """
                      the check model holds no background-time lease, so a bring-over that is \
                      still running when the phone goes in a pocket is suspended by the system \
                      mid-transfer with the page still claiming it is working.
                      """)
        // AT THE CHOKE POINTS. `beginErrand`/`finishErrand` are the one start and the one stop
        // every errand on this page passes through — the check, the bring-over, the two
        // removals and the fast sync. Taking the assertion anywhere else is five call sites
        // and four chances to forget.
        let begin = try slice(of: model, from: "private func beginErrand(", upTo: "\n    ///")
        XCTAssertTrue(begin.contains("lease.begin(subject:"),
                      "an errand starts without taking background time")
        let finish = try slice(of: model, from: "private func finishErrand(", upTo: "\n    ///")
        XCTAssertTrue(finish.contains("lease.end()"),
                      """
                      an errand can stop without giving the background time back. An assertion \
                      that outlives its errand is how iOS terminates the app.
                      """)
        // AND PRODUCTION LEASES FROM THE SYSTEM. The scenario seam is `#if DEBUG`, so a
        // Release binary has no door — but a default that stopped being `.live` would leave
        // every shipping transfer holding nothing while the counts stayed green.
        let factory = try slice(of: model,
                                from: "private static func backgroundTime()",
                                upTo: "\n    ///")
        XCTAssertTrue(factory.contains("return .live"),
                      """
                      the shipping model no longer leases background time from the system, so \
                      the counts a scenario asserts are about a budget nothing in life uses.
                      """)
    }

    /// The text between two markers, so a claim about ONE function is not a claim about the
    /// whole file. A lexical slice, not a parse — see this file's stated limit.
    private func slice(of body: String, from start: String, upTo end: String) throws -> String {
        guard let begins = body.range(of: start) else {
            throw XCTSkip("`\(start)` is gone from the model")
        }
        let rest = String(body[begins.lowerBound...])
        guard let ends = rest.range(of: end) else { return rest }
        return String(rest[..<ends.lowerBound])
    }

    /// AC5. The defect in one line: the recorder page's attachment factory defaulted its log
    /// to `nil` while its sibling 450 lines down the SAME FILE defaulted to `.shared`, so the
    /// slowest and most failure-prone path in the app was the one whose telemetry was thrown
    /// away. A required parameter is how that cannot recur by omission.
    func testTheRecorderPageAttachmentAlwaysGetsALog() throws {
        let code = AppSourceTree.code(of: try source())
        XCTAssertFalse(code.contains("makeAttachment(log: DoorLog? = nil)"),
                       """
                       the check model's attachment factory still defaults its log to nil. \
                       `RecordingDeviceAttachment` logs the exact reason a tap stopped and \
                       every one of those lines goes nowhere.
                       """)
        // AND THE POSITIVE HALF: the factory exists, is required to take a log, and every
        // caller passes the process-wide one. A file with no factory at all would satisfy the
        // prohibition above.
        XCTAssertTrue(code.contains("makeAttachment(log: DoorLog)"),
                      "the check model no longer has an attachment factory taking a log")
        // SCOPED TO THE CHECK MODEL. `RecordingDeviceAttachModel` lives in this same file and
        // has its own `Self.makeAttachment(` call sites; counting the file's would be counting
        // the sibling this track is explicitly not allowed to edit.
        let model = try checkModelBody()
        //
        // FOUR SINCE STEP 6. The check, the bring-over, and the TWO removal errands the delete
        // ruling's two paths need — an explicit tap and the owner-armed clear. Each opens its
        // own session, so each builds its own attachment; `teardown()` retires an attachment's
        // link and generation, which makes one single-use by construction.
        let calls = model.components(separatedBy: "Self.makeAttachment(").count - 1
        XCTAssertEqual(calls, 4,
                       "the check model builds \(calls) attachment(s); the check, the "
                       + "bring-over and the two removal paths are all expected to")
        let logged = model.components(separatedBy: "Self.makeAttachment(log: DoorLog.shared)")
            .count - 1
        XCTAssertEqual(logged, 4,
                       "\(logged) of \(calls) attachment call sites pass the shared log")
    }

    /// `PocketRecorderCheckModel`'s own text, from its declaration to the next top-level one.
    /// A lexical slice, not a parse — see this file's stated limit.
    private func checkModelBody() throws -> String {
        let code = AppSourceTree.code(of: try source())
        guard let start = code.range(of: "final class PocketRecorderCheckModel") else {
            throw XCTSkip("the model is gone — held by testTheRecorderPageExistsAndOwnsTheCheckModel")
        }
        let rest = String(code[start.lowerBound...])
        // The next declaration at column zero ends the class. Comments are already gone, so
        // the boundary has to be code.
        let boundaries = ["\nprivate struct ", "\nstruct ", "\nfinal class ", "\n@MainActor",
                          "\nprivate enum ", "\nenum ", "\nextension "]
        let end = boundaries.compactMap { rest.range(of: $0) }.map(\.lowerBound).min()
        return end.map { String(rest[..<$0]) } ?? rest
    }

    /// THE RE-ATTACH IS GONE. Held here as well as in the app-hosted lane because this is the
    /// cheap, exact form: the app-hosted scenario counts BYTES ON THE WIRE, which is the claim
    /// that matters; this names the line, which is what makes the failure actionable.
    func testTheBringOverDoesNotReOpenTheSessionToReReadTheShelf() throws {
        let code = AppSourceTree.code(of: try source())
        XCTAssertFalse(
            code.contains("self.run(hardwareToken: hardwareToken, advertisedName: advertisedName)"),
            """
            `bringOver` still re-runs the whole check when it finishes: a second attach, a \
            second key handshake and a second LIST_DIRS, to learn one fact this phone's own \
            disk already knew. Custody is the authority; ask it.
            """)
        // EXISTENCE OVER THE SAME POPULATION: `run` is still there and the page still calls
        // it. A `bringOver` that stopped re-attaching because the check was deleted would
        // pass the prohibition and lose the feature.
        // NAMED WITHOUT ITS PARAMETER LIST. Pinning the full signature made this existence
        // assertion red every time the check gained an argument — it gained `library:`,
        // `stages:` and `brain:` on the way here — for a reason that had nothing to do with
        // the check having been deleted, which is the only thing it exists to notice.
        XCTAssertTrue(code.contains("func run(hardwareToken: String, advertisedName: String"),
                      "the check itself is gone")
        XCTAssertTrue(code.contains("check.run(hardwareToken: input.identity.hardwareToken,"),
                      "nothing on the page starts a check any more")
        XCTAssertTrue(code.contains("check.bringOver(hardwareToken: input.identity.hardwareToken,"),
                      "nothing on the page starts a bring-over any more")
    }

    /// THE COMMAND PATH IS ISSUED FROM THE PAGE, not merely available to it. `DoorLog.command`
    /// having tests of its own proves the primitive; this proves the caller.
    func testTheRecorderPageIssuesTheThreeErrandCommands() throws {
        let code = AppSourceTree.code(of: try source())
        for command in ["PocketErrandCommand.start",
                        "PocketErrandCommand.stop",
                        "PocketErrandCommand.custodyCommit"] {
            XCTAssertTrue(code.contains(command),
                          "\(Self.path) never issues \(command), so an errand that failed "
                          + "slowly leaves nothing findable behind it")
        }
    }
}
