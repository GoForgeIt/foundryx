import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PocketBLEProtocolClientTests: XCTestCase {
    func testPocketProtocolScenarios() async throws {
        let world = PocketWorld()
        let result = try await BrineFeatureRunner.run("pocket-ble-protocol-client", registry: StepRegistry(PocketSteps.make(world: world)))
        XCTAssertEqual(result.passed, 14)
    }
}

private final class PocketWorld: @unchecked Sendable {
    var action: (@Sendable () async throws -> PocketChecks)?
    var checks: PocketChecks?
    func set(_ body: @escaping @Sendable () async throws -> PocketChecks) { action = body }
    func act() async throws { checks = try await action?() }
    func verify() { checks?.verify() }
}

private final class PocketChecks: @unchecked Sendable {
    private var values: [() -> Void] = []
    func equal<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) { values.append { XCTAssertEqual(actual, expected, file: file, line: line) } }
    func isTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) { values.append { XCTAssertTrue(actual, file: file, line: line) } }
    func isFalse(_ actual: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { values.append { XCTAssertFalse(actual, message, file: file, line: line) } }
    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { values.append { XCTFail(message, file: file, line: line) } }
    func verify() { values.forEach { $0() } }
}

private enum PocketSteps {
    static let secret = "A!b2-C_d.E?9+x=Z"
    static func make(world: PocketWorld) -> [StepDefinition] {
        let cases: [(String, @Sendable () async throws -> PocketChecks)] = [
            ("a connected fake transport with the complete primary map", primaryAuthentication),
            ("connected fake transports with a complete fallback map and a partial map", mapSelection),
            ("an authenticated fake transport that returns the proposal live unknown-command capture", unknownIsUnsupported),
            ("connected fake transports for malformed, rejected, timed-out, and disconnected authentication", authenticationFailures),
            ("a connected fake transport and an injected diagnostic sink", secretPrivacy),
            ("authenticated fake transports with valid, zero, missing, malformed, unsupported, timed-out, and disconnected information traces", information),
            ("authenticated fake transports with provenance-labelled empty, repeated, malformed, incomplete, unsupported, and timed-out date traces", dateLists),
            ("authenticated fake transports with complete, malformed, count-mismatched, timed-out, and disconnected reference-derived file traces", fileLists),
            ("authenticated fake transports with successful, zero-size, stalled, sync-missing, malformed, timed-out, and disconnected download traces", downloads),
            ("an authenticated fake transport with a suspended operation", busy),
            ("an authenticated fake transport with an operation that is cancelled or times out", generationIsolation),
            ("an authenticated fake transport with an active operation", disconnect),
            ("a partial download followed by a newly authenticated transport generation", retry),
            ("silent fake transports for authentication, information, listing, and download", bounded)
        ]
        var steps = cases.map { phrase, action in defineStep(phrase) { context, _, _ in world.set(action); return context } }
        let whens = ["I authenticate with a valid synthetic session secret using a proposal live capture", "I probe and authenticate both transports", "I request device information", "I try each session secret and then request protected operations", "I authenticate with a valid synthetic secret containing punctuation and invalidate the session", "I request battery, firmware, storage, and state", "I list recording dates", "I list recordings for a device-reported date", "I download a recording by its device request tuple", "I start a second public operation", "late frames arrive and I attempt another operation", "the transport disconnects", "I retry the same recording", "each operation reaches its configured deadline"]
        steps += whens.map { phrase in defineStep(phrase) { context, _, _ in try await world.act(); return context } }
        let thens = ["authentication succeeds and a subsequent information command is permitted", "the reference-derived fallback succeeds and the partial map is unsupported", "the operation fails as unsupported rather than succeeding with empty data", "none authenticates and no protected command is issued", "the secret appears in no public result, error description, or diagnostic event and is cleared", "each field reports its traced value or specific unavailable condition without invention", "completed sequences preserve order and repeats while every incomplete sequence fails", "only complete ordered date, timestamp, size, and calculated duration results succeed", "only the trace crossing its announced size returns bytes beginning at the first MP3 sync marker", "it fails immediately as busy without issuing its command and the first alone consumes frames", "the generation is retired, authentication is invalidated, and late frames cannot complete later work", "the operation fails as disconnected and protected commands require reconnect and reauthentication", "only retry bytes are returned and no resume, delete, or modify command is emitted", "each finishes with its operation-specific timeout or stall failure without hardware time"]
        steps += thens.map { phrase in defineCheck(phrase) { _, _, _ in world.verify() } }
        return steps
    }

