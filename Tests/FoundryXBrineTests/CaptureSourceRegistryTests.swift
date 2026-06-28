import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// Capture-source registry tests (track 20260628T1702). Two layers:
///  - Plain XCTest unit assertions on the real `CaptureSourceRegistry` (seed, per-source
///    toggle + persistence, BT discover/add, active-source priority, watch scaffold).
///  - A HERMETIC Brine run of `features/capture-sources.feature` driving the same real
///    registry with an in-memory store + a fake input discovery — no UI, no hardware.
final class CaptureSourceRegistryTests: XCTestCase {

    /// Fake audio-input discovery: a settable list of routes + a record of the last
    /// preferred-input uid the registry asked for (so the BT route selection is testable).
    final class FakeAudioInputDiscovery: AudioInputDiscovering, @unchecked Sendable {
        private let lock = NSLock()
        private var _inputs: [DiscoveredAudioInput] = []
        private var _preferred: String?? = nil
        var inputs: [DiscoveredAudioInput] {
            get { lock.lock(); defer { lock.unlock() }; return _inputs }
            set { lock.lock(); _inputs = newValue; lock.unlock() }
        }
        var preferred: String?? { lock.lock(); defer { lock.unlock() }; return _preferred }
        func availableInputs() -> [DiscoveredAudioInput] { inputs }
        func setPreferredInput(uid: String?) { lock.lock(); _preferred = .some(uid); lock.unlock() }
    }

    // MARK: unit — seed + per-source toggle + persistence

    @MainActor
    func testSeedListsBuiltInsEnabled() {
        let reg = CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                                        discovery: FakeAudioInputDiscovery())
        XCTAssertEqual(reg.sources.map(\.category), [.omi, .phoneMic])
        XCTAssertTrue(reg.sources.allSatisfy { $0.enabled })
    }

    @MainActor
    func testToggleOffPersistsAcrossRelaunch() {
        let store = InMemoryCaptureSourceStore()
        let reg = CaptureSourceRegistry(store: store, discovery: FakeAudioInputDiscovery())
        reg.setEnabled(CaptureSourceDescriptor.omiId, false)
        XCTAssertFalse(reg.isEnabled(CaptureSourceDescriptor.omiId))
        // "Relaunch": a new registry over the SAME store must remember the choice.
        let reg2 = CaptureSourceRegistry(store: store, discovery: FakeAudioInputDiscovery())
        XCTAssertFalse(reg2.isEnabled(CaptureSourceDescriptor.omiId))
        XCTAssertTrue(reg2.isEnabled(CaptureSourceDescriptor.phoneMicId))
    }

    // MARK: unit — active-source policy (one active, by priority)

    @MainActor
    func testActiveSourceIsHighestPriorityEnabledReady() {
        let reg = CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                                        discovery: FakeAudioInputDiscovery())
        // Omi disconnected → phone mic (built-in, always ready) is active.
        XCTAssertEqual(reg.activeSource?.category, .phoneMic)
        // Omi connects → it wins on priority.
        reg.setOmiConnected(true)
        XCTAssertEqual(reg.activeSource?.category, .omi)
        // Disable Omi → hands off to the phone mic.
        reg.setEnabled(CaptureSourceDescriptor.omiId, false)
        XCTAssertEqual(reg.activeSource?.category, .phoneMic)
    }

    @MainActor
    func testActiveSourceChangeNotifiesCaptureKind() {
        let reg = CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                                        discovery: FakeAudioInputDiscovery())
        var kinds: [CaptureSourceKind] = []
        reg.onActiveSourceChanged = { kinds.append($0) }
        reg.setOmiConnected(true)             // → .omi
        reg.setEnabled(CaptureSourceDescriptor.omiId, false)  // → .phoneMic
        XCTAssertEqual(kinds, [.omi, .phoneMic])
    }

    // MARK: unit — BT mic discover/add + route selection

    @MainActor
    func testDiscoverAndAddBluetoothMic() {
        let discovery = FakeAudioInputDiscovery()
        discovery.inputs = [
            DiscoveredAudioInput(uid: "builtin", name: "iPhone Microphone", isBluetooth: false),
            DiscoveredAudioInput(uid: "bt-airpods", name: "AirPods Pro", isBluetooth: true),
        ]
        let reg = CaptureSourceRegistry(store: InMemoryCaptureSourceStore(), discovery: discovery)
        reg.discoverBluetoothMics()
        // Only Bluetooth inputs are surfaced as add-able.
        XCTAssertEqual(reg.discoveredBluetoothInputs.map(\.uid), ["bt-airpods"])
        reg.addBluetoothMic(reg.discoveredBluetoothInputs[0])
        let added = reg.sources.first { $0.category == .bluetoothMic }
        XCTAssertEqual(added?.displayName, "AirPods Pro")
        XCTAssertTrue(added?.canToggle == true)
        XCTAssertEqual(added?.routeUID, "bt-airpods")
        // A BT mic outranks the phone mic → becomes active + its route is preferred.
        XCTAssertEqual(reg.activeSource?.category, .bluetoothMic)
        XCTAssertEqual(discovery.preferred, .some("bt-airpods"))
    }

    @MainActor
    func testAddedBluetoothMicPersists() {
        let store = InMemoryCaptureSourceStore()
        let discovery = FakeAudioInputDiscovery()
        discovery.inputs = [DiscoveredAudioInput(uid: "bt-airpods", name: "AirPods Pro", isBluetooth: true)]
        let reg = CaptureSourceRegistry(store: store, discovery: discovery)
        reg.discoverBluetoothMics()
        reg.addBluetoothMic(reg.discoveredBluetoothInputs[0])
        // Relaunch rematerialises the added BT mic from the store.
        let reg2 = CaptureSourceRegistry(store: store, discovery: FakeAudioInputDiscovery())
        XCTAssertTrue(reg2.sources.contains { $0.id == CaptureSourceDescriptor.bluetoothId(routeUID: "bt-airpods") })
    }

    // MARK: unit — Apple Watch scaffold

    @MainActor
    func testAppleWatchIsNonToggleableScaffoldAndNeverActive() {
        let reg = CaptureSourceRegistry(store: InMemoryCaptureSourceStore(),
                                        discovery: FakeAudioInputDiscovery())
        reg.setOmiConnected(true)
        reg.addAppleWatchScaffold()
        let watch = reg.sources.first { $0.category == .appleWatch }
        XCTAssertNotNil(watch)
        XCTAssertFalse(watch?.canToggle ?? true)
        XCTAssertEqual(watch?.connection, .scaffold)
        // Disable every other source; the scaffold must still not become active.
        reg.setEnabled(CaptureSourceDescriptor.omiId, false)
        reg.setEnabled(CaptureSourceDescriptor.phoneMicId, false)
        XCTAssertNotEqual(reg.activeSource?.category, .appleWatch)
    }

    // MARK: hermetic brine — wire the feature scenarios to the real registry

    func testCaptureSourceScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Tests/FoundryXBrineTests/<file> -> package root
        let featurePath = url.appendingPathComponent("features/capture-sources.feature").path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = CaptureSourceWorld()
        let registry = StepRegistry(CaptureSourceSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "capture-sources scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all scenarios should pass")
    }
}

