import XCTest
import Foundation
import CryptoKit
import BrineSwiftCore
import FoundryXKit

/// **The client half of P1** — `features/the-phone-refuses-a-host-it-cannot-pin.feature`.
///
/// ## Why this lives in the NON-hermetic target
///
/// `Tests/FoundryXBrineTests/BrineFeatureRunner.swift` declares itself a "hermetic
/// runner (no real network, no real hardware; every seam is injected)". The observable
/// here is what the SHIPPED `HostResolver` does with a REAL gateway answer that arrives
/// over a REAL socket through a REAL `URLSession` — the defect was a coercion on the
/// decode path, and a decode driven from an injected dictionary would step over it.
/// So the drive belongs in the target that is allowed a real server, next to
/// `GatewayFixture`, which is the same fixture P1 itself drives.
///
/// This feature needs NO relay: the refusal must happen at RESOLVE, before a socket is
/// ever opened to a door. That is the point — a host that cannot be pinned produces no
/// `RelayConfig`, so there is no connect left to fail open. P1 (which does need the
/// blind tunnel relay) then observes the same fix from the far end of the dial.
///
/// ## What each scenario would catch
///
/// - the outline is the refusal enumeration: nine ways an answer fails to carry a door
///   key, each one a separate row, so a fix that closes only the absent case is red on
///   the other eight;
/// - the positive control (a real door key resolves AND pins those exact bytes) is the
///   non-vacuity half: a resolver that refused everything would satisfy the outline;
/// - "the door key is not an optional" is the structural half, read off the REAL type
///   at run time via `Mirror`, not off the source text. Re-introducing `Data?` reddens
///   it even if every behavioural scenario still passes, because an optional pin is a
///   pin whose absence has a spelling at the two dial sites.
final class MandatoryDoorPinTests: XCTestCase {

    func testThePhoneRefusesAHostItCannotPin() async throws {
        let w = PinWorld()
        defer { w.teardown() }
        try await ConformanceFeatureDriver.run("the-phone-refuses-a-host-it-cannot-pin",
                                               registry: StepRegistry(MandatoryDoorPinSteps.make(world: w)),
                                               expectedScenarios: 12)
    }
}

/// One scenario's state. Held in a class for the same reason `ConformanceWorld` is:
/// the steps mutate across `Given`/`When`/`Then` and the checks must read the run that
/// actually happened.
final class PinWorld: @unchecked Sendable {
    var gateway: GatewayFixture?
    /// The key the gateway was told to name, when the case names a real one.
    var namedDoorKey: Data?
    var resolved: RelayConfig?
    var thrown: Error?

    func requireGateway() throws -> GatewayFixture {
        guard let g = gateway else { throw ConformanceStepError("no gateway was started") }
        return g
    }

    func teardown() {
        gateway?.stop()
        gateway = nil
    }
}

enum MandatoryDoorPinSteps {

    /// A REAL X25519 public key, generated per scenario. A literal would be a
    /// well-formed string that no door ever held; this is the same shape the door
    /// actually registers under.
    static func realDoorKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// The pin the client ended up with, read off the REAL `RelayConfig` through
    /// `Mirror` so this file compiles — and means the same thing — whether the field is
    /// `Data` or `Data?`. That matters: the RED of this feature has to be observed
    /// against the optional-pin baseline, and a `guard let` here would simply stop
    /// compiling once the field is made non-optional.
    static func pinChild(_ cfg: RelayConfig) -> Mirror.Child? {
        Mirror(reflecting: cfg).children.first { $0.label == "expectedDoorStatic" }
    }

    static func pinBytes(_ cfg: RelayConfig) -> Data? {
        guard let c = pinChild(cfg) else { return nil }
        return c.value as? Data
    }