    static func client(_ actions: [PocketFakeTransport.Action], map: Set<String> = PocketCharacteristicMap.primary.required) async throws -> (PocketBLEClient, PocketFakeTransport) {
        let transport = PocketFakeTransport(characteristics: map, actions: actions)
        return (try await PocketBLEClient.connect(transport: transport), transport)
    }
    static func authenticated(_ actions: [PocketFakeTransport.Action]) async throws -> (PocketBLEClient, PocketFakeTransport) {
        let pair = try await client([.control("MCU&SK&OK")] + actions); try await pair.0.authenticate(secret: secret); return pair
    }
    static func expectError<T>(_ expected: PocketProtocolError, _ checks: PocketChecks, _ body: () async throws -> T) async {
        do { _ = try await body(); checks.fail("expected \(expected)") } catch let error as PocketProtocolError { checks.equal(error, expected) } catch { checks.fail("unexpected error \(error)") }
    }

    static func primaryAuthentication() async throws -> PocketChecks { let c = PocketChecks(); let (client, t) = try await self.client([.control("MCU&SK&OK"), .control("MCU&BAT&0")]); try await client.authenticate(secret: secret); c.equal(try await client.batteryLevel(), 0); c.equal(await t.writes.first?.characteristic, PocketCharacteristicMap.primary.command); return c }
    static func mapSelection() async throws -> PocketChecks { let c = PocketChecks(); let fallback = try await client([.control("MCU&SK&OK")], map: PocketCharacteristicMap.fallback.required); try await fallback.0.authenticate(secret: secret); c.equal(await fallback.0.characteristicMap, .fallback); await expectError(.unsupportedProtocol, c) { try await PocketBLEClient.connect(transport: PocketFakeTransport(characteristics: [PocketCharacteristicMap.fallback.command], actions: [])) }; return c }
    static func unknownIsUnsupported() async throws -> PocketChecks { let c = PocketChecks(); let p = try await authenticated([.control("MCU&UNKNOWN")]); await expectError(.unsupportedOperation, c) { try await p.0.batteryLevel() }; return c }
    static func authenticationFailures() async throws -> PocketChecks { let c = PocketChecks(); let malformed = try await client([]); for candidate in [nil, "short", "abcdefghijklmnopé"] as [String?] { await expectError(.malformedSecret, c) { try await malformed.0.authenticate(secret: candidate) } }; let rejected = try await client([.control("MCU&SK&NO")]); await expectError(.authenticationRejected, c) { try await rejected.0.authenticate(secret: secret) }; let timed = try await client([.timeout]); await expectError(.timeout(.authentication), c) { try await timed.0.authenticate(secret: secret) }; let disconnected = try await client([.disconnect]); await expectError(.disconnected, c) { try await disconnected.0.authenticate(secret: secret) }; for pair in [malformed, rejected, timed, disconnected] { let before = await pair.1.writes.count; await expectError(.unauthenticated, c) { try await pair.0.listDates() }; c.equal(await pair.1.writes.count, before) }; return c }
    static func secretPrivacy() async throws -> PocketChecks { let c = PocketChecks(); let sink = PocketEventRecorder(); let t = PocketFakeTransport(characteristics: PocketCharacteristicMap.primary.required, actions: [.control("MCU&SK&OK")]); let client = try await PocketBLEClient.connect(transport: t, diagnostics: { await sink.record($0) }); try await client.authenticate(secret: secret); await client.close(); c.isFalse(await sink.events.joined().contains(secret)); c.isFalse(String(describing: PocketProtocolError.authenticationRejected).contains(secret)); c.isFalse(await client.hasRetainedSecretForTesting, "the client is still holding the plaintext secret bytes after the session closed. `retainedSecret = nil` alone is not a wipe: it releases the live buffer to the allocator untouched, and `if var bytes = retainedSecret { bytes.resetBytes(...) }` zeroes a copy-on-write DUPLICATE rather than that buffer"); return c }
    static func information() async throws -> PocketChecks { let c = PocketChecks(); let good = try await authenticated([.control("MCU&BAT&0"), .control("MCU&FW&1.6"), .control("MCU&SPA&0&61032"), .control("MCU&STE&0")]); let info = await good.0.deviceInfo(); c.equal(info.battery, .value(0)); c.equal(info.firmware, .value("1.6")); c.equal(info.storage, .value(.init(usedKilobytes: 0, capacityKilobytes: 61_032))); c.equal(info.state, .value(0)); let bad = try await authenticated([.control("MCU&BAT&x"), .control("MCU&UNKNOWN"), .timeout, .disconnect]); let unavailable = await bad.0.deviceInfo(); c.equal(unavailable.battery, .failure(.malformedResponse)); c.equal(unavailable.firmware, .failure(.unsupportedOperation)); c.equal(unavailable.storage, .failure(.timeout(.information))); c.equal(unavailable.state, .failure(.unauthenticated)); let d = try await authenticated([.disconnect]); await expectError(.disconnected, c) { try await d.0.deviceState() }; return c }
    static func dateLists() async throws -> PocketChecks { let c = PocketChecks(); let empty = try await authenticated([.control("MCU&DIRS_SUM&000")]); c.equal(try await empty.0.listDates(), []); let repeated = try await authenticated([.control("MCU&DIRS&2026-03-26"), .control("MCU&DIRS&2026-03-27"), .control("MCU&DIRS&2026-03-26"), .control("MCU&DIRS_SUM&003")]); c.equal(try await repeated.0.listDates(), ["2026-03-26", "2026-03-27", "2026-03-26"]); for actions: [PocketFakeTransport.Action] in [[.control("bad")], [.control("MCU&DIRS&2026-03-26"), .timeout], [.control("MCU&UNKNOWN")]] { let p = try await authenticated(actions); do { _ = try await p.0.listDates(); c.fail("expected list failure") } catch {} }; return c }
    static func fileLists() async throws -> PocketChecks { let c = PocketChecks(); let p = try await authenticated([.control("MCU&F&2026-03-28&20260328001919&4000"), .control("MCU&F&2026-03-28&20260328191640&8000"), .control("MCU&LIST&002")]); let files = try await p.0.listRecordings(on: "2026-03-28"); c.equal(files.map(\.durationSeconds), [1, 2]); c.equal(files.map(\.sizeBytes), [4000, 8000]); for actions: [PocketFakeTransport.Action] in [[.control("MCU&F&bad")], [.control("MCU&F&2026-03-28&t&4000"), .control("MCU&LIST&002")], [.timeout], [.disconnect]] { let bad = try await authenticated(actions); do { _ = try await bad.0.listRecordings(on: "2026-03-28"); c.fail("expected file-list failure") } catch {} }; return c }
    static func downloads() async throws -> PocketChecks { let c = PocketChecks(); let good = try await authenticated([.control("MCU&U&6"), .audio(Data([0,1,0xff])), .audio(Data([0xf3,0x48,0xc4,9]))]); c.equal(try await good.0.download(.init(date: "2026-03-28", timestamp: "t")), Data([0xff,0xf3,0x48,0xc4,9])); for actions: [PocketFakeTransport.Action] in [[.control("MCU&U&0")], [.control("MCU&U&8"), .audio(Data([0xff,0xf3])), .stall], [.control("MCU&U&2"), .audio(Data([1,2]))], [.control("MCU&U&x")], [.timeout], [.disconnect]] { let bad = try await authenticated(actions); do { _ = try await bad.0.download(.init(date: "d", timestamp: "t")); c.fail("expected download failure") } catch {} }; return c }
    static func busy() async throws -> PocketChecks { let c = PocketChecks(); let (client, t) = try await authenticated([.suspend, .control("MCU&BAT&5")]); let first = Task { try await client.batteryLevel() }; try await t.waitUntilSuspended(); await expectError(.busy, c) { try await client.firmwareVersion() }; c.isFalse(await t.writes.contains { $0.data == Data("APP&FW".utf8) }); await t.resume(); c.equal(try await first.value, 5); return c }
    static func generationIsolation() async throws -> PocketChecks { let c = PocketChecks(); let (client, t) = try await authenticated([.suspend]); let task = Task { try await client.batteryLevel() }; try await t.waitUntilSuspended(); task.cancel(); await t.emitLate(.control(Data("MCU&BAT&99".utf8), generation: 1)); await t.resume(); await expectError(.cancelled, c) { try await task.value }; c.equal(await client.generationForTesting, 2); await expectError(.unauthenticated, c) { try await client.batteryLevel() }; c.isTrue(await t.isClosed); c.equal(await t.deliveredLateEvents, 1); return c }
    static func disconnect() async throws -> PocketChecks { let c = PocketChecks(); let (client, t) = try await authenticated([.disconnect]); await expectError(.disconnected, c) { try await client.listDates() }; let count = await t.writes.count; await expectError(.unauthenticated, c) { try await client.download(.init(date: "d", timestamp: "t")) }; c.equal(await t.writes.count, count); return c }
    static func retry() async throws -> PocketChecks { let c = PocketChecks(); let first = try await authenticated([.control("MCU&U&8"), .audio(Data([0xff,0xf3,1])), .stall]); do { _ = try await first.0.download(.init(date: "d", timestamp: "t")) } catch {}; let retry = try await authenticated([.control("MCU&U&4"), .audio(Data([0xff,0xf3,7,8]))]); c.equal(try await retry.0.download(.init(date: "d", timestamp: "t")), Data([0xff,0xf3,7,8])); let commands = await (first.1.writes + retry.1.writes).compactMap { String(data: $0.data, encoding: .ascii) }; c.isFalse(commands.contains { $0.contains("OFFSET") || $0.contains("DELETE") || $0.contains("MODIFY") }); return c }
    static func bounded() async throws -> PocketChecks { let c = PocketChecks(); let auth = try await client([.timeout]); await expectError(.timeout(.authentication), c) { try await auth.0.authenticate(secret: secret) }; for operation in [PocketOperation.information, .dateList, .fileList, .download] { let p = try await authenticated([operation == .download ? .stall : .timeout]); switch operation { case .information: await expectError(.timeout(.information), c) { try await p.0.batteryLevel() }; case .dateList: await expectError(.timeout(.dateList), c) { try await p.0.listDates() }; case .fileList: await expectError(.timeout(.fileList), c) { try await p.0.listRecordings(on: "d") }; case .download: await expectError(.stall, c) { try await p.0.download(.init(date: "d", timestamp: "t")) }; default: break } }; return c }
}

