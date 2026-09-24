import Foundation
import CryptoKit
import Security

// Phone-side host resolution (M5 R1b). After sign-in, ask the hosted gateway
// "which desktop is my account's host?" (GET /host/resolve, bearer = the verified
// provider id_token) and assemble the RelayConfig the phone dials: the relay WS
// URL + the resolved per-host tunnel id + the phone's durable Noise static key.
//
// NOT YET COMPILE-VERIFIED in CI — validate in Xcode.

public struct RemoteConfig: Sendable {
    /// Host-registry control plane, e.g. "https://relay.example.com:8788".
    public let gatewayHTTPURL: URL
    /// Blind relay WS endpoint, e.g. "wss://relay.example.com:8787".
    public let relayWSURL: URL

    public init(gatewayHTTPURL: URL, relayWSURL: URL) {
        self.gatewayHTTPURL = gatewayHTTPURL
        self.relayWSURL = relayWSURL
    }

    /// Read from the app's Info.plist `FoundryXOAuth` dict (GatewayHTTPURL +
    /// RelayWSURL). Returns nil when remote isn't configured for this build.
    public static func fromBundle(_ bundle: Bundle = .main) -> RemoteConfig? {
        let dict = bundle.object(forInfoDictionaryKey: "FoundryXOAuth") as? [String: Any] ?? [:]
        guard let g = (dict["GatewayHTTPURL"] as? String).flatMap(URL.init(string:)),
              let r = (dict["RelayWSURL"] as? String).flatMap(URL.init(string:)) else {
            return nil
        }
        return RemoteConfig(gatewayHTTPURL: g, relayWSURL: r)
    }
}

public enum HostResolveError: Error, LocalizedError {
    case noHostDesignated
    case http(Int, String)
    case badResponse
    /// The gateway named a host whose `machine_id` is not a usable door key, so
    /// there is nothing to pin. Carries the reason for the log; the person is told
    /// the machine could not be verified. This is a REFUSAL, not a degraded
    /// connection: an unpinnable host is exactly the shape a rogue door presents.
    case hostCannotBePinned(String)

    public var errorDescription: String? {
        switch self {
        case .noHostDesignated: return "No desktop is designated as your host yet — open Solleva on your Mac and press “Make this machine the host”."
        case .http(let c, let b): return "Host lookup failed (\(c)): \(b)"
        case .badResponse: return "Unexpected response from the gateway"
        case .hostCannotBePinned(let why): return "Your Mac's identity could not be verified, so Solleva will not connect to it (\(why)). Open Solleva on your Mac and press “Make this machine the host” again."
        }
    }
}

public struct HostResolver: Sendable {
    let remote: RemoteConfig
    let log: DoorLog?

    public init(remote: RemoteConfig, log: DoorLog? = .shared) {
        self.remote = remote
        self.log = log
    }

    /// The characters a `machine_id` may be spelled with. Lowercase only, on purpose —
    /// see `doorStaticKey(fromMachineId:)`.
    private static let machineIdAlphabet = Set("0123456789abcdef")

