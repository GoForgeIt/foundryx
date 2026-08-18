// A TEST RUN DOES NOT SHIP INTO THE PRODUCTION DIAGNOSTIC LOG.
//
// WHAT WAS MEASURED, 2026-08-18. 385 `cmd errand.*` lines arrived at the LIVE relay's
// /diag/log carrying `build=1 install=1a255475 device=arm64 battery=-1` and uploading to
// `http://127.0.0.1:1/foundryx/capture` — the app-hosted scenario suite, on a simulator,
// posting its own errands into the one instrument this project diagnoses the recorder with.
// The lines are well-formed and carry the real vocabulary, so they are not noise a reader
// filters out: the main loop nearly read those errands as Nick's own.
//
// WHY THESE TESTS ARE SHAPED THIS WAY. "Nothing shipped" is exactly the assertion that passes
// when the code path never ran at all — the gate-that-cannot-fail this project has been bitten
// by eight times. So the refusal is COUNTED: `withheld` going up is proof the sender reached
// the choke point and was turned back, and `shipped` staying flat is the fix. Both are
// asserted, always as a delta, and the pure decision is asserted in BOTH directions because a
// guard that also refuses on a real handset would blind the instrument it is protecting.
//
// THE MUTATIONS THESE ANSWER TO:
//   * delete the `guard !underTest` in `FoundryXDiagShipping.send` and every behavioural test
//     here goes red (shipped +1, withheld +0);
//   * make `looksLikeATestProcess` return `true` unconditionally and
//     `testAHandsetIsNotMistakenForATestRun` goes red;
//   * put `URLSession.shared.dataTask` back in any of the three senders and the source gate
//     names the file.

import XCTest
import Foundation
@testable import FoundryXKit

final class ATestRunDoesNotShipIntoTheProductionLogTests: XCTestCase {

    /// A loopback discard port. Nothing here may reach a network even if the guard fails —
    /// but the guard failing is still a RED, which is the point.
    private static let sink = URL(string: "http://127.0.0.1:9/diag/log")!

    // MARK: - The decision, in both directions

    /// THE RUNTIME FACT. Whatever the lane — `swift test` hostless, the iOS simulator runtime,
    /// or a test bundle injected into the shipping app — this process must know it is a test.
    func testThisProcessIsRecognisedAsATestRun() {
        XCTAssertTrue(FoundryXDiagShipping.underTest,
                      "this test process is not recognised as one, so every diagnostic line it "
                          + "writes would be posted to the production relay — which is exactly "
                          + "the 385 errand lines measured on 2026-08-18")
    }

    /// THE HALF THAT MATTERS MOST. A guard that cannot say "this is a real handset" silences
    /// the only instrument this project has for the recorder.
    func testAHandsetIsNotMistakenForATestRun() {
        XCTAssertFalse(
            FoundryXDiagShipping.looksLikeATestProcess(
                environment: ["HOME": "/var/mobile", "TMPDIR": "/private/var/tmp"],
                linkedTestFramework: false,
                executablePath: "/private/var/containers/Bundle/Application/ABC/FoundryX.app/FoundryX"),
            "a shipping app on a handset is being read as a test process, so nothing it logs "
                + "would ever reach the relay")
    }

    /// The app-hosted lane: the executable IS the shipping app and argv says nothing, so the
    /// signal is the injected framework.
    func testAnInjectedTestBundleIsRecognised() {
        XCTAssertTrue(
            FoundryXDiagShipping.looksLikeATestProcess(
                environment: [:],
                linkedTestFramework: true,
                executablePath: "/Users/x/Library/Developer/CoreSimulator/Devices/A/FoundryX.app/FoundryX"))
    }

    /// The same lane, seen from the environment instead — xcodebuild sets these for every
    /// bundle it runs, including one whose host has not loaded XCTest yet.
    func testAnXCTestEnvironmentIsRecognised() {
        for key in FoundryXDiagShipping.testEnvironmentKeys {
            XCTAssertTrue(
                FoundryXDiagShipping.looksLikeATestProcess(
                    environment: [key: "/tmp/whatever"],
                    linkedTestFramework: false,
                    executablePath: "/Applications/FoundryX.app/FoundryX"),
                "\(key) present is a test host, and it was not recognised")
        }
    }

