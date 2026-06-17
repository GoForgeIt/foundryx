import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// P1 green gate: drive the REAL 3a door (gateway → kiln-session) through the Swift
/// Brine runner + the Fixture API — no mocks. The `foundryx-door` suite resource spawns
/// the real `foundryx_door` example (which boots a real gateway + real kiln-session +
/// a real openai-completions recording target), and the step defs drive the real
/// `FoundryXKit.DoorClient` (the M3 app's networking core) against it. Asserts an
/// authenticated turn streams a completed reply, an unauthenticated turn is rejected,
/// and the routed turn is recorded in kiln-session's real event log (AC2 + AC3).
struct DoorTestError: Error { let message: String }

final class FoundryXDoorTests: XCTestCase {

    // MARK: paths (dev fixture; M3 will make these configurable)
    static func packageRoot() -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }  // Tests/BrineSwiftCoreTests/<file> -> swift/
        return url.path
    }
    static let doorExample = NSHomeDirectory() + "/Development/foundry/src-tauri/target/debug/examples/foundryx_door"
    static let kilnSessionBin = NSHomeDirectory() + "/Development/kiln/target/release/kiln-session"

    func testDoorScenariosAgainstRealDoor() async throws {
        // Skip cleanly if the dev fixture binaries aren't built (keeps the suite honest
        // about what it needs rather than failing opaquely).
        guard FileManager.default.fileExists(atPath: Self.doorExample),
              FileManager.default.fileExists(atPath: Self.kilnSessionBin) else {
            throw XCTSkip("real-door fixture binaries not built (foundryx_door / kiln-session)")
        }

        let root = Self.packageRoot()
        let text = try String(contentsOfFile: "\(root)/features/door.feature", encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = DoorWorld()
        let registry = StepRegistry(DoorSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [DoorSteps.doorResource()],
                                             collector: { collected.append($0) })

        var failures: [String] = []
        for ev in collected {
            guard case .object(let o) = ev,
                  case .string("scenario_end")? = o["type"],
                  case .string(let status)? = o["status"], status != "passed" else { continue }
            let name: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(name): \(err)")
        }
        XCTAssertTrue(failures.isEmpty, "door scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
        XCTAssertEqual(result.passed, parsed.features[0].scenarios.count, "all door scenarios should pass")
    }
}

// MARK: - Cross-step world (held by the step closures; reset per scenario in the Given,
// mirroring the Rust seam's global-state pattern — robust against the retain-keys prune).
final class DoorWorld: @unchecked Sendable {
    var doorURL = ""
    var bearer = ""
    var eventLog = ""
    var events: [DoorEvent] = []
    var lastError: Error?

    func resetFromSeed(_ ctx: BrineContext) throws {
        doorURL = try ctx.require("door_url")
        bearer = try ctx.require("bearer")
        eventLog = (ctx.get("event_log") as String?) ?? ""
        events = []
        lastError = nil
    }
    func makeClient(bearerOverride: String? = nil) -> DoorClient {
        DoorClient(target: DoorTarget(baseURL: URL(string: doorURL)!, bearer: bearerOverride ?? bearer))
    }
}

enum DoorSteps {

    // MARK: the real-door Fixture
    static func doorResource() -> ResourceDefinition {
        ResourceDefinition(name: "foundryx-door", scope: .suite,
                           provides: ["door_url", "bearer", "event_log"]) { _ in
            let fm = FileManager.default
            let workdir = NSTemporaryDirectory() + "foundryx-brine-p1-\(UUID().uuidString)"
            try fm.createDirectory(atPath: workdir, withIntermediateDirectories: true)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: FoundryXDoorTests.doorExample)
            var env = ProcessInfo.processInfo.environment
            env["KILN_SESSION_BIN"] = FoundryXDoorTests.kilnSessionBin
            env["TMPDIR"] = workdir              // controls the example's std::env::temp_dir()
            proc.environment = env
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            try proc.run()

            let (base, token) = try await readDoorHandshake(outPipe, timeout: 45)
            let eventLog = "\(workdir)/foundryx-door-example/events.jsonl"
            return ["door_url": base, "bearer": token, "event_log": eventLog,
                    "_proc": proc, "_workdir": workdir]
        } disposer: { provided in
            if let proc = provided["_proc"] as? Process { proc.terminate(); proc.waitUntilExit() }
            if let wd = provided["_workdir"] as? String { try? FileManager.default.removeItem(atPath: wd) }
        }
    }

    // MARK: step definitions (drive the real DoorClient)
    static func make(world: DoorWorld) -> [StepDefinition] {
        [
            defineStep("a running Foundry door") { ctx, _, _ in
                try world.resetFromSeed(ctx)
                return ctx
            },
            defineStep("the client sends an authenticated message {string}") { ctx, p, _ in
                let msg = try p.requireString(0)
                world.events = try await world.makeClient().collect(
                    ChatRequest(message: msg, platform: "foundryx", chatId: "c1", org: "acme"))
                return ctx
            },
            defineStep("the client sends a message with no bearer token") { ctx, _, _ in
                do {
                    _ = try await world.makeClient(bearerOverride: "").collect(
                        ChatRequest(message: "hi", platform: "foundryx", chatId: "c1", org: "acme"))
                    world.lastError = nil
                } catch {
                    world.lastError = error
                }
                return ctx
            },
            defineCheck("the door opened a session") { _, _, _ in
                guard world.events.contains(where: { if case .session = $0 { return true }; return false }) else {
                    throw DoorTestError(message: "no session event in \(world.events)")
                }
            },
            defineCheck("the reply streams at least one assistant delta") { _, _, _ in
                guard world.events.contains(where: { if case .assistantDelta = $0 { return true }; return false }) else {
                    throw DoorTestError(message: "no assistant_delta in \(world.events)")
                }
            },
            defineCheck("the turn ends with done reason {string}") { _, p, _ in
                let want = try p.requireString(0)
                let done = world.events.last(where: { if case .done = $0 { return true }; return false })
                guard case .done(let reason)? = done, reason == want else {
                    throw DoorTestError(message: "expected done reason \"\(want)\", got \(String(describing: done))")
                }
            },
            defineCheck("the door rejects it as unauthorized") { _, _, _ in
                guard case DoorError.unauthorized? = (world.lastError as? DoorError) else {
                    throw DoorTestError(message: "expected DoorError.unauthorized, got \(String(describing: world.lastError))")
                }
            },
            defineCheck("the kiln-session event log records a routed turn") { _, _, _ in
                guard !world.eventLog.isEmpty,
                      let content = try? String(contentsOfFile: world.eventLog, encoding: .utf8) else {
                    throw DoorTestError(message: "no kiln-session event log at \(world.eventLog)")
                }
                let routed = content.contains("mlx-local") || content.lowercased().contains("routed")
                    || content.contains("\"route") || content.contains("\"outcome\"")
                guard routed else {
                    throw DoorTestError(message: "event log present but no routed turn recorded; head: \(content.prefix(400))")
                }
            },
            // AC4 — real hosted SwiftUI view driven by the real streamed turn (no mock).
            defineCheck("the streamed reply renders in a hosted ChatView ending in {string}") { _, p, _ in
                let want = try p.requireString(0)
                let events = world.events
                #if canImport(SwiftUI) && canImport(AppKit)
                try await MainActor.run {
                    let model = ChatViewModel()
                    model.beginUserTurn("hello")
                    model.applyAll(events)               // fold the REAL door events into state
                    let host = NSHostingView(rootView: ChatView(model: model))
                    host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
                    host.layoutSubtreeIfNeeded()          // force SwiftUI to build the body + lay out
                    guard host.fittingSize.width > 0 else {
                        throw DoorTestError(message: "hosted ChatView produced no layout (fittingSize=\(host.fittingSize))")
                    }
                    guard !model.assistantText.isEmpty else {
                        throw DoorTestError(message: "assistant bubble empty after real stream: \(events)")
                    }
                    guard case .completed(let reason) = model.turnState, reason == want else {
                        throw DoorTestError(message: "expected hosted view turnState .completed(\"\(want)\"), got \(model.turnState)")
                    }
                }
                #else
                throw DoorTestError(message: "SwiftUI/AppKit unavailable — cannot host ChatView on this platform")
                #endif
            },
        ]
    }
}

