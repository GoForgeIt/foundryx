import XCTest
import Foundation
import Network
import BrineSwiftCore
@testable import FoundryXKit

/// features/an-upload-names-where-it-sent-the-bytes.feature, driven against the REAL
/// `CaptureWAL` drain and the REAL brain seam.
///
/// The door scenario is not simulated: a listener is opened on this machine, the WAL is
/// given NO upload override at all, and the segment travels over a socket. That is the
/// only way to prove the `.door` route is DERIVED rather than declared — a test that
/// hands the WAL a closure and then asserts the WAL names a door is the shape of the
/// instrument that certified nine ACKs to nowhere.
final class UploadNamesItsDestinationFeatureTests: ProcessGlobalStateTestCase {

    func testUploadDestinationScenarios() async throws {
        let world = UploadDestinationWorld()
        let result = try await BrineFeatureRunner.run(
            "an-upload-names-where-it-sent-the-bytes",
            registry: StepRegistry(UploadDestinationSteps.make(world: world)))
        // An undefined step is not a pass: every scenario in the file must have RUN.
        XCTAssertEqual(result.passed, 5,
                       "every scenario in the feature must run and pass")
    }
}

// MARK: - A door that is really listening

/// The smallest thing that can honestly be called a door: it accepts a connection,
/// reads the request, answers the shape `/foundryx/capture` answers, and remembers how
/// many body bytes it was actually handed.
private final class LoopbackDoor: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var received: [Int] = []
    let port: UInt16

    init() throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        let box = Box()
        listener.newConnectionHandler = { [box] connection in
            connection.start(queue: .global())
            box.pump(connection)
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success,
              let p = listener.port?.rawValue else {
            throw BrineStepError("the loopback door never came up")
        }
        port = p
        box.owner = self
    }

    /// `newConnectionHandler` is set before `self` is fully initialised, so the handler
    /// closes over this box instead of over `self`.
    ///
    /// It reads until the DECLARED `Content-Length` has actually arrived. A door that
    /// answers 200 on the first packet — headers, usually, with the body still in
    /// flight — is an instrument that reports "received nothing" for a perfectly good
    /// upload, and it did exactly that here on the first run.
    fileprivate final class Box: @unchecked Sendable {
        weak var owner: LoopbackDoor?

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
                let lower = line.lowercased()
                guard lower.hasPrefix("content-length:") else { continue }
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
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
    var captureAddress: String { "http://127.0.0.1:\(port)/foundryx/capture" }

    func stop() { listener.cancel() }
}

// MARK: - The world

private final class UploadDestinationWorld: @unchecked Sendable {
    var baseDir: URL = FileManager.default.temporaryDirectory
    var captureId = ""
    var target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
    var log = DoorLog()
    var route: CaptureUploadRoute?
    var upload: (@Sendable (UInt64, Data) async throws -> Void)?
    var door: LoopbackDoor?
    /// The routes the SHIPPING brain seam gives each tier.
    var phoneOnlyRoute: CaptureUploadRoute??
    var realBrainRoute: CaptureUploadRoute??

    deinit { door?.stop() }

    func seedOneSegment() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-upload-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        captureId = "cap-\(UUID().uuidString.prefix(8))"
        let cdir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        try CaptureWAL.encodeSegment([Data([1, 2, 3, 4, 5, 6, 7, 8])])
            .write(to: cdir.appendingPathComponent(CaptureWAL.segName(0)))
    }

    func drain() async throws {
        let wal = CaptureWAL(captureId: captureId, target: target, baseDir: baseDir,
                             log: log, upload: upload, route: route)
        let outcome = await wal.sync()
        guard outcome == .progressed else {
            throw BrineStepError("the seeded segment did not upload: \(outcome)")
        }
        // `DoorLog.info` hops to the main queue when written off-main, which every WAL
        // upload is. Await the hop rather than reading a buffer nothing has appended to.
        let deadline = Date().addingTimeInterval(5)
        while (destinationLines.isEmpty || ackLines.isEmpty), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    var allLines: [String] { log.entries.map(\.text) }
    /// The ONE line a drain pass writes before it sends anything.
    var destinationLines: [String] { allLines.filter { $0.contains("uploading") && $0.contains("→") } }
    var ackLines: [String] { allLines.filter { $0.contains("ACK'd") } }
}

// MARK: - Steps