// MARK: - Brine world + steps (in-memory, no UI / hardware)

final class CaptureSourceWorld: @unchecked Sendable {
    let store = InMemoryCaptureSourceStore()
    let discovery = CaptureSourceRegistryTests.FakeAudioInputDiscovery()
    var registry: CaptureSourceRegistry?

    @MainActor func freshRegistry() -> CaptureSourceRegistry {
        // "Fresh" = a clean slate: the world's store/discovery are shared across the
        // feature run, so reset them so one scenario's added BT mic can't leak into the
        // next. (A WITHIN-scenario relaunch keeps the store, see `relaunch()`.)
        store.enabledOverrides = [:]
        store.addedSources = []
        discovery.inputs = []
        let r = CaptureSourceRegistry(store: store, discovery: discovery)
        registry = r
        return r
    }
    @MainActor func relaunch() -> CaptureSourceRegistry {
        let r = CaptureSourceRegistry(store: store, discovery: discovery)
        registry = r
        return r
    }
}

struct CaptureSourceStepError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

enum CaptureSourceSteps {
    /// Map a display name in the feature to a registry source id.
    static func id(forName name: String) -> String {
        switch name {
        case "Omi wearable": return CaptureSourceDescriptor.omiId
        case "Phone microphone": return CaptureSourceDescriptor.phoneMicId
        case "Apple Watch": return CaptureSourceDescriptor.appleWatchId
        default: return name
        }
    }

