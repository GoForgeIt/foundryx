import SwiftUI
import Grain

// FoundryX remote sign-in (M5 R1b) — branded entry gate. "Continue with Google /
// Microsoft" → resolve the account's designated desktop host → connect off-LAN
// through the blind relay. Styled with the Grain design system to match the app.
//
// LOGO: the real Grain brand mark (`GrainMark`, the Foundry blue anvil) on its warm
// app-icon card — vectorized in the design system, so no asset-catalog imageset needed.
struct SignInView: View {
    @ObservedObject var remote: RemoteSession
    var onDone: () -> Void
    /// When shown as the entry GATE (not a sheet) there's nothing to dismiss to,
    /// so hide "Done". Only the post-connect sheet (sign-out/status) shows it.
    var dismissable: Bool = true

    var body: some View {
        NavigationStack {
            ZStack {
                // Subtle forge-blue gradient wash behind the Grain background.
                LinearGradient(
                    colors: [GrainColor.forgeBlue.opacity(0.18), GrainColor.surfaceElevated.opacity(0.0)],
                    startPoint: .top, endPoint: .center
                )
                .ignoresSafeArea()

                VStack(spacing: GrainSpacing.x4) {
                    Spacer()

                    brandMark
                    Text("FoundryX")
                        .grainTextStyle(.title)
                        .foregroundStyle(GrainColor.ink)
                    Text("Your Foundry — in your pocket, anywhere.")
                        .grainTextStyle(.body)
                        .foregroundStyle(GrainColor.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, GrainSpacing.x6)

                    statusPill

                    VStack(spacing: GrainSpacing.x2) {
                        content
                    }
                    .padding(.horizontal, GrainSpacing.x4)
                    .padding(.top, GrainSpacing.x2)

                    Spacer()
                    Text("End-to-end encrypted to your Foundry · you choose what stays private")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .padding(.bottom, GrainSpacing.x3)
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, GrainSpacing.x4)
            }
            .grainBackground()
            .navigationTitle("")
            .toolbar {
                if dismissable {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
                }
            }
            .task { await remote.restore() }
        }
    }

    /// The Foundry brand mark — Grain's blue-anvil `GrainMark` on its warm rounded
    /// card. `onCard: true` already supplies the card fill and shadow, so no wrapper.
    private var brandMark: some View {
        GrainMark(size: 84, onCard: true)
    }

    @ViewBuilder private var content: some View {
        if !remote.isConfigured {
            Text("Remote access isn't configured in this build.")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textFaint)
                .multilineTextAlignment(.center)
        } else if remote.email == nil {
            ForEach(remote.providers, id: \.self) { p in
                Button { Task { await remote.signIn(p) } } label: {
                    HStack(spacing: GrainSpacing.x2) {
                        Image(systemName: p == .google ? "globe" : "building.2.fill")
                        Text("Continue with \(p == .google ? "Google" : "Microsoft")")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, GrainSpacing.x3)
                    .background(GrainColor.forgeBlue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        } else if remote.status == .noHost {
            // Signed in, but no Mac is claimed as host yet — the first-run wall. Promote
            // the "claim this Mac" steps from the status pill into a clear, actionable card.
            VStack(spacing: GrainSpacing.x3) {
                GrainEmptyState(
                    systemImage: "desktopcomputer",
                    title: "Claim your Mac as host",
                    message: "Your Foundry runs on your Mac. On it, open Foundry → Remote host → “Make this machine the host,” then tap Retry.",
                    action: ("Retry connection", { Task { await remote.resolve() } })
                )
                GrainButton("Sign out", variant: .text, size: .sm) { remote.signOut() }
            }
        } else if case .error(let detail) = remote.status {
            VStack(spacing: GrainSpacing.x3) {
                GrainErrorState(
                    title: "Can't reach your Foundry",
                    message: detail,
                    retry: { Task { await remote.resolve() } }
                )
                GrainButton("Sign out", variant: .text, size: .sm) { remote.signOut() }
            }
        } else {
            GrainButton("Retry connection", variant: .filled, size: .sm) {
                Task { await remote.resolve() }
            }
            GrainButton("Sign out", variant: .text, size: .sm) { remote.signOut() }
        }
    }

    private var statusPill: some View {
        HStack(spacing: GrainSpacing.x2) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(statusText)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, GrainSpacing.x3)
        .padding(.vertical, GrainSpacing.x2)
        .background(GrainColor.surfaceElevated)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
        .padding(.horizontal, GrainSpacing.x4)
    }

    private var statusColor: Color {
        switch remote.status {
        case .connected: return GrainColor.sage
        case .resolving: return GrainColor.amber
        case .noHost, .error: return GrainColor.amber
        case .signedOut, .unconfigured: return GrainColor.inkTertiary
        }
    }
    private var statusText: String {
        switch remote.status {
        case .unconfigured: return "Remote not available in this build"
        case .signedOut: return "Sign in to reach your Foundry"
        case .resolving: return "Connecting…"
        case .connected: return "Connected\(remote.email.map { " · \($0)" } ?? "")"
        case .noHost: return "No Mac is your host yet"
        case .error(let e): return e
        }
    }
}
