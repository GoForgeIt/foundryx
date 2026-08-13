import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// The door-credential seam, driven END TO END: a real `VaultSignupClient` over a
/// URLProtocol stub that answers with the EXACT body the signup service sends,
/// wired into a real `VaultFunnelModel`.
///
/// The seam-stub tests elsewhere in this bundle hand the funnel a
/// `VaultProvisionStatus` directly, which is precisely why nobody caught this: the
/// client and the server were each green against their own stub, and the defect
/// lived in the wire contract between them. So this file stubs only the socket.
final class VaultDoorCredentialFeatureTests: XCTestCase {
    func testVaultDoorCredentialFeature() async throws {
        try await BrineFeatureRunner.run(
            "vault-door-credential",
            registry: StepRegistry(VaultDoorCredentialSteps.make(world: try .init())))
    }
}

/// The server's wire answer, PER PATH — because the two endpoints deliberately
/// answer differently: `/signup/reconcile` is authenticated and issues the door
/// credential, `/app/return` is a ticket exchange and withholds it. A stub that
/// answered both alike would model a server that does not exist.
private final class DoorCredentialStub: URLProtocol {
    nonisolated(unsafe) static var responseJSON: [String: Any] = [:]
    nonisolated(unsafe) static var responseByPath: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var requestPaths: [String] = []
    /// A 200 whose body is not a JSON object at all — a proxy error page, a
    /// truncated response, a service answering HTML. Set, it wins over the
    /// dictionaries above.
    nonisolated(unsafe) static var rawBody: Data?

