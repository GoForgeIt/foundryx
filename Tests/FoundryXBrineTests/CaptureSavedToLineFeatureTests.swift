import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// features/capture-saved-to-line-and-recorder-status.feature, driven against the REAL
/// production values — `SyncStripCopy`, `RecorderLinkBadge`, `CaptureWAL`'s own log-line
/// builder, and a source scan of the App target (which `swift test` cannot compile).
///
/// WHY THIS FILE EXISTS. The shipped assertion was
/// `SyncStripCopy.allSaved(local: false) == "All voice notes saved to computer"` — a
/// BOOLEAN pinned over a THREE-valued fact. `RootGate` resolves to `.computerBrain`,
/// `.cellBrain` or `.phoneBrain`; the first two both passed `local: false`, so a
/// cell-brain owner with no computer read "All voice notes saved to computer" and the
/// test agreed with him. Every scenario below is asserted for ALL THREE brains, so the
/// two that happen to agree today cannot stand in for the one that does not.
final class CaptureSavedToLineFeatureTests: ProcessGlobalStateTestCase {

    func testCaptureSavedToLineScenarios() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let featurePath = url
            .appendingPathComponent("features/capture-saved-to-line-and-recorder-status.feature")
            .path
        let text = try String(contentsOfFile: featurePath, encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = SavedToLineWorld()
        let registry = StepRegistry(SavedToLineSteps.make(world: world))

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
        XCTAssertTrue(failures.isEmpty,
                      "capture saved-to-line scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count,
                       "every scenario in the feature must run — an undefined step is not a pass")
    }
}

// MARK: - The world

/// Vendor words no recorder-agnostic surface may say. Kept as a POPULATION rather than as
/// the one brand whichever author was thinking of.
private let vendorWords = ["omi", "pocket", "airpods", "friend", "limitless", "bose", "jabra"]

private func namesAVendor(_ text: String) -> String? {
    vendorWords.first { text.range(of: $0, options: .caseInsensitive) != nil }
}

private final class SavedToLineWorld: @unchecked Sendable {
    /// The single destination under test in the one-brain scenarios.
    var destination: CaptureDestination = .phone
    /// Every destination the root gate can resolve to (the all-three scenarios).
    var allDestinations: [CaptureDestination] = []
    /// The badge under test.
    var badge: RecorderLinkBadge = .init(tone: .idle, label: "")

    // The WAL leg.
    var baseDir: URL = FileManager.default.temporaryDirectory
    var target: DoorTarget = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    var log = DoorLog()
    var captureId = ""

    func seedOneSegment() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-savedto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        captureId = "cap-\(UUID().uuidString.prefix(8))"
        let cdir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        let name = String(format: "seg-%012llu", UInt64(0))
        try Data([0, 1, 2, 3]).write(to: cdir.appendingPathComponent("\(name).opus"))
    }

    /// Drive one real sync pass and let the log's main-queue hop land.
    ///
    /// The closure stands in for a REAL DOOR's 200 — the scenarios here are about a
    /// hosted Vault at an address this machine cannot listen on — so the route is
    /// DECLARED rather than left to be derived. It has to be declared, because an
    /// upload override that names nothing is now reported as untraceable instead of
    /// borrowing its target's address: that default is the fix for nine segments ACK'd
    /// by a phone-only brain to a loopback port nothing served. The derived `.door`
    /// case is proved over a real socket in
    /// features/an-upload-names-where-it-sent-the-bytes.feature.
    func uploadAndAck() async throws {
        let wal = CaptureWAL(captureId: captureId, target: target, baseDir: baseDir,
                             log: log, upload: { _, _ in }, route: .door)
        let outcome = await wal.sync()
        guard outcome == .progressed else {
            throw BrineStepError("the seeded segment did not upload: \(outcome)")
        }
        // `DoorLog.info` hops to the main queue when written off-main, which every WAL
        // upload is. Await it rather than reading a buffer that has not been appended to.
        let deadline = Date().addingTimeInterval(5)
        while ackLines.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    var ackLines: [String] { log.entries.map(\.text).filter { $0.contains("ACK'd") } }
}

