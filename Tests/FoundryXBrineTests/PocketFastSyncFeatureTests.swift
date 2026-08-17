import XCTest
import BrineSwiftCore
@testable import FoundryXKit

/// THE HANDOFF, DRIVEN THROUGH THE SHIPPED COORDINATOR.
///
/// Everything below is the production `PocketFastSyncCoordinator`. What is faked is what a
/// hermetic run cannot own: a recorder's radio, a WiFi association, and an HTTP server on an
/// address nobody has confirmed exists.
///
/// THE FIXTURE'S CREDENTIALS ARE THE MEASURED ONES. Session key `PD9QQDJ6KM3PJDFC`, reported
/// access-point password `PD9QQDJ8` — taken off Nick's own recorder on 2026-08-16, disagreeing
/// in the eighth character, which is exactly the pair that made the old possession gate refuse
/// its own owner. A fixture that agreed in all eight would have gone on passing forever.
final class PocketFastSyncFeatureTests: XCTestCase {
    func testPocketFastSyncFeature() async throws {
        let world = PocketFastWorld()
        let result = try await BrineFeatureRunner.run("pocket-fast-sync", registry: .init(PocketFastSteps.make(world)))
        XCTAssertEqual(result.passed, 14)
    }
}

private enum PocketFastSteps {
    static func make(_ world: PocketFastWorld) -> [StepDefinition] {
        let givens = ["all Pocket WiFi evidence gates are absent",
          "an authenticated Pocket identity and a recorder reporting its own network password",
          "a recorder reporting the password measured on real hardware",
          "a recorder reporting a password from another owner's key",
          "a recorder that only says it is ready once a phone has joined",
          "a recorder that never says it is ready",
          "a recorder whose file endpoint answers nothing",
          "every line the Fast sync surface can render",
          "the Fast sync sheet is open", "a mismatched Pocket identity or recorder password",
          "the endpoint, stock-control, and iOS-AP evidence gates are absent", "production evidence gates and a complete selected-file response",
          "a backlog of 23 files with 9 durably imported", "active Fast sync attempts that complete, pause, cancel, fail, and retry"]
        let whens = ["Pocket setup and device Settings are presented", "I select Join and fast sync once", "I keep using Bluetooth",
          "I select Join and fast sync", "Fast sync runs the typed authenticated control and HTTP boundaries",
          "Fast sync progress is presented without measured rate evidence", "each attempt exits",
          "the lines are read"]
        let thens = ["both entry points show Fast sync and state that the phone leaves its normal network",
          "the join receives the network and the password the recorder reported, without showing or logging either secret",
          "the recorder is recognised as ours and the join uses what it reported",
          "no network join occurs and the attempt names the credential as the reason",
          "the phone joined before the recorder was asked whether it was ready",
          "the recorder was allowed at least ninety seconds to become ready",
          "the attempt finishes with a named reason and the recorder is put back on Bluetooth",
          "nothing is kept, the attempt finishes with a named reason, and the recorder is put back on Bluetooth",
          "there is at least one, and none of them names a speed, a multiple, or how long it will take",
          "no network join occurs and the internet-loss warning was already visible",
          "no WiFi command, network join, HTTP request, or durable handoff occurs",
          "Fast sync remains visible and finishes with a named unavailable gap",
          "exactly one verified completed payload reaches Pocket durable sync",
          "it shows 9 of 23 with Over, Now, and Waiting and no speed or ETA claim",
          "cleanup is attempted, partial bytes never complete, no file is deleted, and no live capture path is reached"]
        return givens.map { p in defineStep(p) { c,_,_ in await world.given(p); return c } }
          + whens.map { p in defineStep(p) { c,_,_ in await world.when(p); return c } }
          + thens.map { p in defineCheck(p) { _,_,_ in try await world.then(p) } }
    }
}

/// THE MEASURED PAIR, USED AS THE FIXTURE EVERYWHERE.
private enum Measured {
    static let ssid = "PKT01_BLUE_26079bc5"
    static let sessionKey = "PD9QQDJ6KM3PJDFC"
    static let reportedPassword = "PD9QQDJ8"       // NOT sessionKey.prefix(8) — hardware said so
    static let anotherOwnersPassword = "Aa1Bb2Cc"
}

/// The order things happened in, shared by the fakes, because ORDER is the fact three of these
/// scenarios are about and no single fake can see it.
private actor PhaseLog {
    private var phases: [String] = []
    func record(_ phase: String) { phases.append(phase) }
    func all() -> [String] { phases }
    func clear() { phases = [] }
}