// MARK: - Read the door example's stdout handshake (gateway URL + bearer) with timeout.
private func readDoorHandshake(_ pipe: Pipe, timeout: TimeInterval) async throws -> (base: String, token: String) {
    final class Box: @unchecked Sendable { var done = false; var buffer = Data(); let lock = NSLock() }
    let box = Box()
    let fh = pipe.fileHandleForReading
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String), Error>) in
        fh.readabilityHandler = { handle in
            let chunk = handle.availableData
            box.lock.lock(); defer { box.lock.unlock() }
            if box.done { return }
            if chunk.isEmpty {
                box.done = true; fh.readabilityHandler = nil
                cont.resume(throwing: DoorError.transport("door exited before handshake"))
                return
            }
            box.buffer.append(chunk)
            if let s = String(data: box.buffer, encoding: .utf8), let parsed = parseDoorHandshake(s) {
                box.done = true; fh.readabilityHandler = nil
                cont.resume(returning: parsed)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            box.lock.lock(); defer { box.lock.unlock() }
            if !box.done {
                box.done = true; fh.readabilityHandler = nil
                cont.resume(throwing: DoorError.transport("timeout waiting for door handshake"))
            }
        }
    }
}

/// Parse the example's printed block:
///   gateway : http://127.0.0.1:<port>/foundryx/chat
///   token   : <token>
private func parseDoorHandshake(_ s: String) -> (base: String, token: String)? {
    var base: String?
    var token: String?
    for raw in s.split(separator: "\n") {
        let line = String(raw)
        // Match the LABEL lines only (trimmed prefix) — not any line that merely
        // mentions "token"/the URL. The example also prints a curl help line
        // containing `Authorization: Bearer <token>`, whose substring "token"
        // would otherwise overwrite the real token with garbage → 401.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("gateway") {
            for tok in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) where tok.hasPrefix("http://") {
                var u = String(tok)
                if let r = u.range(of: "/foundryx/chat") { u = String(u[..<r.lowerBound]) }
                base = u
            }
        } else if trimmed.hasPrefix("token"), let idx = line.firstIndex(of: ":") {
            token = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        }
    }
    if let b = base, let t = token, !t.isEmpty { return (b, t) }
    return nil
}