// MARK: - Steps

private enum SavedToLineSteps {
    static func make(world w: SavedToLineWorld) -> [StepDefinition] {
        [
            // MARK: the saved-to line, per brain

            defineStep("the app resolved to the computer brain") { ctx, _, _ in
                w.destination = try require(RootDestination.computerBrain)
                return ctx
            },
            defineStep("the app resolved to the cloud brain") { ctx, _, _ in
                w.destination = try require(RootDestination.cellBrain)
                return ctx
            },
            defineStep("the app resolved to the phone brain") { ctx, _, _ in
                w.destination = try require(RootDestination.phoneBrain)
                return ctx
            },
            defineCheck("the settled sync line reads {string}") { _, p, _ in
                let expected = try p.requireString(0)
                let actual = SyncStripCopy.allSaved(destination: w.destination)
                try expect(actual == expected,
                           "the \(w.destination.rawValue) brain's saved-to line is "
                           + "\"\(actual)\", not \"\(expected)\"")
            },
            defineCheck("the settled sync line does not mention a computer") { _, _, _ in
                let actual = SyncStripCopy.allSaved(destination: w.destination)
                try expect(!actual.localizedCaseInsensitiveContains("computer"),
                           "the \(w.destination.rawValue) brain's saved-to line names a "
                           + "computer this user may not have: \"\(actual)\"")
            },

            // MARK: all three brains at once

            defineStep("every brain the root gate can resolve to") { ctx, _, _ in
                // FROM THE GATE, NOT FROM A HAND-WRITTEN LIST. A fourth brain added to
                // `RootDestination` arrives here without anyone remembering to add it.
                let resolvable: [RootDestination] = [.computerBrain, .cellBrain, .phoneBrain]
                w.allDestinations = try resolvable.map { try require($0) }
                try expect(w.allDestinations.count == CaptureDestination.allCases.count,
                           "the gate resolves to \(w.allDestinations.count) brains but there "
                           + "are \(CaptureDestination.allCases.count) destinations — one of "
                           + "them is unreachable or unnamed")
                return ctx
            },
            defineCheck("each brain's saved-to line names that brain's own destination and no other") { _, _, _ in
                // The place each destination MAY name, and the places it may not.
                let names: [CaptureDestination: String] = [
                    .computer: "computer",
                    .vault: "vault",
                ]
                for destination in w.allDestinations {
                    let line = SyncStripCopy.allSaved(destination: destination)
                    for (other, word) in names where other != destination {
                        try expect(!line.localizedCaseInsensitiveContains(word),
                                   "the \(destination.rawValue) brain's line names the "
                                   + "\(other.rawValue): \"\(line)\"")
                    }
                    if let own = names[destination] {
                        try expect(line.localizedCaseInsensitiveContains(own),
                                   "the \(destination.rawValue) brain's line does not name "
                                   + "its own destination: \"\(line)\"")
                    }
                }
            },
            defineCheck("no two brains share a saved-to line") { _, _, _ in
                let lines = w.allDestinations.map { SyncStripCopy.allSaved(destination: $0) }
                try expect(Set(lines).count == lines.count,
                           "two brains render the SAME sentence — the exact shape of the "
                           + "defect this feature exists for: \(lines)")
            },
            defineCheck("no brain's empty-library invitation names a vendor") { _, _, _ in
                for destination in w.allDestinations {
                    let copy = SyncStripCopy.emptyLibraryInvitation(destination: destination)
                    if let vendor = namesAVendor(copy) {
                        throw BrineStepError("the \(destination.rawValue) brain's empty-state "
                                             + "copy names \"\(vendor)\": \"\(copy)\"")
                    }
                }
            },
            defineCheck("no brain's empty-library invitation points at a block above it") { _, _, _ in
                for destination in w.allDestinations {
                    let copy = SyncStripCopy.emptyLibraryInvitation(destination: destination)
                    try expect(!copy.localizedCaseInsensitiveContains("above"),
                               "the \(destination.rawValue) brain's empty-state copy points "
                               + "at something above it that no longer exists: \"\(copy)\"")
                }
            },

            // MARK: the recorder status icon

            defineStep("a recorder is connected") { ctx, _, _ in
                w.badge = RecorderLinkBadge.resolve(
                    link: .connected("R-1"), enabled: true, sources: [])
                return ctx
            },
            defineStep("a recorder link is being re-established") { ctx, _, _ in
                w.badge = RecorderLinkBadge.resolve(
                    link: .disconnected, enabled: true, sources: [])
                return ctx
            },
            defineStep("no recorder is connected") { ctx, _, _ in
                w.badge = RecorderLinkBadge.resolve(link: .idle, enabled: true, sources: [])
                return ctx
            },
            defineStep("only the phone's built-in microphone is available") { ctx, _, _ in
                let mic = CaptureSourceDescriptor(
                    id: CaptureSourceDescriptor.phoneMicId, category: .phoneMic,
                    displayName: "iPhone microphone", connection: .builtIn,
                    enabled: true, canToggle: false, isBuiltIn: true)
                w.badge = RecorderLinkBadge.resolve(link: .idle, enabled: false, sources: [mic])
                return ctx
            },
            defineStep("the recorder status icon") { ctx, _, _ in
                w.badge = RecorderLinkBadge.resolve(link: .idle, enabled: true, sources: [])
                return ctx
            },
            defineCheck("the recorder status icon is green") { _, _, _ in
                try expect(w.badge.isConnected,
                           "the badge is \(w.badge.tone.rawValue), not connected")
            },
            defineCheck("the recorder status icon is not green") { _, _, _ in
                try expect(!w.badge.isConnected,
                           "the badge reads connected (\(w.badge.label)) when nothing is")
            },
            defineCheck("its label names no vendor") { _, _, _ in
                if let vendor = namesAVendor(w.badge.label) {
                    throw BrineStepError("the badge label names \"\(vendor)\": \(w.badge.label)")
                }
            },
            defineCheck("its label says nothing is connected") { _, _, _ in
                try expect(w.badge.label.localizedCaseInsensitiveContains("no recorder"),
                           "the idle badge label does not say nothing is connected: "
                           + "\"\(w.badge.label)\"")
            },
            defineCheck("tapping it opens the {string} page on the Settings tab") { _, p, _ in
                let page = try p.requireString(0)
                try expect(RecorderLinkBadge.destinationPage == page,
                           "the badge routes to \"\(RecorderLinkBadge.destinationPage)\", "
                           + "not \"\(page)\"")
                try expect(RecorderLinkBadge.destinationTab == .settings,
                           "the badge routes to the \(RecorderLinkBadge.destinationTab) tab")
                // THE WHOLE CHAIN, NOT THE NAME. `swift test` cannot compile `App/`, and a
                // route that is declared but never applied is exactly the shape of defect
                // this feature exists for. Each link is held where it lives.
                let capture = try captureScreenSource()
                try expect(capture.contains("Button(action: onOpenDevices)"),
                           "the recorder status icon is not a button that opens anything")
                let root = try appSource("App/RootView.swift")
                try expect(root.contains("onOpenDevices: { router.openDevices() }"),
                           "the capture screen's open-devices action is never wired to the "
                           + "router, so the icon taps into nothing")
                try expect(root.contains("openDevices: $router.openDeviceSettings"),
                           "Settings is never handed the route, so the router would select "
                           + "the tab and stop one tap short of the devices page")
                let settings = try appSource("App/SettingsScreen.swift")
                try expect(settings.contains("navigationDestination(isPresented: $openDevices)"),
                           "Settings never pushes the device page for the route")
            },

            // MARK: the header, as the App target actually spells it

            defineStep("the capture screen as the app actually ships it") { ctx, _, _ in
                _ = try captureScreenSource()
                return ctx
            },
            defineCheck("the capture screen offers no {string} button") { _, p, _ in
                let banned = try p.requireString(0)
                let capture = try captureScreenSource()
                try expect(!capture.contains(banned),
                           "App/CaptureScreen.swift still renders \"\(banned)\"")
            },
            defineCheck("the capture screen renders the recorder status badge from the shared model") { _, _, _ in
                let files = try AppSourceTree.filesReferencing("RecorderLinkBadge")
                try expect(files.contains("App/CaptureScreen.swift"),
                           "no App-side capture surface references RecorderLinkBadge; the "
                           + "icon would be a second, untested decision. Referencing files: "
                           + "\(files)")
            },
            defineCheck("the capture screen takes its saved-to line from the resolved destination") { _, _, _ in
                let capture = try captureScreenSource()
                try expect(capture.contains("SyncStripCopy.allSaved(destination:"),
                           "App/CaptureScreen.swift does not build its saved-to line from a "
                           + "resolved destination")
                try expect(!capture.contains("allSaved(local:"),
                           "App/CaptureScreen.swift still asks the boolean question")
            },

            // MARK: the WAL log line

            defineStep("a capture whose door is a Vault at {string}") { ctx, p, _ in
                let url = try p.requireString(0)
                w.target = DoorTarget(baseURL: URL(string: url)!, bearer: "x")
                w.log = DoorLog()
                try w.seedOneSegment()
                return ctx
            },
            defineStep("a capture whose door is reached through relay tunnel {string}") { ctx, p, _ in
                let tunnel = try p.requireString(0)
                w.target = DoorTarget(
                    baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x",
                    relay: RelayConfig(relayURL: URL(string: "wss://relay.example.dev")!,
                                       tunnelId: tunnel,
                                       staticPrivate: Data(repeating: 0, count: 32)))
                return ctx
            },
            defineStep("a segment is uploaded and acknowledged") { ctx, _, _ in
                try await w.uploadAndAck()
                return ctx
            },
            defineCheck("the ACK log line names {string}") { _, p, _ in
                let expected = try p.requireString(0)
                let lines = w.ackLines
                try expect(!lines.isEmpty, "no ACK line was logged at all")
                try expect(lines.allSatisfy { $0.contains(expected) },
                           "an ACK line does not name where the bytes went (\(expected)): "
                           + "\(lines)")
            },
            defineCheck("the ACK log line does not claim the bytes reached a computer") { _, _, _ in
                for line in w.ackLines {
                    try expect(!line.localizedCaseInsensitiveContains("computer")
                               && !line.localizedCaseInsensitiveContains("desktop"),
                               "the ACK line still claims a computer: \(line)")
                }
            },
            defineCheck("the logged upload destination names {string}") { _, p, _ in
                let expected = try p.requireString(0)
                let described = CaptureWAL.uploadDestination(w.target)
                try expect(described.contains(expected),
                           "the upload destination is \"\(described)\", which does not name "
                           + "\(expected)")
            },
            defineCheck("the logged upload destination does not claim the bytes reached a computer") { _, _, _ in
                let described = CaptureWAL.uploadDestination(w.target)
                try expect(!described.localizedCaseInsensitiveContains("computer")
                           && !described.localizedCaseInsensitiveContains("desktop"),
                           "the upload destination claims a computer: \(described)")
            },
        ]
    }

    /// An App-side file with comments removed and string literals INTACT — the copy is
    /// exactly what is being held, so it must survive the strip.
    ///
    /// NON-VACUOUS FIRST: an unreadable or moved file would make every "does not contain"
    /// check pass for the wrong reason, which is the failure mode a source scan has.
    fileprivate static func source(_ path: String) throws -> String {
        let file = AppSourceTree.repoRoot.appendingPathComponent(path)
        let text = AppSourceTree.withoutComments(of: try String(contentsOf: file, encoding: .utf8))
        guard text.count > 1_000 else {
            throw BrineStepError("\(path) read as \(text.count) characters — the scan is "
                                 + "reading nothing and every absence check would be vacuous")
        }
        return text
    }
}

private func appSource(_ path: String) throws -> String { try SavedToLineSteps.source(path) }
private func captureScreenSource() throws -> String { try appSource("App/CaptureScreen.swift") }

/// Only a brain the app can actually be running on has a destination to name.
private func require(_ destination: RootDestination) throws -> CaptureDestination {
    guard let resolved = destination.captureDestination else {
        throw BrineStepError("\(destination) resolves to no capture destination")
    }
    return resolved
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw BrineStepError(message) }
}