    /// The door's X25519 static public key, decoded from the `machine_id` the gateway
    /// named — or a REFUSAL.
    ///
    /// This replaces `hexToData`, which returned `nil` for anything it could not decode
    /// and left the caller to decide what `nil` meant. The caller decided it meant "no
    /// pin", which is how a missing `machine_id` became an unpinned dial. There is no
    /// `nil` here: every way an answer fails to be a door key is a thrown refusal that
    /// names itself.
    ///
    /// What it accepts is exactly one spelling of exactly one thing: 64 LOWERCASE hex
    /// characters, which decode to the 32 bytes of an X25519 public key.
    ///
    /// * **not 64 characters** — a shorter even-length string used to decode happily
    ///   into a short "pin" that could never equal a 32-byte key. That is a pin that
    ///   only ever refuses: a broken connect wearing the costume of a control.
    /// * **uppercase** — `machine_id_from_static_key` emits lowercase (it is literally
    ///   `hex(public)`), and the host registry treats a differently-spelled id as a
    ///   DIFFERENT id. Normalising the spelling here would let the phone pin against an
    ///   id the registry never issued, so the client refuses the spelling rather than
    ///   repairing it.
    static func doorStaticKey(fromMachineId value: Any?) throws -> Data {
        guard let value else {
            throw HostResolveError.hostCannotBePinned("the gateway named a host with no machine_id")
        }
        guard let hex = value as? String else {
            throw HostResolveError.hostCannotBePinned("the gateway's machine_id is not text")
        }
        guard hex.count == 64 else {
            throw HostResolveError.hostCannotBePinned("the gateway's machine_id is \(hex.count) characters; a door key is 64")
        }
        guard hex.allSatisfy({ machineIdAlphabet.contains($0) }) else {
            throw HostResolveError.hostCannotBePinned("the gateway's machine_id is not lowercase hexadecimal")
        }
        var out = Data(capacity: 32)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                throw HostResolveError.hostCannotBePinned("the gateway's machine_id is not lowercase hexadecimal")
            }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Resolve the account's designated host and build the RelayConfig to dial it.
    /// `idToken` is the verified provider id_token (the gateway derives the account
    /// from it). Throws `noHostDesignated` when the account has no host yet.
    public func resolveRelayConfig(idToken: String) async throws -> RelayConfig {
        var req = URLRequest(url: remote.gatewayHTTPURL.appendingPathComponent("host/resolve"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HostResolveError.badResponse }
        if http.statusCode == 404 { throw HostResolveError.noHostDesignated }
        guard (200..<300).contains(http.statusCode) else {
            throw HostResolveError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tunnel = obj["tunnel_id"] as? String else {
            throw HostResolveError.badResponse
        }
        // PIN the door's static key: the resolved `machine_id` IS the door's X25519
        // public key (hex) — `machine_id_from_static_key()` in foundryx-tunnel is
        // literally `hex(public)`. Pinning it means a rogue door that registered
        // under this tunnel fails the Noise handshake, which is why the relay can
        // ship OPEN door registration.
        //
        // THAT ARGUMENT ONLY HOLDS IF THE PIN CANNOT BE SKIPPED, and it could:
        // `machine_id ?? ""` fed `hexToData`, which returns nil on the empty string,
        // and both consumers tested the result with `if let`. One absent field in a
        // resolve response therefore disabled channel authentication silently and
        // the phone completed a Noise handshake with any door. So an unpinnable host
        // is now a REFUSAL rather than an unpinned connection.
        //
        // Refusing costs nothing legitimate: `HostRecord.machine_id` is a
        // non-optional String on the relay (since a16df59d, 2026-08-07 — older than
        // the deployed binary), and no relay path constructs an empty one. A host
        // that cannot be pinned is malformed or hostile, not merely old.
        let expectedDoor = try Self.doorStaticKey(fromMachineId: obj["machine_id"])
        log?.info("resolved host tunnel=\(tunnel) label=\((obj["label"] as? String) ?? "?") pinned=yes")
        return RelayConfig(
            relayURL: remote.relayWSURL,
            tunnelId: tunnel,
            staticPrivate: PhoneStaticKey.loadOrCreate(),
            expectedDoorStatic: expectedDoor
        )
    }
}

/// The phone's durable X25519 Noise static private key (its initiator identity),
/// persisted in the Keychain so the channel identity is stable across launches.
public enum PhoneStaticKey {
    private static let service = "com.goforgeit.foundryx.noise"
    private static let account = "phone-static-key"

    public static func loadOrCreate() -> Data {
        if let existing = load(), existing.count == 32 { return existing }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let raw = key.rawRepresentation
        save(raw)
        return raw
    }

    private static func load() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return d
    }
    private static func save(_ data: Data) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
