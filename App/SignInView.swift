import SwiftUI
import Grain

// FoundryX remote sign-in (M5 R1b) — branded entry gate. "Continue with Google /
// Microsoft" → resolve the account's designated desktop host → connect off-LAN
// through the blind relay. Styled with the Grain design system to match the app.
//
// LOGO: uses a placeholder brand mark (SF Symbol) until the real Foundry / Ville
// logo assets are added to Resources/Assets.xcassets (then swap `brandMark`).
//
// NOT YET COMPILE-VERIFIED in CI — validate in Xcode.
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
                    // The small-caps wordmark, same register as the welcome.
                    Text("F O U N D R Y X")
                        .font(.system(size: 13, design: .monospaced))
                        .kerning(3)
                        .foregroundStyle(GrainColor.textMuted)
                    Text("Record, transcribe, and chat, all on your phone. Sign in once; your recordings never leave this device.")
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
                    Text("End-to-end encrypted · your data stays on your devices")
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

    /// The brand mark is the INSTRUMENT, not an icon tile (design law from the
    /// welcome bakeoff: no app-icon tiles on ceremony surfaces). The same ring
    /// the user meets at the welcome, voice enrollment, and recording — at
    /// rest here, breathing.
    private var brandMark: some View {
        GrainVoiceRing(energy: 0.14, order: 0.55)
            .frame(width: 108, height: 108)
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
                        Text(p == .apple ? "Sign in with Apple"
                             : "Continue with \(p == .google ? "Google" : "Microsoft")")
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
        case .unconfigured: return "Sign-in not available in this build"
        case .signedOut: return "Sign in to get started"
        case .resolving: return "Signing in…"
        case .connected: return "Connected\(remote.email.map { " · \($0)" } ?? "")"
        // A phone-only user has no host by design — this is NOT an error. The app
        // runs entirely on-device; a computer is an optional upgrade in Settings.
        case .noHost: return "You're all set — everything runs on your phone. Add your computer anytime in Settings → Brain."
        case .error(let e): return e
        }
    }
}