    /// The hostless swiftpm runner, recognised from argv alone.
    func testThePackageTestRunnerIsRecognised() {
        XCTAssertTrue(
            FoundryXDiagShipping.looksLikeATestProcess(
                environment: [:],
                linkedTestFramework: false,
                executablePath: ".build/debug/FoundryXPackageTests.xctest/Contents/MacOS/FoundryXPackageTests"))
        XCTAssertTrue(
            FoundryXDiagShipping.looksLikeATestProcess(
                environment: [:], linkedTestFramework: false,
                executablePath: "/usr/bin/xctest"))
    }

    // MARK: - The device log: recorded here, withheld from the relay

    /// THE ONE THAT MATTERS. A sinked `DoorLog` writing an errand command — the exact line
    /// class that polluted the relay — must reach the choke point and be turned back.
    func testAnErrandCommandIsWithheldRatherThanPosted() {
        let log = DoorLog()
        log.setRemoteSink(Self.sink)
        defer { log.setRemoteSink(nil) }

        let before = (shipped: FoundryXDiagShipping.shipped,
                      withheld: FoundryXDiagShipping.withheld)
        log.command(PocketErrandCommand.start, subject: PocketErrandCommand.bringOverSubject)
        // `.error` flushes immediately rather than on the 1.5s debounce, so this is synchronous
        // on the main thread and the counts below are about THIS batch.
        log.error("a recorder errand failed")

        let after = (shipped: FoundryXDiagShipping.shipped,
                     withheld: FoundryXDiagShipping.withheld)
        XCTAssertEqual(after.shipped - before.shipped, 0,
                       "a test run POSTed a diagnostic batch to \(Self.sink). That is the 385 "
                           + "errand lines: convincing, well-formed noise in the one instrument "
                           + "this project depends on")
        XCTAssertGreaterThanOrEqual(after.withheld - before.withheld, 1,
                                    "no batch was withheld either — so this test proves nothing "
                                        + "about the guard, it proves the flush never ran")
    }

    /// INERT IS NOT SILENT. The lines must still be in the ring buffer, or the suites that
    /// assert on `entries` and the `Copy logs` button lose what they are about.
    func testTheWithheldLinesAreStillRecordedInProcess() {
        let log = DoorLog()
        log.setRemoteSink(Self.sink)
        defer { log.setRemoteSink(nil) }

        log.command(PocketErrandCommand.stop,
                    subject: PocketErrandCommand.shelfSubject,
                    outcome: DoorLog.succeeded)
        log.error("a recorder errand failed")

        XCTAssertTrue(log.dump().contains("cmd errand.stop subject=shelf outcome=ok"),
                      "withholding the network leg also lost the in-process record")
        XCTAssertEqual(log.commands(named: PocketErrandCommand.stop).count, 1)
    }

    /// The record of an irreversible act is kept locally and does not leave a test process.
    func testADeletionRecordIsKeptLocallyAndNotPosted() {
        let recorder = DeletionRecorder(endpoint: Self.sink)
        let before = (shipped: FoundryXDiagShipping.shipped,
                      withheld: FoundryXDiagShipping.withheld)

        recorder.emit("delete.attempt", "scope=test")

        let after = (shipped: FoundryXDiagShipping.shipped,
                     withheld: FoundryXDiagShipping.withheld)
        XCTAssertEqual(after.shipped - before.shipped, 0,
                       "a test run POSTed a deletion record to the production sink")
        XCTAssertEqual(after.withheld - before.withheld, 1,
                       "the POST path never ran, so this test is vacuous")
        XCTAssertEqual(recorder.recorded(), ["delete.attempt scope=test"],
                       "the local record is what a deletion dispute is answered from and it "
                           + "must survive the network leg being withheld")
    }

    // MARK: - One choke point, and it stays that way

