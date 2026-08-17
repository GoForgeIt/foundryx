import XCTest
@testable import FoundryXKit

/// THE TWO DEFECTS THAT WOULD HAVE KILLED FAST SYNC FOR THE WRONG REASON.
///
/// These drive the SHIPPED `PocketBLEClient` — the real authenticated session, the real command
/// serialisation — over a scripted recorder whose access point behaves the way the legend in
/// `PROTOCOL.md:139-143` says a real one does: `WIFIO` puts it at `3` ("AP created, waiting for
/// client connection") and it STAYS there until something actually joins.
///
/// On `main`, with the choreography in one `prepare()` function, this is what the recorder saw:
///
///     ["SK&…", "BAT", "FW", "U&WIFI", "WIFI", "WIFIO", "WIFIS", "WIFIS", "WIFIS"]
///     -> threw malformed response, 0.2 seconds after the access point came up
///
/// Three polls, no delay, and no phone had been told to join — because the join happened after
/// `prepare()` returned. pocket-libre allows ninety seconds for the same wait
/// (`src/pocket_libre/cli.py:1035`). Both clients were ordered to deadlock.
final class PocketFastSyncControlOrderingTests: XCTestCase {

    private static let secret = "PD9QQDJ6KM3PJDFC"
    private static let day = "2026-08-07"
    private static let stamp = "20260807142852"

    private func stage() async throws -> (FakePocketBLEStack, RecordingDeviceAttachment, UUID) {
        let identifier = UUID()
        let stack = FakePocketBLEStack(deviceId: identifier,
                                       deviceName: "PKT01_BLUE_26079bc5",
                                       acceptedSecret: Self.secret,
                                       inventory: [.init(date: Self.day,
                                                         timestamp: Self.stamp,
                                                         sizeBytes: 4_096,
                                                         content: Data([0xff, 0xf3, 1, 2]))])
        let secrets = InMemoryPocketSecretStore()
        try await secrets.save(Self.secret,
                               for: try PocketAuthenticatedIdentity(
                                    peripheralIdentifier: identifier.uuidString))
        return (stack,
                RecordingDeviceAttachment(makeCentral: stack.factory,
                                          secrets: secrets,
                                          recovery: nil,
                                          deadlines: .init(powerOn: 5, connect: 5,
                                                           discovery: 5, control: 5)),
                identifier)
    }

    /// THE ORDERING, AND THE BUDGET, IN ONE RUN. The phone joins half a second after the access
    /// point appears — far faster than a real WPA association — and the recorder is then given
    /// time to notice.
    func testTheRecorderIsGivenTimeToNoticeAPhoneThatJoinsAfterTheAccessPointIsUp() async throws {
        let (stack, attachment, identifier) = try await stage()
        let started = Date()
        let joining = Task {
            for _ in 0..<400 {
                if stack.accessPointStatus == 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    stack.clientJoinedTheAccessPoint()
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { joining.cancel() }

        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: identifier, advertisedName: stack.deviceName
        ) { client, _ -> String in
            do {
                try await client.openAccessPoint()
                try await client.awaitClientJoined(withinSeconds: 20)
                try await client.beginTransfer(.init(date: Self.day, timestamp: Self.stamp))
                await client.cleanup()
                return "served"
            } catch {
                return "threw \(error)"
            }
        }
        guard case .ran(let outcome) = result else { return XCTFail("no session: \(result)") }
        XCTAssertEqual(outcome, "served", """
        The recorder never got as far as serving a file. It answered `MCU&WIFIS&3` — waiting \
        for a client — and this client gave up before the phone that was joining got there. \
        Commands: \(stack.commandsWritten)
        """)
        // IT WAITED THROUGH REAL TIME. The phone joined half a second after the access point
        // came up, and the old shape's entire readiness window — three polls, no delay — was
        // measured at 0.2 s. Asking N times is the mechanism; outlasting the join is the fact.
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 0.5,
                             "the whole run took \(elapsed)s, which is less than the join it "
                                 + "is supposed to have waited for")
        let polls = stack.commandsWritten.filter { $0 == "WIFIS" }.count
        XCTAssertGreaterThan(polls, 1,
                             "the recorder was asked \(polls) time(s): it was never re-asked "
                                 + "after answering `3`, so nothing could ever change its mind")
        // AND THE ACCESS POINT IS DOWN AFTERWARDS. Verified on hardware: WIFIC returns it to 0.
        XCTAssertEqual(stack.accessPointStatus, 0,
                       "the recorder was left with its access point up")
        XCTAssertEqual(stack.accessPointCloseCount, 1)
    }

    /// A RECORDER THAT NEVER SEES A CLIENT GIVES UP ON THE BUDGET, NOT ON A COUNT — and it
    /// gives up SAYING SO. Nothing joins here, so the access point stays at `3` forever.
    func testARecorderNoPhoneJoinsGivesUpOnTheBudget() async throws {
        let (stack, attachment, identifier) = try await stage()
        let started = Date()
        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: identifier, advertisedName: stack.deviceName
        ) { client, _ -> String in
            do {
                try await client.openAccessPoint()
                try await client.awaitClientJoined(withinSeconds: 3)
                return "served"
            } catch {
                await client.cleanup()
                return "gave up"
            }
        }
        guard case .ran(let outcome) = result else { return XCTFail("no session: \(result)") }
        XCTAssertEqual(outcome, "gave up")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 3,
                             "it gave up after \(elapsed)s against a 3s budget, which means the "
                                 + "budget is not what it is waiting on")
        XCTAssertEqual(stack.accessPointStatus, 0,
                       "a recorder nobody joined was left with its access point up — on "
                           + "somebody's desk, out of sight, until its battery goes")
    }

    /// THE DEFAULT IS THE REFERENCE CLIENT'S, and it is stated once. A budget that shipped as
    /// three seconds because a test wanted to be quick is the same defect wearing a number.
    func testTheDefaultBudgetIsTheOneTheReferenceClientAllows() {
        XCTAssertEqual(PocketFastSyncCoordinator.readinessBudgetSeconds, 90,
                       "pocket-libre allows 90s (cli.py:1035, wifi_wait_ready(timeout=90.0))")
    }

    /// EXACTLY ONE PRODUCTION CONFORMER, so the register's `undetermined` on
    /// `pocket-ble-fast-sync-control` has an answer rather than an excuse: with one conformer
    /// in the shipping tree and a production line that binds a `PocketBLEClient` into the
    /// existential, there is nothing else the dispatch could reach.
    func testExactlyOneShippingTypeConformsToTheControlProtocol() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        var conformers: [String] = []
        for directory in ["Sources", "App", "Widget"] {
            let base = root.appendingPathComponent(directory)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for line in text.components(separatedBy: "\n")
                where line.contains(": PocketFastSyncControlling")
                    && (line.contains("extension ") || line.contains("struct ")
                        || line.contains("final class ") || line.contains("actor ")) {
                    conformers.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        XCTAssertEqual(conformers.count, 1,
                       "the shipping tree has \(conformers.count) conformers of "
                           + "PocketFastSyncControlling: \(conformers). The reachability "
                           + "register's verdict on the conformance rests on there being one.")
        XCTAssertTrue(conformers.first?.contains("PocketBLEClient") == true,
                      "the one conformer is not PocketBLEClient: \(conformers)")
    }
}
