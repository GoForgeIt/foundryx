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
    public var isConfigured: Bool {
        #if DEBUG
        if previewForced { return true }
        #endif
        return remote != nil && !providers.isEmpty
    }

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
    ///
    /// Instant launch (H usefulness slice): if a last-good resolved session is cached
    /// for THIS signed-in account, publish it SYNCHRONOUSLY here — `relay`/`idToken`/
    /// `status=.connected` land before the first `await`, so `makeDoorTarget()` is
    /// non-nil immediately and RootView can drop the branded gate for the tabs after
    /// only the 0.6s brand beat. Then re-resolve quietly in the background, swapping the
    /// published route ONLY if it changed (RootView's `.id()` rebuild handles the swap)
    /// and KEEPING the cached route on a transient failure. The un-cached path is
    /// unchanged (falls through to the original `resolve()`).
    public func restore() async {
        guard remote != nil, let signedInEmail = auth.signedInEmail else { return }
        if let cached = loadCache(), cached.email == signedInEmail {
            relay = cached.relay
            idToken = cached.idToken
            status = .connected(host: cached.relay.tunnelId)
            note("restore: published cached host tunnel=\(cached.relay.tunnelId) (cached)")
            await reresolveInBackground()
        } else {
            await resolve()
        }
    }

    /// Quiet re-resolve after an instant cached publish. Refreshes the host in the
    /// background and swaps the published route only when it actually changed (a new
    /// tunnel/relay/pin or a fresher bearer). On a transient failure it KEEPS the cached
    /// route — a launch-time network hiccup must never tear down a working connection
    /// (a genuinely dead door 401s → `handleAuthExpired()` self-heals). Only an explicit
    /// server-side de-designation (`noHost`) clears the cache and drops the route.
    private func reresolveInBackground() async {
        guard let remote else { return }
        guard let token = await auth.currentIdToken() else {
            note("re-resolve: no fresh id_token; keeping cached route")
            return
        }
        do {
            let cfg = try await HostResolver(remote: remote, log: log).resolveRelayConfig(idToken: token)
            let changed = cfg.tunnelId != relay?.tunnelId
                || cfg.relayURL != relay?.relayURL
                || cfg.expectedDoorStatic != relay?.expectedDoorStatic
                || token != idToken
            if changed {
                idToken = token
                relay = cfg
                status = .connected(host: cfg.tunnelId)
                saveCache()
                note("re-resolve OK tunnel=\(cfg.tunnelId) — route changed, swapped")
            } else {
                note("re-resolve OK tunnel=\(cfg.tunnelId) — unchanged")
            }
        } catch HostResolveError.noHostDesignated {
            relay = nil
            idToken = nil
            status = .noHost
            clearCache()
            note("re-resolve: host no longer designated → cleared cache, dropped route")
        } catch {
            note("re-resolve FAILED (keeping cached route): \(error.localizedDescription)")
        }
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
        idToken = nil
        clearCache()   // instant-launch invalidation: never restore a signed-out account
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
            saveCache()   // persist the last-good resolved session for instant launch next time
            note("resolve OK tunnel=\(cfg.tunnelId) relay=\(cfg.relayURL.absoluteString) pinned=\(cfg.expectedDoorStatic != nil)")
        } catch HostResolveError.noHostDesignated {
            relay = nil
            status = .noHost
            clearCache()   // instant-launch invalidation: no host means no route to restore
            note("resolve: NO host designated for this account")
        } catch {
            relay = nil
            status = .error(error.localizedDescription)
            note("resolve FAILED: \(error.localizedDescription)")
        }
    }

    /// The phone's door bearer (its OIDC id_token) was rejected as EXPIRED by the door
    /// (a 401 on a capture upload). Per the user's ask: attempt a silent refresh ONCE;
    /// if that yields a genuinely fresh token, publish it (the door target rebuilds with
    /// it and uploads resume); if not, drop to signed-out so the LOGIN screen is surfaced
    /// — never keep firing requests with a known-expired token. Guarded so a burst of
    /// 401s triggers a single refresh attempt.
    private var reauthInFlight = false
    public func handleAuthExpired() async {
        guard remote != nil else { status = .unconfigured; return }
        guard !reauthInFlight else { return }
        reauthInFlight = true
        defer { reauthInFlight = false }
        note("door rejected id_token as expired — silent refresh once")
        let fresh = await auth.currentIdToken()
        if let fresh, fresh != idToken {
            idToken = fresh
            saveCache()   // keep the cached bearer fresh so next launch restores a live token
            note("re-auth: obtained a fresh id_token (door target rebuilds, uploads resume)")
            return
        }
        // No NEW token (refresh failed / not possible / door still rejects it) → surface
        // the login screen so the user re-authenticates and mints a fresh id_token.
        relay = nil
        idToken = nil
        status = .signedOut
        clearCache()   // the token is unrefreshable → don't instant-restore a dead route
        note("re-auth: no fresh id_token → signed out (login required)")
    }

    /// The door target for the resolved remote host: the relay tunnel + the
    /// id_token as bearer (the door verifies it). `nil` until connected.
    public func makeDoorTarget() -> DoorTarget? {
        guard let relay, let token = idToken, let remote else { return nil }
        // baseURL is nominal in relay mode (RelayTransport drives the tunnel); use
        // the gateway URL so it's a valid URL.
        return DoorTarget(baseURL: remote.gatewayHTTPURL, bearer: token, relay: relay,
                          useMux: FoundryXFeatures.mux)
    }

    // ── Instant-launch cache (last-good resolved session) ───────────────────
    // Persist the last successfully-resolved route so a returning signed-in user gets
    // tabs after only the brand beat, without waiting on a network host-resolve. Lives
    // in Application Support alongside the chat store (`FoundryX/remote-session.json`).
    //
    // TODO(keychain): the id_token is a short-lived (~55 min) bearer; it's cached here in
    // the app-sandbox Application Support JSON rather than the Keychain because FoundryAuth
    // exposes no SYNCHRONOUS token accessor (only the async `currentIdToken()`), and instant
    // launch needs the token in hand before the first `await`. This is app-sandboxed and
    // self-healing (a stale token 401s at the door → `handleAuthExpired()` refreshes it).
    // Move to the Keychain when a sync seam exists — do NOT build new Keychain infra here.
    private struct CachedSession: Codable {
        var relay: RelayConfig
        var idToken: String
        var email: String
    }

    private static func cacheURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("FoundryX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("remote-session.json")
    }

    private func loadCache() -> CachedSession? {
        guard let url = Self.cacheURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedSession.self, from: data)
    }

    /// Write the current published route as the last-good session. No-op unless we have a
    /// full route (relay + token + email) — a partial write could restore a broken state.
    private func saveCache() {
        guard let url = Self.cacheURL(), let relay, let idToken, let email else { return }
        let cached = CachedSession(relay: relay, idToken: idToken, email: email)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearCache() {
        guard let url = Self.cacheURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    #if DEBUG
    /// DEBUG-only: a session forced into a given state for headless UI screenshots
    /// (see RootView's FOUNDRYX_UI_PREVIEW path). Bypasses real auth/config so the
    /// no-host / error gate states can be captured without a live backend.
    private var previewForced = false
    public static func preview(status: Status, email: String?) -> RemoteSession {
        let s = RemoteSession()
        s.previewForced = true
        s.email = email
        s.status = status
        return s
    }
    #endif
}

/// Build-time feature flags. `mux` activates the multiplexed door transport (one
/// persistent connection per channel) — flip in lockstep with a mux-capable desktop
/// door (the door flips at runtime via the `~/.foundry/foundryx_mux` flag file). The
/// per-turn `RelayTransport` path is the fallback when this is false.
public enum FoundryXFeatures {
    public static let mux = true
}
