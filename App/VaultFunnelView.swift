import SwiftUI
import Grain
// NOTE: no `import FoundryXKit` — the app target compiles Sources/FoundryXKit
// directly into this same module (see project.yml), so VaultFunnelModel,
// VaultAction, VaultPlan, VaultCheckoutBrowser, VaultSignupClient, CellStore
// et al. are already in scope; importing a non-existent module breaks the build.
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

// VaultFunnelView — the phone-side Vault activation screens (track T-IOS-FUNNEL, design
// canon "6 · Vault"). One view, driven entirely by VaultFunnelModel.state: the paid-intent
// TRIGGER, the Vault INTRO, native PLANS (three selectable tier rows + one CTA), the browser
// hand-off ("opening"), and the durable return states Checking payment → Setting up → Live.
// Pricing is native; login + payment happen in an external browser (ASWebAuthenticationSession
// via ASWebAuthenticationVaultBrowser). Every visual uses the Grain design system, matching
// the prototype's language (micro-label, screen title, tier rows, privacy line).
struct VaultFunnelView: View {
    @ObservedObject var model: VaultFunnelModel

    var body: some View {
        ZStack {
            GrainDotField(density: 0.4)
            LinearGradient(colors: [tint.opacity(0.16), GrainColor.surfaceElevated.opacity(0.0)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
            content
                .frame(maxWidth: 460)
                .padding(.horizontal, GrainSpacing.x4)
        }
        .grainBackground()
    }

    /// The accent tint follows the funnel's emotional register (forge → sage on live).
    private var tint: Color {
        switch model.state {
        case .live: return GrainColor.sage
        default: return GrainColor.forgeBlue
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .trigger(let action):
            triggerScreen(action)
        case .intro:
            introScreen
        case .plans(let selected):
            plansScreen(selected)
        case .opening:
            waitScreen(label: "Secure checkout", title: "Opening your browser…",
                       body: "Sign-in and payment open in your browser. Your card never touches the app.",
                       spinning: true)
        case .checkingPayment:
            waitScreen(label: "Back in FoundryX", title: "Checking your payment…",
                       body: "Welcome back. We finish on our servers and reconcile the moment you return — closing the app is safe.",
                       spinning: true)
        case .settingUp:
            waitScreen(label: "Payment confirmed", title: "Setting up your Vault",
                       body: "Your private Vault, your memory, and your agent. Yours alone — isolated from every other Vault.",
                       spinning: true)
        case .live:
            liveScreen
        }
    }

    // MARK: paid-intent trigger — "This lives in your Vault"

    private func triggerScreen(_ action: VaultAction) -> some View {
        VStack(spacing: GrainSpacing.x4) {
            Spacer()
            GrainVoiceRing(energy: 0.12, order: 0.5).frame(width: 96, height: 96)
            microLabel("\(action.triggerLabel) · Search everything")
            Text("This lives in your Vault")
                .grainTextStyle(.title).multilineTextAlignment(.center)
            Text("Asking Foundry about everything you've captured — and searching by meaning — runs on your private Vault. It's off right now.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
            privacyLine("key", "Encrypted, isolated, and yours. Only your voice and login open it.")
            Spacer()
            VStack(spacing: GrainSpacing.x2) {
                GrainButton("Set up your Vault", variant: .filled, size: .lg) { model.beginSetup() }
                GrainButton("Not now", variant: .ghost, size: .sm) { model.dismiss() }
            }
        }
        .padding(.vertical, GrainSpacing.x6)
    }

    // MARK: intro — "Turn on your Vault"

    private var introScreen: some View {
        VStack(spacing: GrainSpacing.x4) {
            Spacer()
            microLabel("On-device today · your Vault next")
            Text("Turn on your Vault")
                .grainTextStyle(.title).multilineTextAlignment(.center)
            Text("Capture, transcribe, and search stay on this iPhone for free. Your private Vault adds three things.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
            VStack(spacing: GrainSpacing.x2) {
                unlockRow("magnifyingglass", "Search everything by meaning",
                          "Find any capture by what it meant, not just its words.")
                unlockRow("bubble.left.and.bubble.right", "Ask your memory anything",
                          "Chat with Foundry about everything you've captured.")
                unlockRow("bolt", "Foundry acts for you",
                          "Approved agent actions run on your private Vault.")
            }
            Spacer()
            VStack(spacing: GrainSpacing.x2) {
                GrainButton("See plans", variant: .filled, size: .lg) { model.seePlans() }
                privacyLine("key", "Encrypted, isolated, and yours. Only your voice and login open it.")
            }
        }
        .padding(.vertical, GrainSpacing.x6)
    }

    // MARK: native pricing — three selectable rows + one CTA

    private func plansScreen(_ selected: VaultPlan) -> some View {
        VStack(spacing: GrainSpacing.x3) {
            Spacer(minLength: GrainSpacing.x4)
            Text("Choose a plan").grainTextStyle(.title)
            Text("Every plan includes your private, isolated Vault. Renews monthly. Cancel anytime.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
            VStack(spacing: GrainSpacing.x2) {
                ForEach(VaultPlan.allCases, id: \.self) { plan in
                    planRow(plan, selected: plan == selected)
                }
            }
            privacyLine("sparkles", "Includes a monthly AI allowance. We'll alert you at 80% and 100%. Extra usage stays off until you set a monthly limit.")
            Spacer(minLength: GrainSpacing.x2)
            VStack(spacing: GrainSpacing.x2) {
                GrainButton("Continue with \(selected.title) · $\(selected.priceUSD)/month",
                            variant: .filled, size: .lg) {
                    Task { await model.continueToCheckout(plan: selected) }
                }
                privacyLine("lock", "No charge yet. Sign-in and checkout open in your browser.")
            }
        }
        .padding(.vertical, GrainSpacing.x4)
    }

    private func planRow(_ plan: VaultPlan, selected: Bool) -> some View {
        Button { model.selectPlan(plan) } label: {
            HStack(spacing: GrainSpacing.x3) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: GrainSpacing.x1) {
                        Text(plan.title).grainTextStyle(.body).fontWeight(.semibold)
                        if plan.recommended {
                            Text("Recommended")
                                .grainTextStyle(.caption)
                                .padding(.horizontal, GrainSpacing.x1).padding(.vertical, 1)
                                .background(GrainColor.amberBg)
                                .foregroundStyle(GrainColor.amberVivid)
                                .clipShape(Capsule())
                        }
                    }
                    Text(plan.blurb).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: GrainSpacing.x2)
                VStack(alignment: .trailing) {
                    Text("$\(plan.priceUSD)").grainTextStyle(.body).fontWeight(.semibold)
                    Text("/mo").grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? GrainColor.forgeBlue : GrainColor.borderLight)
            }
            .padding(GrainSpacing.x3)
            .background(GrainColor.surfaceElevated)
            .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous)
                .strokeBorder(selected ? GrainColor.forgeBlue : GrainColor.border,
                              lineWidth: selected ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: durable wait states

    private func waitScreen(label: String, title: String, body: String, spinning: Bool) -> some View {
        VStack(spacing: GrainSpacing.x4) {
            Spacer()
            if spinning { ProgressView().scaleEffect(1.4) }
            microLabel(label)
            Text(title).grainTextStyle(.title).multilineTextAlignment(.center)
            Text(body).grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, GrainSpacing.x6)
    }

    // MARK: live — "Your Vault is live"

    private var liveScreen: some View {
        VStack(spacing: GrainSpacing.x4) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64)).foregroundStyle(GrainColor.sage)
            microLabel("Live")
            Text("Your Vault is live").grainTextStyle(.title).multilineTextAlignment(.center)
            Text("Only your voice and your login open it. It stays isolated from every other Vault.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: GrainSpacing.x2) {
                GrainButton("Enter", variant: .filled, size: .lg) { model.dismiss() }
                privacyLine("key", "Kept under your keys.")
            }
        }
        .padding(.vertical, GrainSpacing.x6)
    }

    // MARK: shared bits

    private func microLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .kerning(1.5)
            .foregroundStyle(GrainColor.forgeBlue)
    }