    /// The gateway body for each named malformation. The names are the feature's words;
    /// the JSON is this file's business.
    static func body(forMachineIdNamed name: String, tunnelId: String, world w: PinWorld) throws -> String {
        let head = #""tunnel_id":"\#(tunnelId)","label":"conformance-host""#
        switch name {
        case "a real door key":
            let key = realDoorKey()
            w.namedDoorKey = key
            return "{\(head),\"machine_id\":\"\(hex(key))\"}"
        case "absent":
            return "{\(head)}"
        case "the empty string":
            return "{\(head),\"machine_id\":\"\"}"
        case "not hexadecimal":
            // 64 characters, none of them hex digits.
            return "{\(head),\"machine_id\":\"\(String(repeating: "zq", count: 32))\"}"
        case "62 hex characters":
            return "{\(head),\"machine_id\":\"\(hex(realDoorKey()).prefix(62))\"}"
        case "63 hex characters":
            return "{\(head),\"machine_id\":\"\(hex(realDoorKey()).prefix(63))\"}"
        case "65 hex characters":
            return "{\(head),\"machine_id\":\"\(hex(realDoorKey()))a\"}"
        case "a JSON number":
            return "{\(head),\"machine_id\":12345}"
        case "JSON null":
            return "{\(head),\"machine_id\":null}"
        case "uppercase hex":
            // A DIFFERENT SPELLING OF A KEY IS A DIFFERENT ID, and the registry treats
            // it as one (`machine_id_from_static_key` emits lowercase). Normalising it
            // here would widen the pin to accept an id the registry never issued, so
            // the client refuses the spelling rather than repairing it.
            return "{\(head),\"machine_id\":\"\(hex(realDoorKey()).uppercased())\"}"
        default:
            throw ConformanceStepError("the feature names a machine id \"\(name)\" that this step does not know how to serve")
        }
    }

