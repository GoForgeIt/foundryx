import Foundation

public enum PocketOperation: String, Sendable, Equatable {
    case authentication, information, dateList, fileList, download, wifiControl
}

public enum PocketProtocolError: Error, Sendable, Equatable, CustomStringConvertible {
    case unauthenticated, busy, cancelled, malformedSecret, authenticationRejected
    case unsupportedProtocol, unsupportedOperation, malformedResponse
    case timeout(PocketOperation), stall, transportFailure, disconnected

    public var description: String {
        switch self {
        case .unauthenticated: "unauthenticated"
        case .busy: "busy"
        case .cancelled: "cancelled"
        case .malformedSecret: "malformed session secret"
        case .authenticationRejected: "authentication rejected"
        case .unsupportedProtocol: "unsupported protocol"
        case .unsupportedOperation: "unsupported operation"
        case .malformedResponse: "malformed response"
        case .timeout(let operation): "\(operation.rawValue) timed out"
        case .stall: "download stalled"
        case .transportFailure: "transport failure"
        case .disconnected: "disconnected"
        }
    }
}

public enum PocketTransportFailure: Error, Sendable { case timeout, stall, disconnected, other }

/// Typed, provenance-labeled WiFi controls. Their wire values come from the reference trace;
/// availability on a stock firmware family is not inferred from this enum or from CI fakes.
public enum PocketWiFiCommand: Sendable, Equatable {
    case initialize
    case credentials
    case enable
    case status
    case select(PocketRecordingRequest)
    case beginTransfer
    case close

    fileprivate var wireValue: String {
        switch self {
        case .initialize: "U&WIFI"
        case .credentials: "WIFI"
        case .enable: "WIFIO"
        case .status: "WIFIS"
        case .select(let request): "U&\(request.date)&\(request.timestamp)"
        case .beginTransfer: "U&WIFI"
        case .close: "WIFIC"
        }
    }
}

public enum PocketTransportEvent: Sendable {
    case control(Data, generation: UInt64)
    case audio(Data, generation: UInt64)
}

public protocol PocketBLETransport: Sendable {
    func availableCharacteristics() async throws -> Set<String>
    func write(_ data: Data, to characteristic: String) async throws
    func nextEvent(generation: UInt64) async throws -> PocketTransportEvent
    func close() async
}

public struct PocketCharacteristicMap: Sendable, Equatable {
    public let command: String
    public let control: String
    public let audio: String
    public var required: Set<String> { [command, control, audio] }

    public static let primary = PocketCharacteristicMap(command: "001120a3", control: "001120a3", audio: "001120a1")
    public static let fallback = PocketCharacteristicMap(command: "e49a3002", control: "e49a3003", audio: "e49a28e1")
}

public struct PocketStorage: Sendable, Equatable {
    public let usedKilobytes: Int
    public let capacityKilobytes: Int
    public init(usedKilobytes: Int, capacityKilobytes: Int) {
        self.usedKilobytes = usedKilobytes; self.capacityKilobytes = capacityKilobytes
    }
}

public enum PocketField<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case failure(PocketProtocolError)
}

public struct PocketDeviceInfo: Sendable, Equatable {
    public let battery: PocketField<Int>
    public let firmware: PocketField<String>
    public let storage: PocketField<PocketStorage>
    public let state: PocketField<Int>
}

/// The protocol request tuple. It is deliberately not `Identifiable`: T1 makes no durable
/// identity claim for the pair.
public struct PocketRecordingRequest: Sendable, Equatable {
    public let date: String
    public let timestamp: String
    public init(date: String, timestamp: String) { self.date = date; self.timestamp = timestamp }
}

public struct PocketRecording: Sendable, Equatable {
    public let date: String
    public let timestamp: String
    public let sizeBytes: Int
    public var durationSeconds: Double { Double(sizeBytes) / 4_000 }
    public init(date: String, timestamp: String, sizeBytes: Int) {
        self.date = date; self.timestamp = timestamp; self.sizeBytes = sizeBytes
    }
    public var request: PocketRecordingRequest { .init(date: date, timestamp: timestamp) }
}