private enum UploadDestinationSteps {
    static func make(world w: UploadDestinationWorld) -> [StepDefinition] {
        [
            // MARK: Given

            defineStep("a capture pointed at a door that is really listening") { ctx, _, _ in
                let door = try LoopbackDoor()
                w.door = door
                w.target = DoorTarget(baseURL: door.baseURL, bearer: "x")
                w.log = DoorLog()
                // NO override and NO declared route: the WAL must work out for itself
                // that it is posting to a door, and really post.
                w.upload = nil
                w.route = nil
                try w.seedOneSegment()
                return ctx
            },

            defineStep("a capture on the phone-only brain, whose upload keeps the bytes here") { ctx, _, _ in
                // EXACTLY what `CaptureBackend`'s localMode ships: a closure that
                // succeeds by doing nothing, pointed at a loopback port nothing serves.
                w.target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
                w.log = DoorLog()
                w.upload = { @Sendable _, _ in }
                w.route = .thisPhoneOnly
                try w.seedOneSegment()
                return ctx
            },

            defineStep("a capture whose upload is a handler that names nothing") { ctx, _, _ in
                w.target = DoorTarget(baseURL: URL(string: "https://vault.example.dev")!, bearer: "x")
                w.log = DoorLog()
                w.upload = { @Sendable _, _ in }
                w.route = nil       // named nothing — the WAL must refuse to guess
                try w.seedOneSegment()
                return ctx
            },

            defineStep("the brain seam as the app actually ships it") { ctx, _, _ in
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("foundryx-brain-seam-\(UUID().uuidString)",
                                            isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x")
                let phoneOnly = await MainActor.run {
                    CaptureManager(target: target,
                                   backend: NoopBackend(),
                                   baseDir: dir,
                                   source: ReplaySource(frames: []),
                                   attachToSourcesImmediately: false,
                                   localMode: true).uploadRoute
                }
                let realBrain = await MainActor.run {
                    CaptureManager(target: target,
                                   backend: NoopBackend(),
                                   baseDir: dir,
                                   source: ReplaySource(frames: []),
                                   attachToSourcesImmediately: false,
                                   localMode: false).uploadRoute
                }
                w.phoneOnlyRoute = .some(phoneOnly)
                w.realBrainRoute = .some(realBrain)
                return ctx
            },

            // MARK: When

            defineStep("the capture drains") { ctx, _, _ in
                try await w.drain()
                return ctx
            },

            // MARK: Then

            defineCheck("the drain names its destination exactly once") { _, _, _ in
                try expect(w.destinationLines.count == 1,
                           "a drain pass must say where it is sending audio exactly once — "
                           + "logged \(w.destinationLines.count): \(w.destinationLines)")
            },

            defineCheck("the drain's destination line names that door's capture address") { _, _, _ in
                let address = try require(w.door?.captureAddress)
                try expect(w.destinationLines.allSatisfy { $0.contains(address) },
                           "the destination line does not name \(address): \(w.destinationLines)")
            },

            defineCheck("the ACK line names that door's capture address") { _, _, _ in
                let address = try require(w.door?.captureAddress)
                try expect(!w.ackLines.isEmpty, "no ACK line was logged at all")
                try expect(w.ackLines.allSatisfy { $0.contains(address) },
                           "an ACK line does not name \(address): \(w.ackLines)")
            },

            defineCheck("that door really received the bytes") { _, _, _ in
                let door = try require(w.door)
                let deadline = Date().addingTimeInterval(5)
                while door.bodiesReceived.isEmpty, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                try expect(!door.bodiesReceived.isEmpty,
                           "the door named in the log never received a request — the drain "
                           + "named an address it did not post to")
                try expect(door.bodiesReceived.contains { $0 > 0 },
                           "the door received a request carrying no body: \(door.bodiesReceived)")
            },

            defineCheck("the drain's destination line says the bytes stayed on this phone") { _, _, _ in
                try expect(!w.destinationLines.isEmpty, "no destination line was logged at all")
                try expect(w.destinationLines.allSatisfy {
                    $0.localizedCaseInsensitiveContains("this phone only")
                        && $0.localizedCaseInsensitiveContains("nothing was sent")
                }, "the destination line does not say the bytes stayed here: \(w.destinationLines)")
            },

            defineCheck("the ACK line says the bytes stayed on this phone") { _, _, _ in
                try expect(!w.ackLines.isEmpty, "no ACK line was logged at all")
                try expect(w.ackLines.allSatisfy {
                    $0.localizedCaseInsensitiveContains("this phone only")
                        && $0.localizedCaseInsensitiveContains("nothing was sent")
                }, "an ACK line does not say the bytes stayed here: \(w.ackLines)")
            },

            defineCheck("the drain's destination line says the ACK cannot be traced") { _, _, _ in
                try expect(!w.destinationLines.isEmpty, "no destination line was logged at all")
                try expect(w.destinationLines.allSatisfy {
                    $0.localizedCaseInsensitiveContains("cannot be traced")
                }, "the destination line claims a traceable place: \(w.destinationLines)")
            },

            defineCheck("no logged line claims the bytes reached a computer") { _, _, _ in
                for line in w.allLines {
                    try expect(!line.localizedCaseInsensitiveContains("computer")
                               && !line.localizedCaseInsensitiveContains("desktop"),
                               "a log line still claims a computer: \(line)")
                }
            },

            defineCheck("no logged line names the door address the capture was pointed at") { _, _, _ in
                let address = w.target.baseURL.absoluteString
                for line in w.allLines {
                    try expect(!line.contains(address),
                               "a log line borrows the address the bytes did NOT go to "
                               + "(\(address)): \(line)")
                }
            },

            defineCheck("a phone-only capture manager routes its uploads to this phone") { _, _, _ in
                let route = try require(w.phoneOnlyRoute)
                try expect(route == .thisPhoneOnly,
                           "the shipping phone-only brain does not name itself; it routes to "
                           + "\(String(describing: route))")
            },

            defineCheck("a capture manager with a real brain routes its uploads to the door") { _, _, _ in
                let route = try require(w.realBrainRoute)
                try expect(route == nil,
                           "a real brain must not carry an upload override route — it posts "
                           + "for real; it routes to \(String(describing: route))")
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

/// A brain that accepts everything and holds nothing — the capture seam is not what
/// these scenarios are about.
private struct NoopBackend: CaptureBackend {
    func finalize(captureId: String, meta: ConversationMeta?) async throws {}
    func captureStatus(captureId: String) async throws -> CaptureStatusResponse {
        throw DoorError.transport("no brain in this scenario")
    }
    func captureContent(captureId: String) async throws -> CaptureContent {
        throw DoorError.transport("no brain in this scenario")
    }
}