private actor PocketFastWorld {
    let log = PhaseLog()
    lazy var joiner = FastJoiner(log: log)
    let http = FastHTTP(), handoff = FastHandoff()
    lazy var control = FastControl(log: log)
    let liveBoundaries = StoredFileLiveBoundarySpy()
    var givenPhrase = ""; var outcome: PocketFastSyncOutcome?; var progress: PocketFastSyncProgress?
    var entryPresentations: [PocketFastSyncPresentation] = []
    var lines: [String] = []

    func given(_ phrase: String) async {
        givenPhrase = phrase; outcome = nil; progress = nil; lines = []
        await joiner.clear(); await http.clear(); await handoff.clear(); await control.clear()
        await log.clear()
        switch phrase {
        case "a recorder reporting a password from another owner's key":
            await control.reports(password: Measured.anotherOwnersPassword)
        case "a recorder that never says it is ready":
            await control.neverBecomesReady()
        case "a recorder whose file endpoint answers nothing":
            await http.answersNothing()
        default: break
        }
    }

    func when(_ phrase: String) async {
        let coordinator = PocketFastSyncCoordinator(joiner: joiner, http: http,
                                                    handoff: handoff, control: control)
        switch phrase {
        case "Pocket setup and device Settings are presented": entryPresentations = [.setup, .settings]
        case "the lines are read": lines = PocketFastSyncPresentation.everyLine
        case "I keep using Bluetooth": outcome = await coordinator.keepUsingBluetooth()
        case "I select Join and fast sync once":
            outcome = await coordinator.run(identityMatches: true, sessionKey: Measured.sessionKey,
                                            evidence: good)
        case "I select Join and fast sync":
            if givenPhrase.contains("mismatched") {
                await control.reports(password: Measured.anotherOwnersPassword)
                outcome = await coordinator.run(identityMatches: false,
                                                sessionKey: Measured.sessionKey, evidence: good)
            } else if givenPhrase.contains("evidence gates are absent") {
                outcome = await coordinator.run(identityMatches: true,
                                                sessionKey: Measured.sessionKey, evidence: .init())
            } else {
                outcome = await coordinator.run(identityMatches: true,
                                                sessionKey: Measured.sessionKey, evidence: good)
            }
        case "Fast sync runs the typed authenticated control and HTTP boundaries":
            outcome = await coordinator.run(identityMatches: true, sessionKey: Measured.sessionKey,
                                            evidence: good)
        case "Fast sync progress is presented without measured rate evidence":
            progress = .init(completed: 9, total: 23, measuredRate: false, measuredClaim: "1 MB/s")
        case "each attempt exits":
            for attempt in 0..<5 {
                if attempt == 1 { await http.failNextPull() }
                outcome = await coordinator.run(identityMatches: true,
                                                sessionKey: Measured.sessionKey, evidence: good)
            }
            StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: liveBoundaries)
        default: break
        }
    }

    var good: PocketFastSyncEvidence {
        .init(stockControlTrace: true, closureSafety: true,
              endpoint: URL(string: "http://192.0.2.1/evidenced")!,
              endpointHardwareProvenance: true, iOSAccessPointJoin: true)
    }

    func then(_ phrase: String) async throws {
        switch phrase {
        case "both entry points show Fast sync and state that the phone leaves its normal network":
            XCTAssertEqual(entryPresentations.first?.title, "FAST SYNC")
            XCTAssertTrue(entryPresentations.last?.body.contains("leaves its normal network") == true)

        case "the join receives the network and the password the recorder reported, without showing or logging either secret":
            let points = await joiner.points()
            XCTAssertEqual(points, [.init(ssid: Measured.ssid, password: Measured.reportedPassword)])
            for line in PocketFastSyncPresentation.everyLine {
                XCTAssertFalse(line.contains(Measured.reportedPassword), "a line renders the password")
                XCTAssertFalse(line.contains(Measured.sessionKey), "a line renders the session key")
            }
            XCTAssertEqual(outcome, .completed)

        case "the recorder is recognised as ours and the join uses what it reported":
            let points = await joiner.points()
            XCTAssertEqual(outcome, .completed, """
            The recorder reported `\(Measured.reportedPassword)` while holding \
            `\(Measured.sessionKey)` and this app refused it. Deriving the password from the key \
            gives `\(String(Measured.sessionKey.prefix(8)))`, which is not what the hardware says.
            """)
            XCTAssertEqual(points.first?.password, Measured.reportedPassword)
            XCTAssertNotEqual(points.first?.password, String(Measured.sessionKey.prefix(8)))

        case "no network join occurs and the attempt names the credential as the reason":
            let points = await joiner.points()
            XCTAssertEqual(outcome, .failed(.credentialMismatch))
            XCTAssertEqual(points.count, 0)
            XCTAssertEqual(PocketFastSyncPresentation.message(for: outcome ?? .keptBluetooth),
                           PocketFastSyncPresentation.notThisRecorderLine)

        case "the phone joined before the recorder was asked whether it was ready":
            let phases = await log.all()
            guard let join = phases.firstIndex(of: "join"),
                  let ready = phases.firstIndex(of: "awaitReady") else {
                return XCTFail("the run did not both join and wait: \(phases)")
            }
            XCTAssertLessThan(join, ready, """
            The phone joined at step \(join) and the recorder was asked whether it was ready at \
            step \(ready). Status 1 means "ready for file transfer" and the recorder only \
            reaches it AFTER a client joins (PROTOCOL.md:139-143), so this order cannot \
            terminate. Phases: \(phases)
            """)
            XCTAssertEqual(phases.first, "readCredentials",
                           "something reached the radio before the recorder had been recognised")

        case "the recorder was allowed at least ninety seconds to become ready":
            let budget = await control.budgetOffered()
            XCTAssertNotNil(budget, "the recorder was never asked to become ready at all")
            XCTAssertGreaterThanOrEqual(budget ?? 0, 90, """
            The recorder was given \(budget ?? 0)s to notice a phone had joined it. \
            pocket-libre allows 90 (cli.py:1035); this client used to allow three round trips, \
            which measured 0.2s.
            """)

        case "the attempt finishes with a named reason and the recorder is put back on Bluetooth":
            let cleanups = await control.cleanupCount()
            XCTAssertEqual(outcome, .failed(.recorderNeverReady))
            XCTAssertEqual(cleanups, 1)
            XCTAssertEqual(PocketFastSyncPresentation.message(for: outcome ?? .keptBluetooth),
                           PocketFastSyncPresentation.neverReadyLine)

        case "nothing is kept, the attempt finishes with a named reason, and the recorder is put back on Bluetooth":
            let kept = await handoff.payloads()
            let cleanupsAfterSilence = await control.cleanupCount()
            XCTAssertEqual(outcome, .failed(.httpFailed))
            XCTAssertEqual(kept.count, 0)
            XCTAssertEqual(cleanupsAfterSilence, 1)
            XCTAssertEqual(PocketFastSyncPresentation.message(for: outcome ?? .keptBluetooth),
                           PocketFastSyncPresentation.transferFailedLine)

        case "there is at least one, and none of them names a speed, a multiple, or how long it will take":
            // PAIRED EXISTENCE FIRST: a ban over an empty population is a test that cannot fail.
            XCTAssertGreaterThanOrEqual(lines.count, 14)
            XCTAssertTrue(lines.allSatisfy { !$0.isEmpty })
            for line in lines {
                XCTAssertFalse(line.contains(where: \.isNumber), """
                "\(line)" renders a number. No WiFi throughput has ever been measured off a \
                Pocket by anyone — the ~150x figure is arithmetic over a source-flagged GUESS — \
                so a number on this surface is a promise nobody can keep.
                """)
                for unit in ["MB/s", "KB/s", "×", "x faster", "per second", "minute", "hour",
                             "seconds", "ETA"] {
                    XCTAssertFalse(line.localizedCaseInsensitiveContains(unit),
                                   "\"\(line)\" names \(unit)")
                }
            }

        case "no network join occurs and the internet-loss warning was already visible":
            let points = await joiner.points()
            XCTAssertEqual(points.count, 0); XCTAssertEqual(outcome, .keptBluetooth)
            XCTAssertTrue(PocketFastSyncPresentation.sheetWarning.contains("Internet may be unavailable"))

        case "no WiFi command, network join, HTTP request, or durable handoff occurs":
            let points = await joiner.points(), urls = await http.urls(), payloads = await handoff.payloads()
            let phases = await log.all()
            XCTAssertEqual(outcome, .failed(.identityMismatch))
            XCTAssertEqual(phases, [], "the radio was reached before identity was settled")
            XCTAssertEqual(points.count, 0); XCTAssertEqual(urls.count, 0); XCTAssertEqual(payloads.count, 0)

        case "Fast sync remains visible and finishes with a named unavailable gap":
            XCTAssertEqual(PocketFastSyncPresentation.setup.primaryAction, "Turn on Fast sync")
            XCTAssertEqual(outcome, .unavailable(.closureSafety))

        case "exactly one verified completed payload reaches Pocket durable sync":
            let payloads = await handoff.payloads()
            XCTAssertEqual(outcome, .completed); XCTAssertEqual(payloads, [Data([0xff,0xf3,1,2])])

        case "it shows 9 of 23 with Over, Now, and Waiting and no speed or ETA claim":
            XCTAssertEqual(progress?.count, "9 of 23")
            XCTAssertEqual(progress?.states, ["Over","Now","Waiting"])
            XCTAssertNil(progress?.quantitativeClaim)

        case "cleanup is attempted, partial bytes never complete, no file is deleted, and no live capture path is reached":
            let cleaned = await control.cleanupCount()
            let completedPayloads = await handoff.payloads()
            let live = liveBoundaries.counts
            XCTAssertEqual(cleaned, 5)
            XCTAssertEqual(completedPayloads.count, 4)
            XCTAssertEqual(PocketRecorderCustodyPromise.automaticDeleteCommands, 0)
            XCTAssertEqual(live.storedFileLifecycleEvents, 5)
            XCTAssertEqual(live.activeSourceSelections + live.frameRouterStarts + live.walWrites + live.liveActivities + live.liveStateMutations, 0)

        default: XCTFail("Unhandled Then: \(phrase)")
        }
    }
}