    static func make(world w: PinWorld) -> [StepDefinition] {
        [
            defineStep("a gateway answering the phone's host lookup") { ctx, _, _ in
                // Started lazily by the machine-id step, which is the one that knows the
                // body. Recorded here so a scenario that never names one is loud.
                w.namedDoorKey = nil
                w.resolved = nil
                w.thrown = nil
                return ctx
            },

            defineStep("the gateway names a host whose machine id is {string}") { ctx, p, _ in
                let name = try p.requireString(0)
                let tunnelId = "pin-\(UInt32.random(in: 0..<UInt32.max))"
                let g = GatewayFixture(body: try body(forMachineIdNamed: name, tunnelId: tunnelId, world: w))
                try g.start()
                w.gateway?.stop()
                w.gateway = g
                return ctx
            },

            defineStep("the phone resolves its host") { ctx, _, _ in
                let g = try w.requireGateway()
                let remote = RemoteConfig(gatewayHTTPURL: g.baseURL,
                                          relayWSURL: URL(string: "ws://127.0.0.1:1")!)
                do {
                    w.resolved = try await HostResolver(remote: remote)
                        .resolveRelayConfig(idToken: "conformance-fixture-token")
                } catch {
                    w.thrown = error
                }
                return ctx
            },

            // ------------------------------------------------------------- the positive control
            defineCheck("the phone gets a relay configuration") { _, _, _ in
                if let e = w.thrown {
                    throw ConformanceStepError("the phone refused a host it CAN pin: \(e). A resolver that refuses everything would satisfy every refusal scenario in this feature, so this is the control that keeps them meaning something.")
                }
                guard w.resolved != nil else {
                    throw ConformanceStepError("no relay configuration and no error — the resolve did not happen")
                }
            },
            defineCheck("the configuration pins exactly the door key the gateway named") { _, _, _ in
                guard let cfg = w.resolved else { throw ConformanceStepError("no relay configuration was produced") }
                guard let named = w.namedDoorKey else { throw ConformanceStepError("this scenario named no door key, so there is nothing to compare the pin against") }
                guard let pin = pinBytes(cfg) else {
                    throw ConformanceStepError("the configuration carries NO pin at all — this is the fail-open: the phone would dial and complete a channel against any door parked on that tunnel")
                }
                guard pin == named else {
                    throw ConformanceStepError("the configuration pins \(hex(pin)), and the gateway named \(hex(named))")
                }
            },
            defineCheck("the pin is 32 bytes") { _, _, _ in
                guard let cfg = w.resolved, let pin = pinBytes(cfg) else {
                    throw ConformanceStepError("the configuration carries no pin, so it cannot be an X25519 public key")
                }
                guard pin.count == 32 else {
                    throw ConformanceStepError("the pin is \(pin.count) bytes; an X25519 static public key is 32")
                }
            },
            defineCheck("the interactive channel carries the same pin") { _, _, _ in
                guard let cfg = w.resolved else { throw ConformanceStepError("no relay configuration was produced") }
                guard let base = pinBytes(cfg), let chat = pinBytes(cfg.interactive()) else {
                    throw ConformanceStepError("a channel carries no pin, so the two cannot be compared")
                }
                guard base == chat else {
                    throw ConformanceStepError("the chat channel pins \(hex(chat)) and the base channel pins \(hex(base)); both splice to the same door and both must pin it")
                }
            },

            // ------------------------------------------------------------- the refusals
            defineCheck("the phone refuses the host") { _, _, _ in
                if let cfg = w.resolved {
                    let pin = pinBytes(cfg).map { "a pin of \($0.count) bytes" } ?? "NO PIN"
                    throw ConformanceStepError("the phone COMPLETED the resolve and built a relay configuration carrying \(pin). An answer that cannot be turned into a door key must produce no configuration at all — otherwise the connect proceeds unpinned, which is the fail-open P1 records.")
                }
                guard w.thrown != nil else {
                    throw ConformanceStepError("the resolve neither produced a configuration nor threw — nothing was driven")
                }
            },
            defineCheck("the phone gets no relay configuration") { _, _, _ in
                guard w.resolved == nil else {
                    throw ConformanceStepError("a relay configuration survived the refusal; a refusal that still hands back something to dial is not a refusal")
                }
            },
            defineCheck("the gateway was actually asked") { _, _, _ in
                let g = try w.requireGateway()
                guard g.requestsServed >= 1 else {
                    throw ConformanceStepError("the gateway fixture served no /host/resolve request — the refusal came from somewhere other than the answer under test, so it proves nothing")
                }
            },
            defineCheck("the refusal tells the person their host could not be verified") { _, _, _ in
                guard let e = w.thrown else { throw ConformanceStepError("nothing was thrown") }
                let text = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                guard text.lowercased().contains("could not be verified") else {
                    throw ConformanceStepError("the refusal reads \"\(text)\", which does not tell the person that the machine's identity could not be verified")
                }
            },
            defineCheck("the refusal is not the no-host-designated refusal") { _, _, _ in
                guard let e = w.thrown else { throw ConformanceStepError("nothing was thrown") }
                if let h = e as? HostResolveError, case .noHostDesignated = h {
                    throw ConformanceStepError("the phone reported that no host is designated. A host IS designated; it is the ANSWER that is unusable, and reporting it as \"no host yet\" would send the person to press \"Make this machine the host\" on a machine that already is one.")
                }
            },

            // ------------------------------------------------------------- the structural half
            defineCheck("the relay configuration's door key is not an optional") { _, _, _ in
                guard let cfg = w.resolved else {
                    throw ConformanceStepError("no relay configuration was produced, so its type could not be read")
                }
                guard let child = pinChild(cfg) else {
                    throw ConformanceStepError("RelayConfig declares no `expectedDoorStatic`; if the pin was renamed, this check moved off its subject and must be moved back")
                }
                if Mirror(reflecting: child.value).displayStyle == .optional {
                    throw ConformanceStepError("`RelayConfig.expectedDoorStatic` is \(type(of: child.value)) — an OPTIONAL. While it is optional, `nil` has a spelling at both dial sites (`RelayTransport.roundTrip`, `NoiseRelayChannel.connect`), each of which reads it with `if let` and simply skips the pin. The type is the guard: with a non-optional there is no unpinned dial to write.")
                }
            },
        ]
    }
}
