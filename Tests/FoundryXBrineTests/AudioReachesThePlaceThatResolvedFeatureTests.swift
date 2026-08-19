import XCTest
import Foundation
import Network
import BrineSwiftCore
@testable import FoundryXKit

/// features/omi-audio-reaches-the-place-that-resolved.feature, driven against the REAL
/// `RootGate`, the REAL `CaptureWAL` drain and the REAL `BrainSeeder`.
///
/// The "really listening" destination is not simulated: a listener is opened on this
/// machine and the segment travels over a socket. A test that hands the WAL a closure and
/// then asserts the bytes arrived is the shape of the instrument that certified 22,358
/// segments to nowhere.
final class AudioReachesThePlaceThatResolvedFeatureTests: ProcessGlobalStateTestCase {

    func testAudioReachesThePlaceThatResolvedScenarios() async throws {
        let world = ResolvedPlaceWorld()
        let result = try await BrineFeatureRunner.run(
            "omi-audio-reaches-the-place-that-resolved",
            registry: StepRegistry(ResolvedPlaceSteps.make(world: world)))
        // An undefined step is not a pass: every scenario in the file must have RUN.
        XCTAssertEqual(result.passed, 5,
                       "every scenario in the feature must run and pass")
    }
}

// MARK: - A destination that is really listening

/// The smallest thing that can honestly be called a destination: it accepts a
/// connection, reads the whole declared body, answers the shape `/foundryx/capture`
/// answers, and remembers how many body bytes it was actually handed.
private final class ListeningDestination: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var received: [Int] = []
    let port: UInt16

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let box = Box()
        listener.newConnectionHandler = { [box] connection in
            connection.start(queue: .global())
            box.pump(connection)
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success,
              let p = listener.port?.rawValue else {
            throw BrineStepError("the listening destination never came up")
        }
        port = p
        box.owner = self
    }

    fileprivate final class Box: @unchecked Sendable {
        weak var owner: ListeningDestination?

        func pump(_ connection: NWConnection, accumulated: Data = Data()) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                guard let split = Self.headerEnd(in: buffer) else {
                    if isComplete || error != nil { connection.cancel() }
                    else { self.pump(connection, accumulated: buffer) }
                    return
                }
                let headers = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
                let declared = Self.contentLength(in: headers) ?? 0
                let bodySoFar = buffer.count - split.upperBound
                if bodySoFar < declared, !isComplete, error == nil {
                    self.pump(connection, accumulated: buffer)
                    return
                }
                self.owner?.record(bodySoFar)
                let body = #"{"capture_id":"x","seq":0,"stored":true,"bytes":\#(bodySoFar),"segments":1}"#
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        private static func headerEnd(in buffer: Data) -> Range<Int>? {
            let marker = Data("\r\n\r\n".utf8)
            guard buffer.count >= marker.count else { return nil }
            for i in 0...(buffer.count - marker.count) {
                if buffer[buffer.startIndex + i ..< buffer.startIndex + i + marker.count] == marker {
                    return i ..< (i + marker.count)
                }
            }
            return nil
        }

        private static func contentLength(in headers: String) -> Int? {
            for line in headers.split(separator: "\r\n") {
                guard line.lowercased().hasPrefix("content-length:") else { continue }
                return Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }

    private func record(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        received.append(bytes)
    }

    var bodiesReceived: [Int] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func stop() { listener.cancel() }
}

// MARK: - The world

private final class ResolvedPlaceWorld: @unchecked Sendable {
    // The gate scenarios.
    var brain: BrainChoice = .myComputer
    var hostResolved = false
    var cellPaired = false
    var resolved: CaptureDestination?

    // The drain scenarios.
    var baseDir = FileManager.default.temporaryDirectory
    var captureId = ""
    var target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    var log = DoorLog()
    var route: CaptureUploadRoute?
    var upload: (@Sendable (UInt64, Data) async throws -> Void)?
    var destination: ListeningDestination?
    /// The watermark read straight off the WAL after the most recent drain.
    var watermarkAfterDrain: Int64 = .min

    // The re-arm scenario.
    var rearmed = 0

    deinit { destination?.stop() }

    func seedOneSegment() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-resolved-place-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        captureId = "omi-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        try CaptureWAL.encodeSegment([Data([1, 2, 3, 4, 5, 6, 7, 8])])
            .write(to: captureDir.appendingPathComponent(CaptureWAL.segName(0)))
    }

    var captureDir: URL { baseDir.appendingPathComponent(captureId, isDirectory: true) }

    /// Every marker file this capture carries, by extension.
    func markerExtensions() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: captureDir,
                                                       includingPropertiesForKeys: nil)) ?? [])
            .map(\.pathExtension)
    }

    func drain() async throws {
        let wal = CaptureWAL(captureId: captureId, target: target, baseDir: baseDir,
                             log: log, upload: upload, route: route)
        let outcome = await wal.sync()
        guard outcome == .progressed else {
            throw BrineStepError("the seeded segment did not drain: \(outcome)")
        }
        watermarkAfterDrain = wal.uploadWatermark()
    }
}

// MARK: - Steps

