import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Brine driver for `features/device-agnostic-source.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T1).
///
/// Everything here drives the REAL `RecordingSourceCatalog` and the REAL
/// `RecordingDeviceReconnectPolicy`; only the OBSERVATIONS are injected, because a radio
/// is the one thing a hermetic suite cannot own. No vendor name appears in any production
/// decision under test — the scenarios exist to prove that.
final class DeviceAgnosticSourceFeatureTests: XCTestCase {

    func testDeviceAgnosticSourceFeature() async throws {
        let world = DeviceAgnosticSourceWorld()
        // L3: pin the POPULATION. BrineFeatureRunner asserts only that nothing failed;
        // deleting a scenario (or an Examples row) would otherwise leave this suite green.
        let result = try await BrineFeatureRunner.run(
            "device-agnostic-source",
            registry: StepRegistry(DeviceAgnosticSourceSteps.make(world: world)))
        XCTAssertEqual(result.passed, 9,
                       "device-agnostic-source must run all 9 scenarios (6 plain + 3 outline rows)")
    }

    // MARK: unit — the same rule, proved by substitution rather than by inspection

    /// Eligibility must be a function of the DECLARED AUDIO FORMAT alone. The strongest
    /// available statement of that is behavioural: hold the format fixed and vary the
    /// shape, the name, and the hardware token across their whole cross-product; the
    /// verdict may not move.
    func testEligibilityIsInvariantUnderShapeAndName() {
        /// `expected` pins what the rule must SAY, so "invariant" can never be satisfied by
        /// a rule that answers the same thing to everything.
        let formats: [(profile: RecordingDeviceAudioProfile?, expected: Bool)] = [
            (RecordingDeviceAudioProfile(codec: "opus", sampleRateHz: 48_000, channels: 1, frameMilliseconds: 20), true),
            (RecordingDeviceAudioProfile(codec: "pcm16", sampleRateHz: 16_000, channels: 1, frameMilliseconds: 20), true),
            (RecordingDeviceAudioProfile(codec: "vendor-secret", sampleRateHz: 48_000, channels: 1, frameMilliseconds: 20), false),
            (RecordingDeviceAudioProfile(codec: "opus", sampleRateHz: 4_000, channels: 1, frameMilliseconds: 20), false),
            (RecordingDeviceAudioProfile(codec: "opus", sampleRateHz: 48_000, channels: 0, frameMilliseconds: 20), false),
            (nil, false),
        ]
        // The rule must actually discriminate — otherwise every invariance claim below is
        // vacuous.
        XCTAssertEqual(Set(formats.map(\.expected)).count, 2, "the fixture itself is degenerate")

        let names = ["Omi", "omi wearable", "Trail Mic", "Field Recorder", ""]
        for (format, expected) in formats {
            let verdicts = RecordingDeviceShape.allCases.flatMap { shape in
                names.map { name in
                    RecordingSourceCatalog.evaluate(RecordingDeviceObservation(
                        identity: RecordingDeviceIdentity(shape: shape, hardwareToken: "token-\(name)"),
                        reportedName: name,
                        audioProfile: format)).eligibility
                }
            }
            XCTAssertEqual(Set(verdicts.map { $0.isEligible }).count, 1,
                           "eligibility moved with shape/name for format \(String(describing: format)): \(verdicts)")
            XCTAssertEqual(verdicts.first?.isEligible, expected,
                           "the rule gave the wrong verdict for \(String(describing: format))")
        }
    }

    /// The device-agnostic reconnect decision must be the SAME decision the shipped BLE
    /// policy already makes, over the whole input cross-product — otherwise T4's
    /// disconnect → reconnect chain would silently change behaviour.
    func testReconnectDecisionMatchesTheShippedBlePolicy() {
        for armed in [true, false] {
            let agnostic = RecordingDeviceReconnectPolicy.onLinkLoss(cause: .system, armed: armed)
            let shipped = OmiReconnectPolicy.onDisconnect(autoConnect: armed)
            switch (agnostic, shipped) {
            case (.reissuePendingConnect, .reissuePendingConnect), (.stayDetached, .stayDown):
                continue
            default:
                XCTFail("armed=\(armed): device-agnostic \(agnostic) disagrees with shipped \(shipped)")
            }
        }
        // A user detach never re-arms, however armed the transport thinks it is.
        for armed in [true, false] {
            XCTAssertEqual(RecordingDeviceReconnectPolicy.onLinkLoss(cause: .userDetach, armed: armed),
                           .stayDetached)
        }
    }
}

// MARK: - World

final class DeviceAgnosticSourceWorld: @unchecked Sendable {
    var observations: [RecordingDeviceObservation] = []
    var merged: [RecordingDeviceEntry] = []
    var previousMerged: [RecordingDeviceEntry] = []
    /// Eligibility recorded by the substitution steps, so a later step can compare.
    var recordedEligibility: RecordingDeviceEligibility?
    var reconnectDecision: RecordingDeviceReconnectDecision?
    var armed: [RecordingDeviceShape: Bool] = [:]

    static let usable = RecordingDeviceAudioProfile(
        codec: "opus", sampleRateHz: 48_000, channels: 1, frameMilliseconds: 20)
    static let usableRoute = RecordingDeviceAudioProfile(
        codec: "pcm16", sampleRateHz: 16_000, channels: 1, frameMilliseconds: 20)

    func reset() {
        observations = []
        merged = []
        previousMerged = []
        recordedEligibility = nil
        reconnectDecision = nil
        armed = [:]
    }

    func add(shape: RecordingDeviceShape, name: String,
             profile: RecordingDeviceAudioProfile?,
             capabilities: [String: String?] = [:]) {
        observations.append(RecordingDeviceObservation(
            identity: RecordingDeviceIdentity(shape: shape, hardwareToken: "hw-\(name)"),
            reportedName: name,
            audioProfile: profile,
            declaredCapabilities: capabilities))
    }

    func entry(named name: String) throws -> RecordingDeviceEntry {
        guard let found = merged.first(where: { $0.displayName == name }) else {
            throw BrineStepError("no entry named \(name) in \(merged.map(\.displayName))")
        }
        return found
    }
}

enum DeviceAgnosticSourceSteps {

    static func shape(named label: String) throws -> RecordingDeviceShape {
        switch label {
        case "Bluetooth audio route", "audio route": return .audioRoute
        case "BLE stream", "non-Omi BLE stream", "Omi-shaped BLE stream": return .bleStream
        case "built-in microphone": return .builtInMic
        default: throw BrineStepError("unknown device shape label: \(label)")
        }
    }

    static func profile(named label: String) throws -> RecordingDeviceAudioProfile? {
        switch label {
        case "no audio format at all": return nil
        case "an unsupported codec":
            return RecordingDeviceAudioProfile(codec: "vendor-secret", sampleRateHz: 48_000,
                                               channels: 1, frameMilliseconds: 20)
        case "a 4000 Hz sample rate":
            return RecordingDeviceAudioProfile(codec: "opus", sampleRateHz: 4_000,
                                               channels: 1, frameMilliseconds: 20)
        default: throw BrineStepError("unknown audio format label: \(label)")
        }
    }

    /// Vendor words that must never appear in generic, device-independent copy.
    static let vendorWords = ["omi", "airpods", "apple", "bose", "sony", "samsung", "jabra"]

    static func make(world: DeviceAgnosticSourceWorld) -> [StepDefinition] {
        [
            defineStep("a Bluetooth audio-route device named {string} is discoverable") { ctx, p, _ in
                world.add(shape: .audioRoute, name: try p.requireString(0),
                          profile: DeviceAgnosticSourceWorld.usableRoute)
                return ctx
            },
            defineStep("a non-Omi BLE stream device named {string} is discoverable") { ctx, p, _ in
                world.add(shape: .bleStream, name: try p.requireString(0),
                          profile: DeviceAgnosticSourceWorld.usable)
                return ctx
            },
            defineStep("an Omi-shaped BLE stream device named {string} is discoverable") { ctx, p, _ in
                world.add(shape: .bleStream, name: try p.requireString(0),
                          profile: DeviceAgnosticSourceWorld.usable)
                return ctx
            },
            defineStep("an eligible device of every shape is discoverable") { ctx, _, _ in
                world.reset()
                world.add(shape: .audioRoute, name: "Field Recorder",
                          profile: DeviceAgnosticSourceWorld.usableRoute)
                world.add(shape: .bleStream, name: "Trail Mic",
                          profile: DeviceAgnosticSourceWorld.usable)
                world.add(shape: .builtInMic, name: "This iPhone",
                          profile: DeviceAgnosticSourceWorld.usableRoute)
                return ctx
            },
            defineStep("a {string} device named {string} declares {string}") { ctx, p, _ in
                world.add(shape: try shape(named: try p.requireString(0)),
                          name: try p.requireString(1),
                          profile: try profile(named: try p.requireString(2)))
                return ctx
            },
            defineStep("a device declaring a usable audio format is discoverable under every shape") { ctx, _, _ in
                world.reset()
                for shape in RecordingDeviceShape.allCases {
                    world.add(shape: shape, name: "Recorder \(shape.rawValue)",
                              profile: DeviceAgnosticSourceWorld.usable)
                }
                return ctx
            },
            defineStep("a discoverable device declares no firmware value and no gap recovery") { ctx, _, _ in
                world.reset()
                world.add(shape: .bleStream, name: "Quiet Recorder",
                          profile: DeviceAgnosticSourceWorld.usable,
                          capabilities: ["battery-level": "72"])
                return ctx
            },
            defineStep("a discoverable device declares a capability this build has never heard of") { ctx, _, _ in
                world.reset()
                world.add(shape: .bleStream, name: "Future Recorder",
                          profile: DeviceAgnosticSourceWorld.usable,
                          capabilities: ["haptic-cue-playback": "v3"])
                return ctx
            },
            defineStep("the source catalog merges what discovery found") { ctx, _, _ in
                world.merged = RecordingSourceCatalog.merge(world.observations)
                return ctx
            },
            defineStep("discovery reports the same devices in the opposite order") { ctx, _, _ in
                world.previousMerged = world.merged
                world.observations.reverse()
                world.merged = RecordingSourceCatalog.merge(world.observations)
                return ctx
            },
            defineCheck("the merged list is unchanged") { _, _, _ in
                // Two empty lists are trivially equal; an order-independence claim over an
                // empty list proves nothing at all.
                guard world.merged.count == world.observations.count,
                      world.observations.count >= 2 else {
                    throw BrineStepError(
                        "order-independence is vacuous: \(world.merged.count) entries from "
                            + "\(world.observations.count) observations")
                }
                guard world.merged == world.previousMerged else {
                    throw BrineStepError(
                        "merge depends on discovery order: \(world.previousMerged.map(\.displayName)) "
                            + "became \(world.merged.map(\.displayName))")
                }
            },
            defineCheck("the list contains {string}, {string} and {string}") { _, p, _ in
                let expected = [try p.requireString(0), try p.requireString(1), try p.requireString(2)]
                let names = world.merged.map(\.displayName)
                let missing = expected.filter { !names.contains($0) }
                guard missing.isEmpty else {
                    throw BrineStepError("merged list \(names) is missing \(missing)")
                }
                guard names.count == world.observations.count else {
                    throw BrineStepError(
                        "merged \(names.count) entries from \(world.observations.count) observations — "
                            + "the one list dropped a device")
                }
            },
            defineCheck("every entry carries its own shape, a stable identity, and an adapter") { _, _, _ in
                for entry in world.merged {
                    guard let observation = world.observations
                        .first(where: { $0.reportedName == entry.displayName }) else {
                        throw BrineStepError("entry \(entry.displayName) has no observation")
                    }
                    guard entry.shape == observation.identity.shape else {
                        throw BrineStepError("\(entry.displayName) reported shape \(entry.shape)")
                    }
                    guard entry.identity == observation.identity,
                          !entry.identity.storageKey.isEmpty,
                          entry.identity.storageKey == observation.identity.storageKey else {
                        throw BrineStepError("\(entry.displayName) has no stable identity")
                    }
                    guard entry.adapter == RecordingSourceCatalog.adapter(for: entry.shape) else {
                        throw BrineStepError("\(entry.displayName) carries adapter \(entry.adapter)")
                    }
                }
                // Two different shapes must not collapse onto one adapter by accident:
                // the mapping has to actually distinguish a streamed device from a routed one.
                guard RecordingSourceCatalog.adapter(for: .bleStream)
                        != RecordingSourceCatalog.adapter(for: .audioRoute) else {
                    throw BrineStepError("every shape maps to the same adapter")
                }
            },
            defineCheck("no entry is ranked ahead of another because of its vendor name") { _, _, _ in
                // FIRST VERSION OF THIS CHECK COULD NOT FAIL. It renamed the vendor device
                // and then compared the relative order of the OTHERS — which a vendor ladder
                // leaves untouched, since sorting one device to the front does not reorder
                // the rest. It passed against a deliberately reintroduced
                // `if name.contains("omi") { sort first }`. What follows can fail, and does.
                //
                // (1) A device's position is a function of its own NAME, computed here
                // independently of the catalog. A ladder keyed on any name substring, any
                // shape, or any discovery position breaks this immediately.
                let expected = world.merged
                    .sorted {
                        let left = $0.displayName.lowercased(), right = $1.displayName.lowercased()
                        if left != right { return left < right }
                        return $0.identity.storageKey < $1.identity.storageKey
                    }
                    .map(\.identity)
                guard world.merged.map(\.identity) == expected else {
                    throw BrineStepError(
                        "list order is not determined by the device's own name: "
                            + "\(world.merged.map(\.displayName)) is not the name order")
                }
                // (2) Renaming the vendor device must move it exactly as any other rename
                // would — the new sequence is again the plain name order of the new names.
                let renamed = world.observations.map { observation -> RecordingDeviceObservation in
                    guard vendorWords.contains(observation.reportedName.lowercased()) else { return observation }
                    return RecordingDeviceObservation(
                        identity: observation.identity,
                        reportedName: "Zebra Recorder",
                        audioProfile: observation.audioProfile,
                        declaredCapabilities: observation.declaredCapabilities)
                }
                guard renamed.contains(where: { $0.reportedName == "Zebra Recorder" }) else {
                    throw BrineStepError("the rename experiment renamed nothing — it proves nothing")
                }
                let after = RecordingSourceCatalog.merge(renamed)
                guard Set(after.map(\.identity)) == Set(world.merged.map(\.identity)) else {
                    throw BrineStepError("renaming the vendor changed the device SET")
                }
                let afterExpected = after
                    .sorted {
                        let left = $0.displayName.lowercased(), right = $1.displayName.lowercased()
                        if left != right { return left < right }
                        return $0.identity.storageKey < $1.identity.storageKey
                    }
                    .map(\.identity)
                guard after.map(\.identity) == afterExpected else {
                    throw BrineStepError(
                        "after renaming the vendor the list is no longer in name order: "
                            + "\(after.map(\.displayName))")
                }
            },
            defineCheck("{string} is refused with an actionable reason") { _, p, _ in
                let name = try p.requireString(0)
                let entry = try world.entry(named: name)
                guard let refusal = entry.eligibility.refusal else {
                    throw BrineStepError("\(name) was not refused")
                }
                let reason = refusal.actionableReason
                guard reason.count >= 12, reason.contains(" ") else {
                    throw BrineStepError("\(name)'s refusal reason is not actionable: \"\(reason)\"")
                }
            },
            defineCheck("the refusal text names no vendor") { _, _, _ in
                for entry in world.merged {
                    guard let refusal = entry.eligibility.refusal else { continue }
                    let lowered = refusal.actionableReason.lowercased()
                    if let leaked = vendorWords.first(where: { lowered.contains($0) }) {
                        throw BrineStepError("refusal reason names a vendor (\(leaked)): \(refusal.actionableReason)")
                    }
                }
            },
            defineCheck("every other discovered device is still eligible to connect") { _, _, _ in
                let others = world.merged.filter { $0.displayName != "Bad Mic" }
                guard !others.isEmpty else { throw BrineStepError("no other devices were listed at all") }
                let refused = others.filter { !$0.eligibility.isEligible }.map(\.displayName)
                guard refused.isEmpty else {
                    throw BrineStepError("one bad device took others down with it: \(refused)")
                }
            },
            defineCheck("every one of them is eligible") { _, _, _ in
                guard world.merged.count == RecordingDeviceShape.allCases.count else {
                    throw BrineStepError("expected one entry per shape, got \(world.merged.count)")
                }
                let refused = world.merged.filter { !$0.eligibility.isEligible }.map(\.displayName)
                guard refused.isEmpty else { throw BrineStepError("refused: \(refused)") }
                world.recordedEligibility = .eligible
            },
            defineStep("the same usable format is re-declared under a different shape and a different name") { ctx, _, _ in
                world.recordedEligibility = RecordingSourceCatalog.evaluate(RecordingDeviceObservation(
                    identity: RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "hw-renamed"),
                    reportedName: "Omi",
                    audioProfile: DeviceAgnosticSourceWorld.usable)).eligibility
                return ctx
            },
            defineStep("the same unusable format is re-declared under a different shape and a different name") { ctx, _, _ in
                let unusable = RecordingDeviceAudioProfile(
                    codec: "vendor-secret", sampleRateHz: 48_000, channels: 1, frameMilliseconds: 20)
                let first = RecordingSourceCatalog.evaluate(RecordingDeviceObservation(
                    identity: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "hw-a"),
                    reportedName: "Omi",
                    audioProfile: unusable)).eligibility
                let second = RecordingSourceCatalog.evaluate(RecordingDeviceObservation(
                    identity: RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: "hw-b"),
                    reportedName: "Trail Mic",
                    audioProfile: unusable)).eligibility
                world.recordedEligibility = first == second ? first : nil
                return ctx
            },
            defineCheck("its eligibility is unchanged") { _, _, _ in
                guard let recorded = world.recordedEligibility else {
                    throw BrineStepError("eligibility moved when only the shape and the name changed")
                }
                switch recorded {
                case .eligible: return
                case .refused(let reason):
                    // A refusal is "unchanged" only if BOTH re-declarations refused for the
                    // same reason; the step above stores nil when they disagreed.
                    guard reason == .unsupportedCodec("vendor-secret") else {
                        throw BrineStepError("refusal reason changed with shape/name: \(reason)")
                    }
                }
            },
            defineCheck("its firmware capability is unavailable") { _, _, _ in
                let entry = try world.entry(named: "Quiet Recorder")
                guard entry.capabilities.state(of: .firmwareVersion) == .unavailable else {
                    throw BrineStepError("firmware is \(entry.capabilities.state(of: .firmwareVersion))")
                }
                // The check must be able to see a capability that IS declared, or
                // "unavailable" would be the only answer it can ever give.
                guard entry.capabilities.state(of: .batteryLevel) == .reported("72") else {
                    throw BrineStepError(
                        "the capability reader cannot report a DECLARED value: "
                            + "battery is \(entry.capabilities.state(of: .batteryLevel))")
                }
            },
            defineCheck("its gap-recovery capability is unavailable") { _, _, _ in
                let entry = try world.entry(named: "Quiet Recorder")
                guard entry.capabilities.state(of: .gapRecovery) == .unavailable else {
                    throw BrineStepError("gap recovery is \(entry.capabilities.state(of: .gapRecovery))")
                }
            },
            defineCheck("no firmware value is fabricated") { _, _, _ in
                let entry = try world.entry(named: "Quiet Recorder")
                guard entry.capabilities.state(of: .firmwareVersion).reportedValue == nil else {
                    throw BrineStepError("a firmware value appeared from nowhere")
                }
            },
            defineCheck("the device is still listed") { _, _, _ in
                _ = try world.entry(named: "Future Recorder")
            },
            defineCheck("that capability is not available") { _, _, _ in
                let entry = try world.entry(named: "Future Recorder")
                let state = entry.capabilities.state(of: RecordingDeviceCapabilityKey("haptic-cue-playback"))
                guard !state.isAvailable else {
                    throw BrineStepError("an unrecognised capability reported itself available: \(state)")
                }
            },
            defineCheck("it is recorded as not understood rather than silently dropped") { _, _, _ in
                let entry = try world.entry(named: "Future Recorder")
                guard entry.capabilities.unrecognizedKeys == ["haptic-cue-playback"] else {
                    throw BrineStepError(
                        "unrecognised keys are \(entry.capabilities.unrecognizedKeys)")
                }
                guard case .notUnderstood("haptic-cue-playback") =
                        entry.capabilities.state(of: RecordingDeviceCapabilityKey("haptic-cue-playback")) else {
                    throw BrineStepError("the unrecognised capability is not reported as not-understood")
                }
            },
            defineStep("an armed recording device of each shape") { ctx, _, _ in
                world.reset()
                for shape in RecordingDeviceShape.allCases { world.armed[shape] = true }
                return ctx
            },
            defineStep("the system link drops") { ctx, _, _ in
                let decisions = RecordingDeviceShape.allCases.map { shape in
                    RecordingDeviceReconnectPolicy.onLinkLoss(
                        cause: .system, armed: world.armed[shape] ?? false)
                }
                world.reconnectDecision = Set(decisions).count == 1 ? decisions[0] : nil
                return ctx
            },
            defineCheck("the connection is re-issued without any user gesture") { _, _, _ in
                guard world.reconnectDecision == .reissuePendingConnect else {
                    throw BrineStepError(
                        "system drop decided \(String(describing: world.reconnectDecision))")
                }
            },
            defineCheck("that decision is the same one the shipped BLE reconnect policy makes") { _, _, _ in
                let shipped = OmiReconnectPolicy.onDisconnect(autoConnect: true)
                guard shipped == .reissuePendingConnect,
                      world.reconnectDecision == .reissuePendingConnect else {
                    throw BrineStepError(
                        "shipped policy says \(shipped), device-agnostic says "
                            + "\(String(describing: world.reconnectDecision))")
                }
            },
            defineStep("I detach the device myself") { ctx, _, _ in
                for shape in RecordingDeviceShape.allCases { world.armed[shape] = false }
                world.reconnectDecision = RecordingDeviceReconnectPolicy.onLinkLoss(
                    cause: .userDetach, armed: true)
                return ctx
            },
            defineCheck("the device stays detached") { _, _, _ in
                guard world.reconnectDecision == .stayDetached else {
                    throw BrineStepError(
                        "a user detach decided \(String(describing: world.reconnectDecision))")
                }
            },
            defineCheck("no automatic path re-arms it") { _, _, _ in
                let decisions = RecordingDeviceShape.allCases.map { shape in
                    RecordingDeviceReconnectPolicy.onLinkLoss(
                        cause: .system, armed: world.armed[shape] ?? false)
                }
                guard decisions.allSatisfy({ $0 == .stayDetached }) else {
                    throw BrineStepError("an automatic link event re-armed a detached device: \(decisions)")
                }
            },
            defineStep("I reconnect it myself") { ctx, _, _ in
                world.reconnectDecision = RecordingDeviceReconnectPolicy.onUserReconnect()
                return ctx
            },
            defineCheck("the connection is re-issued") { _, _, _ in
                guard world.reconnectDecision == .reissuePendingConnect else {
                    throw BrineStepError(
                        "a manual reconnect decided \(String(describing: world.reconnectDecision))")
                }
            },
        ]
    }
}
