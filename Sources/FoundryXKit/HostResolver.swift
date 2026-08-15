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

    public var errorDescription: String? {
        switch self {
        case .noHostDesignated: return "No desktop is designated as your host yet — open Solleva on your Mac and press “Make this machine the host”."
        case .http(let c, let b): return "Host lookup failed (\(c)): \(b)"
        case .badResponse: return "Unexpected response from the gateway"
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

    /// Decode a hex string (e.g. the door's 64-char pubkey) to bytes; nil if not
    /// valid even-length hex.
    static func hexToData(_ hex: String) -> Data? {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
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
        // public key (hex). Pinning it means a rogue door that registered under this
        // tunnel fails the Noise handshake — so the relay needs no door-registration
        // secret (open registration is safe with this pin).
        let machineId = (obj["machine_id"] as? String) ?? ""
        let expectedDoor = Self.hexToData(machineId)
        log?.info("resolved host tunnel=\(tunnel) label=\((obj["label"] as? String) ?? "?") pinned=\(expectedDoor != nil)")
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