    static func make(world: CaptureSourceWorld) -> [StepDefinition] {
        [
            defineStep("a fresh capture-source registry") { ctx, _, _ in
                await MainActor.run { _ = world.freshRegistry() }
                return ctx
            },
            defineCheck("it lists the {string} and {string} sources") { _, p, _ in
                let a = try p.requireString(0), b = try p.requireString(1)
                let names = await MainActor.run { world.registry?.sources.map(\.displayName) ?? [] }
                guard names.contains(a), names.contains(b) else {
                    throw CaptureSourceStepError("sources \(names) missing \(a)/\(b)")
                }
            },
            defineCheck("both are enabled by default") { _, _, _ in
                let allOn = await MainActor.run { world.registry?.sources.allSatisfy { $0.enabled } ?? false }
                guard allOn else { throw CaptureSourceStepError("not all sources enabled by default") }
            },
            defineStep("I turn off the {string} source") { ctx, p, _ in
                let sid = id(forName: try p.requireString(0))
                await MainActor.run { world.registry?.setEnabled(sid, false) }
                return ctx
            },
            defineStep("I turn on the {string} source") { ctx, p, _ in
                let sid = id(forName: try p.requireString(0))
                await MainActor.run { world.registry?.setEnabled(sid, true) }
                return ctx
            },
            defineCheck("the {string} source is off") { _, p, _ in
                let sid = id(forName: try p.requireString(0))
                let on = await MainActor.run { world.registry?.isEnabled(sid) ?? true }
                guard !on else { throw CaptureSourceStepError("\(sid) is on, expected off") }
            },
            defineCheck("the {string} source is on") { _, p, _ in
                let sid = id(forName: try p.requireString(0))
                let on = await MainActor.run { world.registry?.isEnabled(sid) ?? false }
                guard on else { throw CaptureSourceStepError("\(sid) is off, expected on") }
            },
            defineStep("the app relaunches with the same saved settings") { ctx, _, _ in
                await MainActor.run { _ = world.relaunch() }
                return ctx
            },
            defineCheck("the {string} source is still off") { _, p, _ in
                let sid = id(forName: try p.requireString(0))
                let on = await MainActor.run { world.registry?.isEnabled(sid) ?? true }
                guard !on else { throw CaptureSourceStepError("\(sid) is on after relaunch, expected off") }
            },
            defineStep("a Bluetooth microphone {string} is connected") { ctx, p, _ in
                let name = try p.requireString(0)
                world.discovery.inputs = [DiscoveredAudioInput(uid: "bt-\(name)", name: name, isBluetooth: true)]
                return ctx
            },
            defineStep("I discover Bluetooth microphones") { ctx, _, _ in
                await MainActor.run { world.registry?.discoverBluetoothMics() }
                return ctx
            },
            defineCheck("the add-source list offers {string}") { _, p, _ in
                let name = try p.requireString(0)
                let names = await MainActor.run { world.registry?.discoveredBluetoothInputs.map(\.name) ?? [] }
                guard names.contains(name) else { throw CaptureSourceStepError("add-source list \(names) missing \(name)") }
            },
            defineStep("I add the {string} Bluetooth microphone") { ctx, p, _ in
                let name = try p.requireString(0)
                await MainActor.run {
                    if let input = world.registry?.discoveredBluetoothInputs.first(where: { $0.name == name }) {
                        _ = world.registry?.addBluetoothMic(input)
                    }
                }
                return ctx
            },
            defineCheck("the registry lists a source named {string} with its own toggle") { _, p, _ in
                let name = try p.requireString(0)
                let ok = await MainActor.run {
                    world.registry?.sources.first { $0.displayName == name }.map { $0.canToggle } ?? false
                }
                guard ok else { throw CaptureSourceStepError("no toggleable source named \(name)") }
            },
            defineStep("the Omi is connected") { ctx, _, _ in
                await MainActor.run { world.registry?.setOmiConnected(true) }
                return ctx
            },
            defineCheck("the active capture source is the Omi") { _, _, _ in
                let cat = await MainActor.run { world.registry?.activeSource?.category }
                guard cat == .omi else { throw CaptureSourceStepError("active source is \(String(describing: cat)), expected omi") }
            },
            defineCheck("the active capture source is the phone microphone") { _, _, _ in
                let cat = await MainActor.run { world.registry?.activeSource?.category }
                guard cat == .phoneMic else { throw CaptureSourceStepError("active source is \(String(describing: cat)), expected phoneMic") }
            },
            defineStep("I add the Apple Watch source") { ctx, _, _ in
                await MainActor.run { _ = world.registry?.addAppleWatchScaffold() }
                return ctx
            },
            defineCheck("the {string} source is present but cannot be toggled") { _, p, _ in
                let name = try p.requireString(0)
                let ok = await MainActor.run {
                    world.registry?.sources.first { $0.displayName == name }.map { !$0.canToggle } ?? false
                }
                guard ok else { throw CaptureSourceStepError("\(name) absent or still toggleable") }
            },
            defineCheck("the Apple Watch is never the active source") { _, _, _ in
                let cat = await MainActor.run { world.registry?.activeSource?.category }
                guard cat != .appleWatch else { throw CaptureSourceStepError("Apple Watch became active") }
            },
        ]
    }
}