private enum ResolvedPlaceSteps {
    static func make(world w: ResolvedPlaceWorld) -> [StepDefinition] {
        [
            // MARK: Given — the gate

            defineStep("a signed-in owner who chose their computer as the brain") { ctx, _, _ in
                w.brain = .myComputer
                return ctx
            },

            defineStep("that computer's host does not resolve") { ctx, _, _ in
                w.hostResolved = false
                return ctx
            },

            defineStep("a vault that is paired") { ctx, _, _ in
                w.cellPaired = true
                return ctx
            },

            defineStep("no vault that is paired") { ctx, _, _ in
                w.cellPaired = false
                return ctx
            },

            // MARK: Given — the drain

            defineStep("a capture whose upload keeps the bytes on this phone") { ctx, _, _ in
                // EXACTLY what `CaptureBackend`'s localMode ships: a closure that succeeds
                // by doing nothing, pointed at a loopback port nothing serves.
                w.target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
                w.log = DoorLog()
                w.upload = { @Sendable _, _ in }
                w.route = .thisPhoneOnly
                try w.seedOneSegment()
                return ctx
            },

            defineStep("the capture drains") { ctx, _, _ in
                try await w.drain()
                return ctx
            },

            // MARK: Given — the re-arm

            defineStep("a recording the phone kept and self-ACK'd before this fix shipped") { ctx, _, _ in
                try w.seedOneSegment()
                // The on-disk shape a pre-fix phone-only drain left behind: a real-looking
                // `.ack` marker and a watermark advanced past the only segment.
                let seg = w.captureDir.appendingPathComponent(CaptureWAL.segName(0))
                try Data().write(to: seg.deletingPathExtension().appendingPathExtension("ack"))
                try Data("0".utf8).write(
                    to: w.captureDir.appendingPathComponent(".upload-watermark"))
                return ctx
            },

            // MARK: When

            defineStep("the app resolves where a recording goes") { ctx, _, _ in
                w.resolved = RootGate.destination(signedIn: true,
                                                  splashElapsed: true,
                                                  brain: w.brain,
                                                  hostResolved: w.hostResolved,
                                                  letStraightIn: true,
                                                  cellPaired: w.cellPaired)
                    .captureDestination
                return ctx
            },

            defineStep("a destination that is really listening resolves and the capture drains again") { ctx, _, _ in
                let live = try ListeningDestination()
                w.destination = live
                w.target = DoorTarget(baseURL: live.baseURL, bearer: "x")
                // A REAL destination: no override and no declared route, so the WAL must
                // work out for itself that it is posting to a door, and really post.
                w.upload = nil
                w.route = nil
                try await w.drain()
                return ctx
            },

            defineStep("the owner connects a vault") { ctx, _, _ in
                guard BrainSeeder.rearmsOnConnecting(.foundryCloud) else {
                    // Not an XCTFail: the check step below is what reports, so a gate that
                    // refuses to re-arm reaches it as zero re-armed captures.
                    w.rearmed = 0
                    return ctx
                }
                w.rearmed = BrainSeeder.rearmForDoorSeed(baseDir: w.baseDir)
                return ctx
            },

            // MARK: Then

            defineCheck("the recording goes to the vault") { _, _, _ in
                try expect(w.resolved == .vault,
                           "a paired vault is a place this recording can reach, but the app "
                           + "resolved \(String(describing: w.resolved))")
            },

            defineCheck("the recording does not go to this phone only") { _, _, _ in
                try expect(w.resolved != .phone,
                           "the app degraded past a reachable vault to the tier whose "
                           + "uploads are self-issued ACKs")
            },

            defineCheck("the recording goes to this phone only") { _, _, _ in
                try expect(w.resolved == .phone,
                           "with no computer and no vault there is nowhere else to go, but "
                           + "the app resolved \(String(describing: w.resolved))")
            },

            defineCheck("the durable upload watermark has not moved") { _, _, _ in
                try expect(w.watermarkAfterDrain == -1,
                           "a route that sent nothing advanced the durable resume point to "
                           + "\(w.watermarkAfterDrain) — past it, these bytes are never "
                           + "re-sent, which is what made 22,358 segments unrecoverable")
            },

            defineCheck("no segment carries an ACK marker") { _, _, _ in
                let markers = w.markerExtensions()
                // ANTI-VACUITY. "No ACK marker" is trivially true of a capture with no
                // segment and of a drain that never ran, and either would let this check
                // certify the exact defect it exists to catch. The segment and the HOLD
                // must both be on disk before the absence of an ACK means anything.
                try expect(markers.contains("opus"),
                           "no segment was ever written — this check would pass on an "
                           + "empty capture: \(markers)")
                try expect(markers.contains("held"),
                           "the drain recorded nothing at all, so 'no ACK' is vacuous — "
                           + "a route that keeps the bytes must still account for them "
                           + "on this phone: \(markers)")
                let acks = markers.filter { $0 == "ack" }
                try expect(acks.isEmpty,
                           "a route that sent nothing wrote \(acks.count) durable ACK "
                           + "marker(s) — an ACK is a claim that another place has the bytes")
            },

            defineCheck("that destination really received the bytes") { _, _, _ in
                let live = try require(w.destination)
                let deadline = Date().addingTimeInterval(5)
                while live.bodiesReceived.isEmpty, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(!live.bodiesReceived.isEmpty,
                           "the audio the phone had kept was never re-sent once a real "
                           + "destination resolved — a later backfill cannot find it")
                try expect(live.bodiesReceived.contains { $0 > 0 },
                           "the destination received a request carrying no body: "
                           + "\(live.bodiesReceived)")
            },

            defineCheck("the durable upload watermark has moved") { _, _, _ in
                try expect(w.watermarkAfterDrain == 0,
                           "a real destination ACK'd the segment, so the resume point must "
                           + "move; it is \(w.watermarkAfterDrain)")
            },

            defineCheck("that recording is re-armed for upload") { _, _, _ in
                try expect(w.rearmed == 1,
                           "connecting a vault re-armed \(w.rearmed) recording(s) — the "
                           + "audio stranded by a self-issued ACK is only recoverable if "
                           + "connecting ANY real brain re-arms it, not just a computer")
            },
        ]
    }
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw BrineStepError(message) }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw BrineStepError("a required value was never set up") }
    return value
}
