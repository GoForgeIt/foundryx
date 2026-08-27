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
    public enum DeletionCleanupStage: String, Equatable, Sendable {
        case preparing
        case signedInMirror
        case widgetWithdrawal
        case liveExposureClosure
        case staleWorkCancellation
        case barrierVerification
        case barrierSync
        case trackBPreferences
        case pairingPreferences
        case pairingSecrets
        case localRoot
        case legacyInputs
        // The erase group that clears every registered account surface. It was
        // MISSING from this enum while `AccountDeletionCleanupGroup` had it, so a
        // failure there decoded to nil and was reported as the meaningless
        // "preparing" — the same word Nick was shown on build 771837.
        case accountSurfaces
        case completedSync
    }

    public enum Status: Equatable, Sendable {
        case unconfigured          // this build has no remote/OAuth config
        case signedOut
        case resolving
        case connected(host: String)
        case noHost                // signed in but no desktop designated as host
        case error(String)
        /// This identity has an unfinished deletion. Separate from `.error` so the
        /// sign-in screen can offer the ONE action that resolves it — the person
        /// cannot reach Settings, which is where "Retry deletion" lives.
        case deletionCleanupPending(ownerScope: String)
        case deletionCleanupInProgress(stage: DeletionCleanupStage)
        case deletionCleanupFailed(stage: DeletionCleanupStage, reason: String)
        case deletionCleanupSucceeded
    }

    // `internal(set)` rather than `private(set)`: the seams need to drive a status
    // the app can only reach through a real refused sign-in. Still read-only to
    // every consumer outside this module.
    @Published public internal(set) var status: Status = .signedOut {
        didSet {
            // ⚠ ONE PLACE, BECAUSE THERE ARE FOURTEEN SETTLE SITES. Cancelling the watchdog
            // at each of them means fourteen chances to forget, and the one that is
            // forgotten is a working connection later stomped into an error by a watchdog
            // nobody cancelled. A `didSet` cannot be forgotten by a site that does not know
            // it exists.
            //
            // (My first attempt DID edit each site, by line, and split a multi-line
            // `status = .error(` in half. Blind line-insertion into Swift is how that
            // happens; the single observer avoids the whole class.)
            if case .resolving = status { return }
            cancelResolveWatchdog()
        }
    }
    /// Authentication state is independent of email. Apple commonly returns email
    /// only on the first authorization, while its stable subject remains signed in.
    @Published public private(set) var isSignedIn = false
    @Published public private(set) var email: String?
    @Published public private(set) var relay: RelayConfig?
    /// The current verified id_token — sent to the door as the bearer (the door
    /// verifies it; no manual door bearer needed in remote-only mode).
    @Published public private(set) var idToken: String?
    /// The same token bound to the account generation that requested it. Consumers
    /// of account-scoped state use this instead of relabeling a delayed token with
    /// whatever identity happens to be current when the await finishes.
    @Published public private(set) var boundIdToken: AccountBoundToken?
    /// Changes only after the account storage boundary transitions. RootView keys
    /// account-owned state objects with this revision.
    @Published public private(set) var identityRevision: UInt64 = 0

    private let auth: FoundryAuth
    private let remote: RemoteConfig?
    private let log: DoorLog?
    private var lastSignInProvider: AuthProvider?

    public init(log: DoorLog? = .shared) {
        self.auth = FoundryAuth(log: log)
        self.remote = RemoteConfig.fromBundle()
        self.log = log
        let identity = auth.signedInIdentity
        self.email = Self.identityLabel(identity)
        self.isSignedIn = FoundryAuth.hasPersistedSignIn
        self.identityRevision = CaptureAccountScope.identityGeneration
        if remote == nil {
            status = .unconfigured
        } else {
            status = isSignedIn ? .resolving : .signedOut
        }
    }

    public var providers: [AuthProvider] { AuthProvider.allCases.filter { auth.isConfigured($0) } }
    public var isConfigured: Bool { remote != nil && !providers.isEmpty }

    /// The Settings → Account identity block. Reads the @Published `email` first
    /// (so sign-out flips the row instantly) and falls back to the persisted
    /// keychain identity for the email/name/provider at launch — so the real
    /// account shows even before `restore()` runs.
    public var accountPresentation: AccountPresentation {
        AccountPresentation.make(signedIn: isSignedIn,
                                 email: auth.signedInEmail,
                                 name: auth.signedInName,
                                 provider: auth.signedInProvider)
    }

    // ── Server-side diagnostics (M5 R1b) ────────────────────────────────────
    // The sign-in/resolve path runs BEFORE the app can authenticate, so its
    // failures are invisible in-app (you can't reach the in-app log without
    // getting past sign-in). Ship a running diagnostic to the relay's
    // unauthenticated /diag/log so we can read it server-side on the VM.
    private var diag: [String] = []

    /// How long a resolve may claim to be in progress before it must say otherwise.
    ///
    /// Generous on purpose: a cold launch on a slow network legitimately takes seconds, and
    /// a watchdog that fires on a working connection is worse than none. Short enough that
    /// a person is not left waiting on a spinner that has already stopped meaning anything.
    static let resolveBudget: TimeInterval = 30

    private var resolveWatchdog: Task<Void, Never>?

    /// Refuse to keep claiming progress after `resolveBudget`.
    ///
    /// The generation is captured so a watchdog armed by a superseded resolve cannot stomp
    /// the status of the one that replaced it — the same guard the abandonment points use,
    /// applied to the recovery rather than only to the failure.
    private func startResolveWatchdog(generation: UInt64) {
        resolveWatchdog?.cancel()
        resolveWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.resolveBudget * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard generation == CaptureAccountScope.identityGeneration else { return }
                guard case .resolving = self.status else { return }
                self.note("resolve did not settle within \(Int(Self.resolveBudget))s — "
                          + "reporting stopped rather than continuing to claim progress")
                self.status = .error("Connection didn't complete")
            }
        }
    }

    /// Called by every path that SETTLES the status, so a settled resolve is not later
    /// overwritten by a watchdog that has not noticed.
    private func cancelResolveWatchdog() {
        resolveWatchdog?.cancel()
        resolveWatchdog = nil
    }

    private func note(_ s: String) {
        log?.info("remote: \(s)")
        diag.append(s)
        shipDiag()
    }

    private func shipDiag() {
        guard let remote else { return }
        // THE EMAIL IS GONE FROM THE WIRE. This header used to carry `email=…`, and
        // `GET /diag/log` answers 200 to anyone — measured, not assumed — so the one field
        // that identified a person was the one field a stranger could read. It was also
        // inconsistent with this repo's own rule: `RecordingDeviceStore` keeps the account
        // scope off this channel precisely BECAUSE the scope is computable from an email.
        //
        // What replaces it is strictly more useful for diagnosis and carries no person: the
        // shared envelope's anonymous install id correlates every line from one handset —
        // door, perf and device alike — which the email never did, because the other two
        // producers did not emit it.
        let header = FoundryXDiagContext.current().wireHeader
            + " session_status=\(status) providers=\(providers.map { $0.rawValue }.joined(separator: "+"))"
        let payload = ([header] + diag).joined(separator: "\n")
        var req = URLRequest(url: remote.gatewayHTTPURL.appendingPathComponent("diag/log"))
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload.data(using: .utf8)
        // THE SAME CHOKE POINT `DoorLog` SHIPS THROUGH, so a test run's sign-in trace cannot
        // reach the production relay either.
        FoundryXDiagShipping.send(req)  // fire-and-forget
    }

    /// On launch / appear: if already signed in, resolve the host silently.
    public func restore() async {
        do {
            guard let identity = try await auth.restorePersistedIdentity() else {
                // A locked launch cannot read the keychain. A fully ACTIVE opaque
                // scope remains authorized for background capture; a pending/missing
                // scope does not.
                isSignedIn = FoundryAuth.hasPersistedSignIn
                status = remote == nil ? .unconfigured
                    : (isSignedIn ? .resolving : .signedOut)
                return
            }
            isSignedIn = true
            email = Self.identityLabel(identity)
            identityRevision = CaptureAccountScope.identityGeneration
            guard remote != nil else {
                status = .unconfigured
                return
            }
            await resolve()
        } catch {
            isSignedIn = FoundryAuth.hasPersistedSignIn
            identityRevision = CaptureAccountScope.identityGeneration
            relay = nil
            idToken = nil
            boundIdToken = nil
            status = .error(error.localizedDescription)
            note("restore FAILED: \(error.localizedDescription)")
        }
    }

    public func signIn(_ provider: AuthProvider) async {
        guard remote != nil else { status = .unconfigured; return }
        lastSignInProvider = provider
        note("signIn(\(provider.rawValue)) start")
        do {
            let id = try await auth.signIn(provider) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .required:
                        self.status = .deletionCleanupPending(ownerScope: "pending")
                    case .stage(let stage):
                        self.status = .deletionCleanupInProgress(stage: stage)
                    case .succeeded:
                        self.status = .deletionCleanupSucceeded
                    case .failed(let stage, let reason):
                        self.status = .deletionCleanupFailed(stage: stage, reason: reason)
                    }
                }
            }
            // Let the final recovery event reach the main actor, then keep the
            // completion sentence on screen long enough to be perceived before
            // ordinary host resolution replaces it.
            await Task.yield()
            if case .deletionCleanupSucceeded = status {
                try? await Task.sleep(for: .milliseconds(650))
            }
            relay = nil
            idToken = nil
            boundIdToken = nil
            isSignedIn = true
            email = Self.identityLabel(id)
            identityRevision = CaptureAccountScope.identityGeneration
            // NOT THE ADDRESS — whether there was one. `note` appends to the buffer that
            // `shipDiag` POSTs, so this line went over the wire too; removing `email=` from
            // the header alone would have left the address travelling one line further down.
            // What a diagnosis needs from here is "did the provider return an identity", and
            // that is a boolean.
            note("signIn(\(provider.rawValue)) OK email_present=\(id.email != nil)")
            await resolve()
        } catch AuthError.cancelled {
            note("signIn cancelled")
        } catch let e as CaptureAccountScopeError {
            isSignedIn = FoundryAuth.hasPersistedSignIn
            identityRevision = CaptureAccountScope.identityGeneration
            if case .deletionCleanupPending(let scope) = e {
                // NOT `.error`: a generic message with no action is what stranded
                // someone on the login screen with a deleted server account and no
                // way forward.
                if case .deletionCleanupFailed = status {
                    // Preserve the named stage supplied by the real cleanup path.
                } else {
                    status = .deletionCleanupPending(ownerScope: scope)
                }
                note("signIn refused — deletion cleanup pending for \(scope)")
            } else {
                status = .error(e.localizedDescription)
                note("signIn FAILED: \(e.localizedDescription)")
            }
        } catch {
            isSignedIn = FoundryAuth.hasPersistedSignIn
            identityRevision = CaptureAccountScope.identityGeneration
            status = .error(error.localizedDescription)
            note("signIn FAILED: \(error.localizedDescription)")
        }
    }

    public func retryInterruptedDeletionSignIn() async {
        guard let provider = lastSignInProvider else { return }
        await signIn(provider)
    }

    /// Finish a deletion that never completed, from the LOGIN screen.
    ///
    /// The catch-22 this exists for: a `cleanupPending` record refuses sign-in, and
    /// the only other way to clear it — "Retry deletion" in Settings — is behind
    /// that same sign-in. Someone whose server account is already gone had no way
    /// forward at all. This runs the same owner-proving local cleanup, using the
    /// identity from the sign-in that was just refused, so no data can be erased
    /// for anyone but its proven owner.
    ///
    /// Returns true when the pending record is resolved and signing in is worth
    /// retrying.
    @discardableResult
    public func finishInterruptedDeletion(
        eraseLocal: @Sendable () async throws -> Void
    ) async -> Bool {
        switch status {
        case .deletionCleanupPending, .deletionCleanupFailed: break
        default: return false
        }
        DeletionRecorder.shared.emit("account.signin.recover", "start")
        do {
            try await eraseLocal()
            DeletionRecorder.shared.emit("account.signin.recover", "ok")
            status = remote == nil ? .unconfigured : .signedOut
            identityRevision = CaptureAccountScope.identityGeneration
            return true
        } catch {
            // Still stuck, but now it SAYS so instead of bouncing silently.
            DeletionRecorder.shared.emit(
                "account.signin.recover", "failed \(error)")
            status = .error(
                "Couldn't finish deleting this account on this iPhone. "
                + "Reinstalling the app will clear it.")
            return false
        }
    }

    public func signOut() {
        do {
            try auth.signOut()
            isSignedIn = false
            email = nil
            relay = nil
            idToken = nil
            boundIdToken = nil
            identityRevision = CaptureAccountScope.identityGeneration
            status = remote == nil ? .unconfigured : .signedOut
        } catch {
            isSignedIn = FoundryAuth.hasPersistedSignIn
            identityRevision = CaptureAccountScope.identityGeneration
            status = .error(error.localizedDescription)
            note("signOut FAILED: \(error.localizedDescription)")
            return
        }
        // A signed-out phone must not keep an ambient-recording BLE link (or its
        // standing pending reconnect) alive — the shared DeviceManager would
        // otherwise persist past the UI teardown and keep capturing/reconnecting
        // (including background state-restoration relaunches). AuthStore retains the
        // saved Omi pairing, while this suspension prevents reconnect until sign-in.
        DeviceManager.sharedExisting()?.suspend()
    }

    /// Mint a fresh id_token and resolve the designated host into a RelayConfig.
    public func resolve() async {
        guard let remote else { status = .unconfigured; return }
        let requestedGeneration = CaptureAccountScope.identityGeneration
        status = .resolving
        note("resolve start (gateway=\(remote.gatewayHTTPURL.absoluteString))")
        // ⚠ `.resolving` IS BOUNDED, BECAUSE AN UNBOUNDED ONE IS A LIE THE UI TELLS.
        //
        // `resolve()` has SEVEN `guard requestedGeneration == …identityGeneration else
        // { return }` abandonment points. Every one leaves `status` at `.resolving`, and
        // `WelcomeFrontDoor.connectStatus` maps that to "Connecting to your computer…".
        // So an abandoned resolve renders as hopeful progress FOREVER.
        //
        // Measured 2026-08-26: the owner's phone sat on "Connecting to your computer…"
        // while its every door request carried an EMPTY bearer — 90 of 138 that day. The
        // session was not connecting. It had stopped, and the only surface that could have
        // said so was reporting the opposite.
        //
        // Abandoning IS legitimate when a newer resolve superseded this one — that resolve
        // sets its own status well within the window. What this refuses is the case where
        // nothing follows: a person waiting on a spinner that will never resolve, with no
        // reason given and nothing to act on. `.error` is the honest terminal state, and it
        // is the one the UI already renders with a real sentence.
        startResolveWatchdog(generation: requestedGeneration)
        let resolvedToken: String?
        do {
            resolvedToken = try await auth.currentIdToken()
        } catch {
            guard requestedGeneration == CaptureAccountScope.identityGeneration else {
                return
            }
            relay = nil
            idToken = nil
            boundIdToken = nil
            status = .error(error.localizedDescription)
            note("resolve: identity refresh/storage failed: \(error.localizedDescription)")
            return
        }
        guard requestedGeneration == CaptureAccountScope.identityGeneration else {
            return
        }
        guard let token = resolvedToken else {
            relay = nil
            idToken = nil
            boundIdToken = nil
            status = .signedOut
            note("resolve: no valid id_token (signed out / refresh failed)")
            return
        }
        idToken = token
        boundIdToken = AccountBoundToken(
            value: token,
            generation: requestedGeneration)
        // Account signup (track 20260705T1100, decision #5): the forced login IS
        // the account creation — ship the identity-only signup event ONCE per
        // account. Self-healing: the flag is set only on a 2xx, so a failed POST
        // retries on the next sign-in/restore. Fire-and-forget; never blocks
        // resolve. (Name flows in with Apple sign-in — Apple only surfaces it on
        // the very first authorization.)
        if AccountClient.shouldPostSignup(generation: requestedGeneration) {
            let client = AccountClient(baseURL: remote.gatewayHTTPURL)
            Task {
                let succeeded = await client.postSignup(
                    idToken: token,
                    name: auth.signedInName,
                    generation: requestedGeneration)
                _ = AccountClient.completeSignupPost(
                    succeeded: succeeded,
                    generation: requestedGeneration)
            }
        }
        do {
            let cfg = try await HostResolver(remote: remote, log: log).resolveRelayConfig(idToken: token)
            guard requestedGeneration == CaptureAccountScope.identityGeneration else {
                return
            }
            relay = cfg
            status = .connected(host: cfg.tunnelId)
            note("resolve OK tunnel=\(cfg.tunnelId) relay=\(cfg.relayURL.absoluteString) door=\(cfg.pinnedDoorPrefix)")
        } catch HostResolveError.noHostDesignated {
            guard requestedGeneration == CaptureAccountScope.identityGeneration else {
                return
            }
            relay = nil
            status = .noHost
            note("resolve: NO host designated for this account")
        } catch {
            guard requestedGeneration == CaptureAccountScope.identityGeneration else {
                return
            }
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
        let requestedGeneration = CaptureAccountScope.identityGeneration
        reauthInFlight = true
        defer { reauthInFlight = false }
        note("door rejected id_token as expired — silent refresh once")
        let fresh: String?
        do {
            fresh = try await auth.currentIdToken()
        } catch {
            guard requestedGeneration == CaptureAccountScope.identityGeneration else {
                return
            }
            relay = nil
            idToken = nil
            boundIdToken = nil
            status = .error(error.localizedDescription)
            note("re-auth FAILED: \(error.localizedDescription)")
            return
        }
        guard requestedGeneration == CaptureAccountScope.identityGeneration else {
            return
        }
        if let fresh, fresh != idToken {
            idToken = fresh
            boundIdToken = AccountBoundToken(
                value: fresh,
                generation: requestedGeneration)
            note("re-auth: obtained a fresh id_token (door target rebuilds, uploads resume)")
            return
        }
        // No NEW token (refresh failed / not possible / door still rejects it) → surface
        // the login screen so the user re-authenticates and mints a fresh id_token.
        relay = nil
        idToken = nil
        boundIdToken = nil
        status = .signedOut
        note("re-auth: no fresh id_token → signed out (login required)")
    }

    /// The door target for the resolved remote host: the relay tunnel + the
    /// id_token as bearer (the door verifies it). `nil` until connected.
    public func makeDoorTarget() -> DoorTarget? {
        guard let relay,
              let boundIdToken,
              boundIdToken.generation == CaptureAccountScope.identityGeneration,
              idToken == boundIdToken.value,
              let remote else { return nil }
        // baseURL is nominal in relay mode (RelayTransport drives the tunnel); use
        // the gateway URL so it's a valid URL.
        return DoorTarget(baseURL: remote.gatewayHTTPURL, bearer: boundIdToken.value, relay: relay,
                          useMux: FoundryXFeatures.mux)
    }

    private static func identityLabel(_ identity: AuthIdentity?) -> String? {
        guard let identity else { return nil }
        if let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        guard let provider = AuthProvider(rawValue: identity.provider) else {
            return "Signed-in account"
        }
        switch provider {
        case .apple: return "Apple account"
        case .google: return "Google account"
        case .microsoft: return "Microsoft account"
        }
    }
}

public enum DeletionSignInRecoveryEvent: Equatable, Sendable {
    case required
    case stage(RemoteSession.DeletionCleanupStage)
    case succeeded
    case failed(RemoteSession.DeletionCleanupStage, String)
}

/// Build-time feature flags. `mux` activates the multiplexed door transport (one
/// persistent connection per channel) — flip in lockstep with a mux-capable desktop
/// door (the door flips at runtime via the `~/.foundry/foundryx_mux` flag file). The
/// per-turn `RelayTransport` path is the fallback when this is false.
public enum FoundryXFeatures {
    public static let mux = true
}