private actor PocketEventRecorder { var events: [String] = []; func record(_ event: String) { events.append(event) } }
private actor PocketFakeTransport: PocketBLETransport {
    enum Action: Sendable { case control(String), audio(Data), timeout, stall, disconnect, suspend }
    let characteristics: Set<String>; let constructedGeneration: UInt64; var actions: [Action]; var lateEvents: [PocketTransportEvent] = []; var writes: [(characteristic: String, data: Data)] = []; var isClosed = false; var deliveredLateEvents = 0; private var suspension: CheckedContinuation<Void, Never>?
    init(characteristics: Set<String>, actions: [Action], generation: UInt64 = 1) { self.characteristics = characteristics; self.actions = actions; constructedGeneration = generation }
    func availableCharacteristics() async throws -> Set<String> { characteristics }
    func write(_ data: Data, to characteristic: String) async throws { writes.append((characteristic, data)) }
    func nextEvent(generation _: UInt64) async throws -> PocketTransportEvent {
        if !lateEvents.isEmpty { deliveredLateEvents += 1; return lateEvents.removeFirst() }
        guard !actions.isEmpty else { throw PocketTransportFailure.timeout }; let action = actions.removeFirst()
        switch action { case .control(let value): return .control(Data(value.utf8), generation: constructedGeneration); case .audio(let value): return .audio(value, generation: constructedGeneration); case .timeout: throw PocketTransportFailure.timeout; case .stall: throw PocketTransportFailure.stall; case .disconnect: throw PocketTransportFailure.disconnected; case .suspend: await withCheckedContinuation { suspension = $0 }; return try await nextEvent(generation: constructedGeneration) }
    }
    func resume() { suspension?.resume(); suspension = nil }
    /// Parks the caller until `.suspend` has actually CAPTURED a continuation — the
    /// operation under test is provably in flight. The scenarios that need this used
    /// a single `Task.yield()` and hoped the spawned task had reached the transport;
    /// on a loaded box it often had not, so the follow-up operation consumed
    /// `.suspend` itself and parked with its `resume()` unreachable behind it —
    /// CI's 86-minute silent sim hang on 2026-08-13. Bounded, so a scenario that can
    /// never suspend fails in seconds with a name rather than by job timeout.
    func waitUntilSuspended() async throws {
        var remaining = 500
        while suspension == nil, remaining > 0 { remaining -= 1; try await Task.sleep(nanoseconds: 10_000_000) }
        guard suspension != nil else { throw PocketTransportFailure.stall }
    }
    func emitLate(_ event: PocketTransportEvent) { lateEvents.append(event) }
    func close() async { isClosed = true; suspension?.resume(); suspension = nil }
}