    /// EVERY DIAGNOSTIC SENDER GOES THROUGH THE ONE PLACE THAT CAN REFUSE.
    ///
    /// A rule stated in four files is a rule that holds in three of them after the next edit.
    ///
    /// THE LIST IS FOUR NOW, AND THAT IS THE POINT. This gate was written over a hardcoded
    /// three and its own comment said it was "the gate that catches the fourth sender" — which
    /// it could not, because it iterates a list somebody has to remember to add to. The fourth
    /// sender was already in the tree when that was written: `PerfSink`
    /// (`Sources/FoundryXKit/PerfTelemetry.swift`) POSTs perf lines to the SAME
    /// `gatewayHTTPURL/diag/log`, wired in `App/FoundryXApp.swift`'s `init` — which runs inside
    /// the app-hosted scenario bundle exactly as it runs on a phone. `cmd errand.*` stopped
    /// shipping from the simulator suite and `perf …` did not. The population is DERIVED
    /// below; this list is only what the derivation must not shrink to.
    func testEveryDiagnosticSenderRoutesThroughTheChokePoint() throws {
        let senders = ["DoorLog.swift", "DeletionRecorder.swift", "RemoteSession.swift",
                       "PerfTelemetry.swift"]
        for name in senders {
            let path = AppSourceTree.repoRoot
                .appendingPathComponent("Sources/FoundryXKit/\(name)")
            let raw = try String(contentsOf: path, encoding: .utf8)
            // Non-vacuity: this gate is about files that ship diagnostics. If one stops
            // mentioning the endpoint at all, the gate is checking the wrong file.
            XCTAssertTrue(raw.contains("diag/log"),
                          "\(name) no longer mentions /diag/log — this gate is holding a file "
                              + "that is not a diagnostic sender any more")
            let code = AppSourceTree.code(of: raw)
            XCTAssertTrue(code.contains("FoundryXDiagShipping.send("),
                          "\(name) ships diagnostics without going through the one place that "
                              + "can refuse to, so a test run posts through it")
            XCTAssertFalse(code.contains("dataTask("),
                           "\(name) reaches the network directly, bypassing the choke point")
            XCTAssertFalse(code.contains("URLSession.shared.data("),
                           "\(name) reaches the network directly, bypassing the choke point")
        }
    }