private actor FastJoiner: PocketSoftAPJoining {
    private let log: PhaseLog
    var values: [PocketAccessPoint] = []
    init(log: PhaseLog) { self.log = log }
    func join(_ p: PocketAccessPoint) async throws { await log.record("join"); values.append(p) }
    func points() -> [PocketAccessPoint] { values }
    func clear() { values = [] }
}

private actor FastHTTP: PocketHTTPPulling {
    var values: [URL] = []; var fails = false; var silent = false
    func pull(_ u: URL) throws -> Data {
        values.append(u)
        if silent { throw PocketFastSyncGap.httpFailed }   // the endpoint nobody has confirmed
        if fails { fails = false; throw PocketFastSyncGap.httpFailed }
        return Data([0xff,0xf3,1,2])
    }
    func failNextPull() { fails = true }
    func answersNothing() { silent = true }
    func urls() -> [URL] { values }
    func clear() { values = []; fails = false; silent = false }
}

private actor FastHandoff: PocketFastSyncHandoff {
    var values: [Data] = []
    func accept(_ p: Data) throws {
        guard p.starts(with: [0xff,0xf3]) else { throw PocketFastSyncGap.validationFailed }
        values.append(p)
    }
    func payloads() -> [Data] { values }
    func clear() { values = [] }
}