    private func unlockRow(_ icon: String, _ title: String, _ meta: String) -> some View {
        HStack(spacing: GrainSpacing.x3) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(GrainColor.forgeBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).grainTextStyle(.body).fontWeight(.medium)
                Text(meta).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(GrainSpacing.x3)
        .background(GrainColor.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: GrainRadius.md, style: .continuous))
    }

    private func privacyLine(_ icon: String, _ text: String) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(GrainColor.textFaint)
            Text(text).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, GrainSpacing.x2)
    }
}

// MARK: - Live browser seam (ASWebAuthenticationSession)

#if canImport(AuthenticationServices) && canImport(UIKit)
/// The production VaultCheckoutBrowser: opens the external web checkout in an
/// ASWebAuthenticationSession, whose callback scheme is `foundryx` (the return deep link).
/// A user-dismissed sheet resolves to `nil` (dismissal ≠ failure — the funnel reconciles).
final class ASWebAuthenticationVaultBrowser: NSObject, VaultCheckoutBrowser {
    private let callbackScheme: String
    init(callbackScheme: String = "foundryx") { self.callbackScheme = callbackScheme }

    func open(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme) { callback, error in
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == .canceledLogin {
                        cont.resume(returning: nil)          // dismissed — not a failure
                    } else if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: callback)
                    }
                }
                session.presentationContextProvider = PresentationAnchorProvider.shared
                session.prefersEphemeralWebBrowserSession = false
                if !session.start() { cont.resume(returning: nil) }
            }
        }
    }
}

/// Supplies the key window as the presentation anchor for the auth session.
private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchorProvider()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

/// Bridges the live sign-in id_token (RemoteSession.idToken) to the funnel's synchronous
/// `idToken` seam — RootView keeps it fresh, the reconcile/checkout POSTs read it as Bearer.
final class VaultAuthTokenBox: @unchecked Sendable {
    static let shared = VaultAuthTokenBox()
    var token: String?
}

extension VaultFunnelModel {
    /// The deployed foundry-signup service (Cloud Run).
    static let signupServiceBase =
        URL(string: "https://foundry-signup-449450484577.us-central1.run.app")!

    /// The production funnel model: live signup client + ASWebAuthenticationSession browser +
    /// the durable CellStore, reading the current id_token from the shared box.
    @MainActor static func live() -> VaultFunnelModel {
        VaultFunnelModel(
            service: VaultSignupClient(baseURL: signupServiceBase),
            browser: ASWebAuthenticationVaultBrowser(),
            cellStore: CellStore(),
            idToken: { VaultAuthTokenBox.shared.token })
    }
}
#endif
