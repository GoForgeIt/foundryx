// macOS-only: reuses FoundryXDoorTests' real-door fixture (spawns the door binary
// via Foundation `Process`), so it's gated to macOS like that file — skipped in the
// iOS-simulator logic-test target, still runs under `swift test` on macOS.
#if os(macOS)
import XCTest
import Foundation
import BrineSwiftCore
import FoundryXKit

/// M4 green gate: drive the phone-side capture pipeline (ReplaySource → CaptureWAL)
/// against the REAL door's /foundryx/capture via the Fixture API — no mocks. Reuses
/// the `foundryx-door` suite resource (real gateway + kiln-session) from
/// FoundryXDoorTests; the capture endpoint lives on the same gateway. Asserts
/// segments durably upload + are marked synced ONLY on the door's 200 ACK,
/// idempotent re-sync, and that an unreachable door leaves segments pending which
/// drain on reconnect. The real Omi BLE source is the excluded @ble-hardware lane.
struct CaptureTestError: Error { let message: String; init(_ m: String) { message = m } }

final class FoundryXCaptureTests: XCTestCase {
    func testCaptureScenariosAgainstRealDoor() async throws {
        // Opt-in only. This suite spawns a real door + kiln-session fixture, which is
        // NON-HERMETIC on a machine running the live Foundry.app: the fixture's
        // kiln-session collides with the live one, so WAL→door sync flakes (0/N
        // synced) intermittently. CI runs on the live-app Mac, so excluding it here
        // keeps the release gate deterministic. Run it in a controlled lane with
        // FOUNDRYX_REAL_DOOR_TESTS=1 (no live app on the same host).
        guard ProcessInfo.processInfo.environment["FOUNDRYX_REAL_DOOR_TESTS"] == "1" else {
            throw XCTSkip("real-door integration test — opt in with FOUNDRYX_REAL_DOOR_TESTS=1 (non-hermetic; excluded from the CI gate)")
        }
        guard FileManager.default.fileExists(atPath: FoundryXDoorTests.doorExample),
              FileManager.default.fileExists(atPath: FoundryXDoorTests.kilnSessionBin) else {
            throw XCTSkip("real-door fixture binaries not built (foundryx_door / kiln-session)")
        }
        let root = FoundryXDoorTests.packageRoot()
        let text = try String(contentsOfFile: "\(root)/features/capture.feature", encoding: .utf8)
        let parsed = parseFeatureText(text)
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed")

        let world = CaptureWorld()
        let registry = StepRegistry(CaptureSteps.make(world: world))

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [DoorSteps.doorResource()],
                                             tagFilter: TagFilter(exclude: ["@ble-hardware"]),
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
        XCTAssertTrue(failures.isEmpty, "capture scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "expected 0 failed scenarios")
    }
}

/// Cross-step state (held by the closures; reset per scenario in the Given), robust
/// against the retain-keys prune — same pattern as DoorWorld.
final class CaptureWorld: @unchecked Sendable {
    var doorURL = ""
    var bearer = ""
    var baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
    var captureId = ""
    var reachable = true
    var wal: CaptureWAL?

    func reset(_ ctx: BrineContext) throws {
        doorURL = try ctx.require("door_url")
        bearer = try ctx.require("bearer")
        baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-cap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        captureId = "omi-test-\(UUID().uuidString.prefix(8))"
        reachable = true
        wal = nil
    }

    /// Real door when reachable; a dead loopback port when "offline".
    var activeURL: String { reachable ? doorURL : "http://127.0.0.1:59999" }

    func makeWAL() -> CaptureWAL {
        let target = DoorTarget(baseURL: URL(string: activeURL)!, bearer: bearer)
        let w = CaptureWAL(captureId: captureId, target: target, baseDir: baseDir, chunkFrames: 25)
        wal = w
        return w
    }
}

enum CaptureSteps {
    /// N fake Opus frames (40 bytes each) — the pipeline is byte-agnostic; decode is
    /// a later server-side concern.
    static func makeFrames(_ n: Int) -> [Data] {
        (0..<n).map { i in
            var d = Data([UInt8(i & 0xff)])
            d.append(contentsOf: (0..<39).map { _ in UInt8.random(in: 0...255) })
            return d
        }
    }

    static func make(world: CaptureWorld) -> [StepDefinition] {
        [
            defineStep("a running Foundry door") { ctx, _, _ in
                try world.reset(ctx); return ctx
            },
            defineStep("the door is unreachable") { ctx, _, _ in
                world.reachable = false; return ctx
            },
            defineStep("a capture WAL fed {int} replayed Opus frames") { ctx, p, _ in
                let n = try p.requireInt(0)
                let w = world.makeWAL()
                let src = ReplaySource(frames: makeFrames(n), interval: 0)
                src.onFrame = { [weak w] f in w?.appendFrame(f) }
                w.beginStreaming()
                src.start()       // queues N appends (io.async, FIFO)
                w.finish()        // barrier-flush all frames into segments; streaming=false
                return ctx
            },
            defineStep("the WAL syncs to the door") { ctx, _, _ in
                await world.wal?.sync(); return ctx
            },
            defineStep("the WAL syncs to the door again") { ctx, _, _ in
                await world.wal?.sync(); return ctx
            },
            defineStep("the door becomes reachable") { ctx, _, _ in
                world.reachable = true
                // Reconnect = a fresh WAL on the SAME dir with the now-good target
                // (target is immutable by design); it scanExisting's the pending
                // segments. Make it the ACTIVE wal so the next sync drains them.
                world.wal = world.makeWAL()
                return ctx
            },
            defineCheck("every segment is acknowledged and marked synced") { _, _, _ in
                guard let s = world.wal?.snapshot() else { throw CaptureTestError("no WAL") }
                guard s.totalSegments > 0 else { throw CaptureTestError("no segments (total=0)") }
                guard s.pendingSegments == 0, s.syncedSegments == s.totalSegments else {
                    throw CaptureTestError("not all synced: \(s.syncedSegments)/\(s.totalSegments)")
                }
                guard s.stage == .savedToComputer else {
                    throw CaptureTestError("stage \(s.stage) != savedToComputer")
                }
            },
            defineCheck("the door has the capture durably stored") { _, _, _ in
                // fsync-before-ACK on the door ⇒ synced==total IS proof the desktop
                // durably stored every segment (the 200 only comes after the fsync).
                guard let s = world.wal?.snapshot(),
                      s.totalSegments > 0, s.syncedSegments == s.totalSegments else {
                    throw CaptureTestError("door did not durably store all segments")
                }
            },
            defineCheck("the capture has unsynced segments") { _, _, _ in
                guard let s = world.wal?.snapshot(), s.pendingSegments > 0 else {
                    throw CaptureTestError("expected pending segments, got none")
                }
            },
        ]
    }
}

#endif  // os(macOS)