/// A RECORDER THAT ANSWERS THE FOUR STEPS, RECORDING THE ORDER IT WAS ASKED IN.
private actor FastControl: PocketFastSyncControlling {
    private let log: PhaseLog
    private var password = Measured.reportedPassword
    private var ready = true
    private var budget: TimeInterval?
    var cleaned = 0
    init(log: PhaseLog) { self.log = log }

    func reportedAccessPoint() async throws -> PocketAccessPointReadback {
        await log.record("readCredentials")
        return PocketAccessPointReadback(ssid: Measured.ssid, fields: [Measured.ssid, password])
    }
    func openAccessPoint() async throws { await log.record("openAP") }
    func awaitClientJoined(withinSeconds seconds: TimeInterval) async throws {
        await log.record("awaitReady")
        budget = seconds
        // A RECORDER THAT NEVER SEES A CLIENT. The real client waits out the budget; this one
        // refuses immediately, because the wall-clock half is held against the shipped
        // `PocketBLEClient` in `PocketFastSyncControlOrderingTests`.
        guard ready else { throw PocketProtocolError.timeout(.wifiControl) }
    }
    func beginTransfer(_ request: PocketRecordingRequest) async throws { await log.record("beginTransfer") }
    func cleanup() async { await log.record("cleanup"); cleaned += 1 }

    func reports(password value: String) { password = value }
    func neverBecomesReady() { ready = false }
    func budgetOffered() -> TimeInterval? { budget }
    func cleanupCount() -> Int { cleaned }
    func clear() { cleaned = 0; password = Measured.reportedPassword; ready = true; budget = nil }
}