    /// THE GATE THAT CAN ACTUALLY CATCH THE NEXT SENDER, because its population is READ OFF
    /// THE TREE rather than typed above.
    ///
    /// Every file in the kit that reaches `URLSession` at all must be one of exactly three
    /// things: the choke point itself, a NAMED non-diagnostic client, or a diagnostic sender
    /// that goes through the choke point. A new file that POSTs anywhere fails here until
    /// somebody says which of the three it is — which is the check that was missing when
    /// `PerfSink` sat outside the guard while a gate one screen up claimed to cover it.
    ///
    /// THE EXCEPTIONS ARE NAMED AND THEIR JUSTIFICATION IS ASSERTED, not asserted by being on
    /// a list: each must NOT mention the diagnostics endpoint. An allowlist entry that quietly
    /// became a diagnostic sender is the same defect wearing the exception's clothes.
    ///
    /// ITS LIMIT, STATED RATHER THAN IMPLIED. It watches the FIRE-AND-FORGET shapes —
    /// `dataTask(…)`, `URLSession.shared.data(…)`, `upload(…)` — which is what every diagnostic
    /// sender in this kit is, because a diagnostic that blocked on its own answer would be a
    /// diagnostic that changed the thing it measures. It deliberately does NOT watch
    /// `session.data(for:)`, which has twenty-three call sites here and is the ordinary shape
    /// of an API client (`DoorClient`, `AccountClient`, `UsageSink`'s bearer-gated door
    /// wire). Covering those would need an allowlist longer than the population it guards, and
    /// a fifteen-name allowlist is a registry that rots, not a gate. A diagnostic sender that
    /// awaits its own POST would slip past this and is the case to add a check for, in the
    /// shape of whatever it turns out to be.
    func testNothingInTheKitReachesTheNetworkOutsideTheChokePoint() throws {
        /// Clients of the ACCOUNT and HOST-REGISTRY APIs. They are request/response calls whose
        /// answers the app cannot work without — nothing about them is a diagnostic, and
        /// withholding them under test would break the suites that drive them.
        let nonDiagnosticClients = ["FoundryAuth.swift", "HostResolver.swift"]

        let kit = AppSourceTree.repoRoot
            .appendingPathComponent("Sources/FoundryXKit", isDirectory: true)
        let files = try FileManager.default
            .contentsOfDirectory(at: kit, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThan(files.count, 50,
                             "the kit was not enumerated, so this gate is about nothing")

        var reachTheNetwork: [String] = []
        for file in files {
            let code = AppSourceTree.code(of: try String(contentsOf: file, encoding: .utf8))
            guard code.contains("dataTask(") || code.contains("URLSession.shared.data(")
                    || code.contains(".upload(for:") || code.contains("URLSession.shared.upload(")
            else { continue }
            reachTheNetwork.append(file.lastPathComponent)
        }
        // Non-vacuity: the choke point itself must be in the population, or the scan found
        // nothing and every claim below is about an empty set.
        XCTAssertTrue(reachTheNetwork.contains("FoundryXDiagShipping.swift"),
                      "the scan did not even find the choke point, so it found nothing: "
                          + "\(reachTheNetwork)")

        let unexplained = reachTheNetwork.filter {
            $0 != "FoundryXDiagShipping.swift" && !nonDiagnosticClients.contains($0)
        }
        XCTAssertEqual(unexplained, [],
                       "these kit files reach the network without going through the one place "
                           + "that can refuse a diagnostic batch, and without being a named "
                           + "non-diagnostic client: \(unexplained). A diagnostic sender here "
                           + "ships the test suite's own lines into the production relay")

        for name in nonDiagnosticClients {
            let raw = try String(
                contentsOf: kit.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(raw.contains("diag/log"),
                           "\(name) is exempted from the choke point as a non-diagnostic "
                               + "client, and it now names the diagnostics endpoint")
        }
    }

    /// THE FOURTH SENDER, BEHAVIOURALLY. `perf …` lines carry the same `build=` / `install=`
    /// identity `cmd errand.*` lines do and go to the same endpoint, so a suite that stopped
    /// shipping one and went on shipping the other has not stopped polluting the instrument.
    func testAPerfLineIsWithheldRatherThanPosted() {
        let sink = PerfSink(endpoint: Self.sink,
                            ctx: PerfContext(build: "1", installId: "1a255475"))
        let before = (shipped: FoundryXDiagShipping.shipped,
                      withheld: FoundryXDiagShipping.withheld)

        sink.emit("perf build=1 dev=1a255475 span=cold-launch ms=820", flush: true)

        let after = (shipped: FoundryXDiagShipping.shipped,
                     withheld: FoundryXDiagShipping.withheld)
        XCTAssertEqual(after.shipped - before.shipped, 0,
                       "a test run POSTed a perf batch to \(Self.sink). `App/FoundryXApp.swift` "
                           + "wires this endpoint from the same RemoteConfig DoorLog uses, and "
                           + "its init runs inside the app-hosted scenario bundle")
        XCTAssertEqual(after.withheld - before.withheld, 1,
                       "no batch was withheld either — the flush never ran, so this test proves "
                           + "nothing about the guard")
    }

    /// AND A HANDSET STILL SHIPS ITS PERF LINES. The refusal is about the harness, never about
    /// the endpoint: `PerfSink` is how a cold-launch regression is seen across the fleet.
    func testAPerfSinkWithNoEndpointDoesNotReachTheChokePointAtAll() {
        let sink = PerfSink(endpoint: nil,
                            ctx: PerfContext(build: "1", installId: "1a255475"))
        let before = FoundryXDiagShipping.withheld

        sink.emit("perf build=1 dev=1a255475 span=cold-launch ms=820", flush: true)

        XCTAssertEqual(FoundryXDiagShipping.withheld - before, 0,
                       "a sink with nowhere to send built a request anyway")
    }
}