    static func reset() {
        responseJSON = ["status": "provisioning"]
        responseByPath = [:]
        requestPaths = []
        rawBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requestPaths.append(path)
        let body = Self.responseByPath[path] ?? Self.responseJSON
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        let data = Self.rawBody ?? (try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DoorCredentialNoopBrowser: VaultCheckoutBrowser, @unchecked Sendable {
    func open(_ url: URL) async throws -> URL? { nil }
}

private final class VaultDoorCredentialWorld: @unchecked Sendable {
    let fixture: PairingTestFixture
    let defaults: UserDefaults
    let secrets = ScriptedPairingSecretStore()
    var attempts: VaultCheckoutAttemptStore!
    var model: VaultFunnelModel!

    init() throws {
        fixture = try PairingTestFixture()
        defaults = fixture.defaults
    }

    /// The REAL client, talking to the stubbed socket.
    private func liveClient() -> VaultSignupClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [DoorCredentialStub.self]
        return VaultSignupClient(baseURL: URL(string: "https://signup.test")!,
                                 session: URLSession(configuration: cfg))
    }

    @MainActor func reset() async {
        try? fixture.activateOther(subject: "door-credential-owner")
        DoorCredentialStub.reset()
        attempts = VaultCheckoutAttemptStore(defaults: defaults)
        attempts.save(attemptId: "paid-attempt", plan: .pro)
        model = VaultFunnelModel(
            service: liveClient(),
            browser: DoorCredentialNoopBrowser(),
            cellStore: CellStore(
                defaults: defaults,
                keychainService: fixture.cellService,
                secretStore: secrets),
            attempts: attempts,
            // The reconcile call refuses to go out with no credential, so the
            // funnel has to be holding a sign-in for any of this to be reached.
            idToken: { "id-token-under-test" })
        await model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
        model.activateFromSettings()
    }

    @MainActor func reconcile() async {
        await model.reconcileOnForeground(generation: CaptureAccountScope.identityGeneration)
    }

    var visible: VaultFunnelPresentation { get async { await MainActor.run { model.presentation } } }
}

private enum VaultDoorCredentialSteps {
    static func make(world w: VaultDoorCredentialWorld) -> [StepDefinition] {[
        defineStep("my payment is confirmed and setup is under way") { ctx, _, _ in
            await w.reset(); return ctx
        },

        // ── THE defect: ready, and no way in ───────────────────────────────────
        defineStep("the server says my Vault is ready but sends no door credential") { ctx, _, _ in
            // The literal body production sent for weeks.
            DoorCredentialStub.responseJSON = [
                "status": "ready",
                "cell_url": "https://foundry-cell-owner-325e-g1.fly.dev",
            ]
            await w.reconcile()
            return ctx
        },
        defineCheck("I am told my Vault is running but the app cannot get in") { _, _, _ in
            let state = await MainActor.run { w.model.state }
            guard case .failed(let reason) = state else {
                throw BrineStepError(
                    "a ready Vault with no door credential was not surfaced at all — "
                    + "state is \(state). This is the silent demotion: the phone shows "
                    + "setup progress forever and falls back to recording locally.")
            }
            guard reason == .cannotOpenVault else {
                throw BrineStepError("surfaced, but as the wrong thing: \(reason)")
            }
            let p = await w.visible
            guard p.title == "Your Vault is running but we can't get in" else {
                throw BrineStepError("the real screen does not say what happened: \(p.title)")
            }
            // `primaryAction` is NOT optional, so `!= nil` was a check that could
            // never fail — a screen offering `.none` would have sailed through it.
            // The thing that matters is that the person is given a way out.
            guard p.primaryAction != .none else {
                throw BrineStepError(
                    "the failure screen offers no way forward — the only action is .none")
            }
        },
        defineCheck("I am not left watching setup progress") { _, _, _ in
            let p = await w.visible
            guard !p.showsProgress else {
                throw BrineStepError("still showing a spinner for a Vault that will never connect")
            }
        },
        defineCheck("my paid Vault attempt is still remembered") { _, _, _ in
            guard w.attempts.load() != nil else {
                throw BrineStepError("a pairing failure threw away the paid attempt")
            }
        },

        // ── A 200 this build cannot read at all ────────────────────────────────
        //
        // The funnel has a branch for exactly this, and nothing exercised it: the
        // mutation that deleted the branch left every test green. A body we cannot
        // parse is a contract breach, and waiting for the next foreground cannot
        // fix it — which is what the catch-all reserved for network blips does.
        defineStep("the server answers with a body this app cannot read") { ctx, _, _ in
            DoorCredentialStub.rawBody = Data("<html>502 Bad Gateway</html>".utf8)
            await w.reconcile()
            return ctx
        },

        // ── The same path, with the credential present ─────────────────────────
        defineStep("the server says my Vault is ready and sends the door credential") { ctx, _, _ in
            DoorCredentialStub.responseJSON = [
                "status": "ready",
                "cell_url": "https://foundry-cell-owner-325e-g1.fly.dev",
                "handoff": "3f9c1d2b4a5e6f708192a3b4c5d6e7f8",
            ]
            await w.reconcile()
            return ctx
        },
        defineCheck("the app pairs with the Vault instead of reporting a failure") { _, _, _ in
            let state = await MainActor.run { w.model.state }
            if case .failed(let reason) = state {
                throw BrineStepError("a complete ready answer was reported as a failure: \(reason)")
            }
            // This world's CellStore writes to `ScriptedPairingSecretStore` — an
            // in-memory store whose writes always succeed — so a complete ready
            // answer must go LIVE on every platform. The previous check branched on
            // `AccountDataIsolationFeatureTests.keychainUsable`, predicting the
            // funnel from the REAL keychain while the funnel was wired to the fake:
            // on the hostless iOS lane the probe is false, the branch demanded
            // setting-up, and the fake store's successful write produced live —
            // deterministically red, so this suite had never once run green on the
            // iOS runtime. The store-cannot-write hold is real behavior, and it is
            // covered the deterministic way — by SCRIPTING the failure
            // (PairingFailureTests.testFailedFirstVaultBearerWriteLeavesNoPartialPairing)
            // — not by branching on which host the test happens to run on.
            guard case .live = state else {
                throw BrineStepError("a complete ready answer did not go live: \(state)")
            }
        },

        // ── A Vault deliberately deleted is not a fault ────────────────────────
        defineStep("the server says my Vault was deleted and a new one is on the way") { ctx, _, _ in
            DoorCredentialStub.responseJSON = ["status": "vault_absent"]
            await w.reconcile()
            return ctx
        },
        defineCheck("the app keeps waiting quietly rather than showing me an error") { _, _, _ in
            let state = await MainActor.run { w.model.state }
            if case .failed(let reason) = state {
                throw BrineStepError(
                    "a Vault the owner deleted was reported as a fault (\(reason)) — the account "
                    + "is fine and a replacement is being provisioned")
            }
        },

        // ── The return-ticket path withholds it BY DESIGN ──────────────────────
        defineStep("the return ticket reports my Vault is ready without a door credential") { ctx, _, _ in
            // EXACTLY production's split: the ticket exchange reports the status
            // and nothing else; the authenticated reconcile issues the credential.
            DoorCredentialStub.responseByPath = [
                "/app/return": ["status": "ready"],
                "/signup/reconcile": [
                    "status": "ready",
                    "cell_url": "https://foundry-cell-owner-325e-g1.fly.dev",
                    "handoff": "3f9c1d2b4a5e6f708192a3b4c5d6e7f8",
                ],
            ]
            await MainActor.run { DoorCredentialStub.requestPaths = [] }
            await w.model.handleReturn(
                url: URL(string: "foundryx://vault/return?ticket=OPAQUE")!,
                generation: CaptureAccountScope.identityGeneration)
            return ctx
        },
        defineCheck("the app treats it as not-yet-answered and asks again with my sign-in") { _, _, _ in
            let state = await MainActor.run { w.model.state }
            if case .failed(let reason) = state {
                throw BrineStepError(
                    "the return path withholds the credential BY DESIGN — treating that as a "
                    + "failure would put an error in front of every returning buyer: \(reason)")
            }
            let paths = DoorCredentialStub.requestPaths
            guard paths.contains("/app/return") else {
                throw BrineStepError("the ticket was never exchanged: \(paths)")
            }
            guard paths.contains("/signup/reconcile") else {
                throw BrineStepError(
                    "the app did not fall through to the authenticated endpoint, which is the "
                    + "ONLY place the door credential is issued: \(paths)")
            }
        },
    ]}
}
