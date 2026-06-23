import Foundation
import SwiftUI

// Off-LAN remote session (M5 R1b). Holds the signed-in identity and the resolved
// RelayConfig (the account's designated desktop host). When `relay` is non-nil the
// app's DoorTarget dials the door through the blind relay; when nil it's LAN-direct
// (unchanged). Remote is OFF unless this build has the OAuth + gateway config
// (Info.plist FoundryXOAuth) — so existing LAN behavior is never disturbed.
//
// NOT YET COMPILE-VERIFIED in CI — validate in Xcode.
@MainActor
public final class RemoteSession: ObservableObject {
    public enum Status: Equatable {
        case unconfigured          // this build has no remote/OAuth config
        case signedOut
        case resolving
        case connected(host: String)
        case noHost                // signed in but no desktop designated as host
        case error(String)
    }

    @Published public private(set) var status: Status = .signedOut
    @Published public private(set) var email: String?
    @Published public private(set) var relay: RelayConfig?
    /// The current verified id_token — sent to the door as the bearer (the door
    /// verifies it; no manual door bearer needed in remote-only mode).
    @Published public private(set) var idToken: String?

    private let auth: FoundryAuth
    private let remote: RemoteConfig?
    private let log: DoorLog?

    public init(log: DoorLog? = nil) {
        self.auth = FoundryAuth(log: log)
        self.remote = RemoteConfig.fromBundle()
        self.log = log
        self.email = auth.signedInEmail
        if remote == nil {
            status = .unconfigured
        } else {
            status = auth.signedInEmail == nil ? .signedOut : .resolving
        }
    }

    public var providers: [AuthProvider] { AuthProvider.allCases.filter { auth.isConfigured($0) } }
    public var isConfigured: Bool { remote != nil && !providers.isEmpty }

    // ── Server-side diagnostics (M5 R1b) ────────────────────────────────────
    // The sign-in/resolve path runs BEFORE the app can authenticate, so its
    // failures are invisible in-app (you can't reach the in-app log without
    // getting past sign-in). Ship a running diagnostic to the relay's
    // unauthenticated /diag/log so we can read it server-side on the VM.
    private var diag: [String] = []

    private func note(_ s: String) {
        log?.info("remote: \(s)")
        diag.append(s)
        shipDiag()
    }

    private func shipDiag() {
        guard let remote else { return }
        let b = Bundle.main.infoDictionary
        let ver = (b?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (b?["CFBundleVersion"] as? String) ?? "?"
        let header = "FoundryX \(ver)(\(build)) email=\(email ?? "-") status=\(status) provs=\(providers.map { $0.rawValue })"
        let payload = ([header] + diag).joined(separator: "\n")
        var req = URLRequest(url: remote.gatewayHTTPURL.appendingPathComponent("diag/log"))
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload.data(using: .utf8)
        Task { _ = try? await URLSession.shared.data(for: req) }  // fire-and-forget
    }

    /// On launch / appear: if already signed in, resolve the host silently.
    public func restore() async {
        guard remote != nil, auth.signedInEmail != nil else { return }
        await resolve()
    }

    public func signIn(_ provider: AuthProvider) async {
        guard let remote else { status = .unconfigured; return }
        note("signIn(\(provider.rawValue)) start")
        do {
            let id = try await auth.signIn(provider)
            email = id.email
            note("signIn(\(provider.rawValue)) OK email=\(id.email ?? "-")")
            await resolve()
        } catch AuthError.cancelled {
            note("signIn cancelled")
        } catch {
            status = .error(error.localizedDescription)
            note("signIn FAILED: \(error.localizedDescription)")
        }
    }

    public func signOut() {
        auth.signOut()
        email = nil
        relay = nil
        status = remote == nil ? .unconfigured : .signedOut
    }

    /// Mint a fresh id_token and resolve the designated host into a RelayConfig.
    public func resolve() async {
        guard let remote else { status = .unconfigured; return }
        status = .resolving
        note("resolve start (gateway=\(remote.gatewayHTTPURL.absoluteString))")
        guard let token = await auth.currentIdToken() else {
            relay = nil
            idToken = nil
            status = .signedOut
            note("resolve: no valid id_token (signed out / refresh failed)")
            return
        }
        idToken = token
        do {
            let cfg = try await HostResolver(remote: remote, log: log).resolveRelayConfig(idToken: token)
            relay = cfg
            status = .connected(host: cfg.tunnelId)
            note("resolve OK tunnel=\(cfg.tunnelId) relay=\(cfg.relayURL.absoluteString) pinned=\(cfg.expectedDoorStatic != nil)")
        } catch HostResolveError.noHostDesignated {
            relay = nil
            status = .noHost
            note("resolve: NO host designated for this account")
        } catch {
            relay = nil
            status = .error(error.localizedDescription)
            note("resolve FAILED: \(error.localizedDescription)")
        }
    }

    /// The door target for the resolved remote host: the relay tunnel + the
    /// id_token as bearer (the door verifies it). `nil` until connected.
    public func makeDoorTarget() -> DoorTarget? {
        guard let relay, let token = idToken, let remote else { return nil }
        // baseURL is nominal in relay mode (RelayTransport drives the tunnel); use
        // the gateway URL so it's a valid URL.
        return DoorTarget(baseURL: remote.gatewayHTTPURL, bearer: token, relay: relay)
    }
}