public actor PocketBLEClient {
    public typealias DiagnosticSink = @Sendable (String) async -> Void

    private let transport: any PocketBLETransport
    public let characteristicMap: PocketCharacteristicMap
    private let diagnostics: DiagnosticSink
    private var generation: UInt64 = 1
    private var authenticated = false
    private var retainedSecret: [UInt8]?
    private var operationInFlight = false
    private var retired = false

    private init(transport: any PocketBLETransport, map: PocketCharacteristicMap, diagnostics: @escaping DiagnosticSink) {
        self.transport = transport; characteristicMap = map; self.diagnostics = diagnostics
    }

    public static func connect(
        transport: any PocketBLETransport,
        diagnostics: @escaping DiagnosticSink = { _ in }
    ) async throws -> PocketBLEClient {
        let available: Set<String>
        do { available = try await transport.availableCharacteristics() }
        catch { throw PocketProtocolError.transportFailure }
        let map: PocketCharacteristicMap
        if available.isSuperset(of: PocketCharacteristicMap.primary.required) { map = .primary }
        else if available.isSuperset(of: PocketCharacteristicMap.fallback.required) { map = .fallback }
        else { throw PocketProtocolError.unsupportedProtocol }
        return PocketBLEClient(transport: transport, map: map, diagnostics: diagnostics)
    }

    /// TRUE ONLY WHILE THIS CLIENT IS HOLDING THE ACTUAL BYTES.
    ///
    /// It used to read `retainedSecret != nil`, which nil-ness alone can satisfy — and
    /// nil-ness alone is what the old wipe achieved. `if var bytes = retainedSecret { bytes
    /// .resetBytes(…) }` binds a COPY of the array struct; mutating it triggers copy-on-write,
    /// allocates a fresh buffer, and zeroes THAT. The original buffer, still holding the
    /// sixteen plaintext characters, was then released to the allocator untouched. Measured:
    /// original at 0x…df70, the copy the wipe zeroed at 0x…e540.
    ///
    /// So this asks the question that mutation can fail: are the bytes ZERO. Reintroducing the
    /// copy-on-write wipe turns this back to `true` and the secret-privacy check goes red.
    public var hasRetainedSecretForTesting: Bool {
        retainedSecret?.contains { $0 != 0 } ?? false
    }

    /// The current transport generation, so a test can prove `retire()` actually
    /// advanced it. Without this the staleness filter had no coverage at all: a
    /// verifier deleted `generation &+= 1` AND the `eventGeneration == generation`
    /// checks and all 14 scenarios still passed, because the fake transport echoed
    /// back whatever generation it was handed. The mechanism must be observable to
    /// be provable.
    public var generationForTesting: UInt64 { generation }

    public func close() async {
        await retire(reason: "session closed")
    }

    public func authenticate(secret: String?) async throws {
        guard !operationInFlight else { throw PocketProtocolError.busy }
        guard !retired else { throw PocketProtocolError.disconnected }
        guard let secret, secret.unicodeScalars.allSatisfy({ $0.isASCII }), secret.utf8.count == 16 else {
            throw PocketProtocolError.malformedSecret
        }
        operationInFlight = true
        retainedSecret = Array(secret.utf8)
        defer { operationInFlight = false }
        do {
            try await write("SK&" + secret)
            let response = try await nextControl(operation: .authentication)
            guard response == "MCU&SK&OK" else {
                wipeRetainedSecret()
                if response == "MCU&UNKNOWN" { throw PocketProtocolError.unsupportedOperation }
                throw PocketProtocolError.authenticationRejected
            }
            authenticated = true
            await diagnostics("protocol authentication succeeded")
        } catch {
            if error is CancellationError || (error as? PocketProtocolError) == .cancelled {
                await retire(reason: "operation cancelled"); throw PocketProtocolError.cancelled
            }
            let mapped = mapError(error, operation: .authentication)
            if mapped == .timeout(.authentication) || mapped == .disconnected || mapped == .transportFailure {
                await retire(reason: "authentication transport invalidated")
            } else { wipeRetainedSecret(); authenticated = false }
            throw mapped
        }
    }

    public func batteryLevel() async throws -> Int { try await scalar(command: "BAT", prefix: "MCU&BAT&", operation: .information) }
    public func firmwareVersion() async throws -> String {
        try await protected(.information) {
            try await write("FW")
            let value = try await matchingValue(prefix: "MCU&FW&", operation: .information)
            guard !value.isEmpty else { throw PocketProtocolError.malformedResponse }
            return value
        }
    }
    public func storage() async throws -> PocketStorage {
        try await protected(.information) {
            try await write("SPACE")
            let value = try await matchingValue(prefix: "MCU&SPA&", operation: .information).split(separator: "&", omittingEmptySubsequences: false)
            guard value.count == 2, let used = Int(value[0]), let total = Int(value[1]), used >= 0, total >= 0 else { throw PocketProtocolError.malformedResponse }
            return PocketStorage(usedKilobytes: used, capacityKilobytes: total)
        }
    }
    public func deviceState() async throws -> Int { try await scalar(command: "STE", prefix: "MCU&STE&", operation: .information) }

    /// THE READ-BACK THAT TURNS AN ACK INTO EVIDENCE.
    ///
    /// `APP&WIFI` asks the recorder for its own access-point credentials. The password it
    /// reports is derived from the session key the recorder is HOLDING — so a recorder that
    /// answered `MCU&SK&OK` to our write and then went on using somebody else's key reports
    /// somebody else's password, and cannot fake ours.
    ///
    /// It is a plain information read on the authenticated session, deliberately NOT part of
    /// `prepare(_:)`'s WiFi bring-up sequence: nothing here enables the radio, joins anything,
    /// or takes the recorder off Bluetooth. `.unsupportedOperation` on `MCU&UNKNOWN` is what a
    /// firmware without the command earns, and the caller must treat that as "not proven"
    /// rather than as "not accepted".
    public func accessPointCredentials() async throws -> PocketAccessPointReadback {
        try await protected(.information) {
            try await write("WIFI")
            let response = try await nextControl(operation: .information)
            if response == "MCU&UNKNOWN" { throw PocketProtocolError.unsupportedOperation }
            guard let readback = PocketAccessPointReadback.parse(response) else {
                throw PocketProtocolError.malformedResponse
            }
            return readback
        }
    }

    public func deviceInfo() async -> PocketDeviceInfo {
        let battery = await field { try await batteryLevel() }
        let firmware = await field { try await firmwareVersion() }
        let storage = await field { try await self.storage() }
        let state = await field { try await deviceState() }
        return PocketDeviceInfo(battery: battery, firmware: firmware, storage: storage, state: state)
    }

    public func listDates() async throws -> [String] {
        try await protected(.dateList) {
            try await write("LIST_DIRS")
            var dates: [String] = []
            while true {
                let response = try await nextControl(operation: .dateList)
                if response == "MCU&UNKNOWN" { throw PocketProtocolError.unsupportedOperation }
                if response.hasPrefix("MCU&DIRS&") {
                    let date = String(response.dropFirst("MCU&DIRS&".count))
                    guard validToken(date) else { throw PocketProtocolError.malformedResponse }
                    dates.append(date); continue
                }
                if response.hasPrefix("MCU&DIRS_SUM&"), let count = Int(response.dropFirst("MCU&DIRS_SUM&".count)), count == dates.count { return dates }
                throw PocketProtocolError.malformedResponse
            }
        }
    }

    public func listRecordings(on requestedDate: String) async throws -> [PocketRecording] {
        guard validToken(requestedDate) else { throw PocketProtocolError.malformedResponse }
        return try await protected(.fileList) {
            try await write("LIST&\(requestedDate)")
            var recordings: [PocketRecording] = []
            while true {
                let response = try await nextControl(operation: .fileList)
                if response == "MCU&UNKNOWN" { throw PocketProtocolError.unsupportedOperation }
                if response.hasPrefix("MCU&F&") {
                    let parts = response.split(separator: "&", omittingEmptySubsequences: false)
                    guard parts.count == 5, parts[0] == "MCU", parts[1] == "F",
                          validToken(String(parts[2])), validToken(String(parts[3])),
                          let size = Int(parts[4]), size >= 0 else { throw PocketProtocolError.malformedResponse }
                    recordings.append(.init(date: String(parts[2]), timestamp: String(parts[3]), sizeBytes: size)); continue
                }
                if response.hasPrefix("MCU&LIST&"), let count = Int(response.dropFirst("MCU&LIST&".count)), count == recordings.count { return recordings }
                throw PocketProtocolError.malformedResponse
            }
        }
    }

    public func download(_ request: PocketRecordingRequest) async throws -> Data {
        guard validToken(request.date), validToken(request.timestamp) else { throw PocketProtocolError.malformedResponse }
        return try await protected(.download) {
            try await write("U&\(request.date)&\(request.timestamp)")
            let announced = try await matchingValue(prefix: "MCU&U&", operation: .download)
            guard let size = Int(announced), size > 0 else { throw PocketProtocolError.malformedResponse }
            var bytes = Data()
            while bytes.count < size {
                let event = try await nextEvent(operation: .download)
                guard case .audio(let chunk, let eventGeneration) = event, eventGeneration == generation else { continue }
                bytes.append(chunk)
            }
            guard let sync = bytes.firstMP3Sync else { throw PocketProtocolError.malformedResponse }
            return bytes.subdata(in: sync..<bytes.endIndex)
        }
    }

    /// T5's typed extension point. Commands remain serialized by this client's authenticated
    /// session and generation rules; callers never receive a raw-command escape hatch.
    /// The transcript is reference-derived and must remain behind E-WIFI-CONTROL in production.
    public func performReferenceWiFiCommand(_ command: PocketWiFiCommand) async throws -> String {
        try await protected(.wifiControl) {
            try await write(command.wireValue)
            return try await nextControl(operation: .wifiControl)
        }
    }

    private func scalar(command: String, prefix: String, operation: PocketOperation) async throws -> Int {
        try await protected(operation) {
            try await write(command)
            guard let number = Int(try await matchingValue(prefix: prefix, operation: operation)), number >= 0 else { throw PocketProtocolError.malformedResponse }
            return number
        }
    }

    private func protected<T: Sendable>(_ operation: PocketOperation, body: () async throws -> T) async throws -> T {
        guard !operationInFlight else { throw PocketProtocolError.busy }
        guard authenticated, !retired else { throw PocketProtocolError.unauthenticated }
        operationInFlight = true
        defer { operationInFlight = false }
        do { return try await body() }
        catch {
            let mapped: PocketProtocolError
            if error is CancellationError { mapped = .cancelled } else { mapped = mapError(error, operation: operation) }
            if [.cancelled, .disconnected, .transportFailure, .stall].contains(mapped) || mapped == .timeout(operation) {
                await retire(reason: "\(operation.rawValue) transport invalidated")
            }
            throw mapped
        }
    }

    private func matchingValue(prefix: String, operation: PocketOperation) async throws -> String {
        let response = try await nextControl(operation: operation)
        if response == "MCU&UNKNOWN" { throw PocketProtocolError.unsupportedOperation }
        guard response.hasPrefix(prefix) else { throw PocketProtocolError.malformedResponse }
        return String(response.dropFirst(prefix.count))
    }

    private func nextControl(operation: PocketOperation) async throws -> String {
        while true {
            let event = try await nextEvent(operation: operation)
            guard case .control(let data, let eventGeneration) = event, eventGeneration == generation else { continue }
            guard let text = String(data: data, encoding: .ascii) else { throw PocketProtocolError.malformedResponse }
            return text
        }
    }

    private func nextEvent(operation: PocketOperation) async throws -> PocketTransportEvent {
        do {
            try Task.checkCancellation()
            let event = try await transport.nextEvent(generation: generation)
            try Task.checkCancellation()
            return event
        } catch { throw mapError(error, operation: operation) }
    }

    private func write(_ command: String) async throws {
        do { try await transport.write(Data("APP&\(command)".utf8), to: characteristicMap.command) }
        catch { throw PocketProtocolError.transportFailure }
    }

    private func retire(reason: String) async {
        guard !retired else { return }
        generation &+= 1; retired = true; authenticated = false
        wipeRetainedSecret()
        await transport.close()
        await diagnostics(reason)
    }

    /// OVERWRITE IN PLACE, THEN KEEP THE BUFFER.
    ///
    /// Two things are deliberate. Mutating `retainedSecret` THROUGH the stored property —
    /// rather than through a `var` copy — is what makes the wipe reach the live buffer instead
    /// of a copy-on-write duplicate of it. And not niling afterwards is what leaves the wipe
    /// OBSERVABLE: `retainedSecret = nil` would drop the sixteen bytes onto the free list and
    /// leave every possible assertion unable to tell a real wipe from a dropped reference.
    /// Sixteen zero bytes cost nothing to keep and are the proof.
    private func wipeRetainedSecret() {
        guard retainedSecret != nil else { return }
        for index in retainedSecret!.indices { retainedSecret![index] = 0 }
    }

    private func mapError(_ error: Error, operation: PocketOperation) -> PocketProtocolError {
        if let error = error as? PocketProtocolError { return error }
        if error is CancellationError { return .cancelled }
        switch error as? PocketTransportFailure {
        case .timeout: return .timeout(operation)
        case .stall: return .stall
        case .disconnected: return .disconnected
        case .other, .none: return .transportFailure
        }
    }

    private func field<T: Sendable & Equatable>(_ body: () async throws -> T) async -> PocketField<T> {
        do { return .value(try await body()) }
        catch let error as PocketProtocolError { return .failure(error) }
        catch { return .failure(.transportFailure) }
    }
}

extension PocketBLEClient: PocketFastSyncControlling {
    public func prepare(_ request: PocketRecordingRequest) async throws {
        guard try await performReferenceWiFiCommand(.initialize) == "MCU&WIFIS&0" else { throw PocketProtocolError.malformedResponse }
        guard try await performReferenceWiFiCommand(.credentials).hasPrefix("MCU&WIFI&") else { throw PocketProtocolError.malformedResponse }
        guard try await performReferenceWiFiCommand(.enable) == "MCU&WIFIO" else { throw PocketProtocolError.malformedResponse }
        var ready = false
        for _ in 0..<3 where !ready { ready = try await performReferenceWiFiCommand(.status) == "MCU&WIFIS&1" }
        guard ready else { throw PocketProtocolError.malformedResponse }
        guard try await performReferenceWiFiCommand(.select(request)).hasPrefix("MCU&U&") else { throw PocketProtocolError.malformedResponse }
        guard try await performReferenceWiFiCommand(.beginTransfer) == "MCU&U&WIFI" else { throw PocketProtocolError.malformedResponse }
    }

    public func cleanup() async { _ = try? await performReferenceWiFiCommand(.close) }
}

private func validToken(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.unicodeScalars.allSatisfy {
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
    }
}

private extension Data {
    var firstMP3Sync: Index? {
        guard count >= 2 else { return nil }
        for index in indices.dropLast() where self[index] == 0xff && self[index + 1] == 0xf3 { return index }
        return nil
    }
}
