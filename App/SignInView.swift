import SwiftUI

// FoundryX remote sign-in (M5 R1b). "Continue with Google" / "Continue with
// Microsoft" → resolve the account's designated desktop host → connect off-LAN
// through the blind relay. When this build has no remote/OAuth config, it shows a
// clear "remote not available in this build" state and the app stays LAN-direct.
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
            VStack(alignment: .leading, spacing: 20) {
                Text("Reach your Mac from anywhere")
                    .font(.title2).bold()
                Text("Sign in with the same account you use for Foundry. Your phone connects to whichever Mac you designated as your host, end-to-end encrypted.")
                    .foregroundStyle(.secondary)

                statusRow

                if remote.isConfigured {
                    if remote.email == nil {
                        ForEach(remote.providers, id: \.self) { p in
                            Button {
                                Task { await remote.signIn(p) }
                            } label: {
                                Text("Continue with \(p == .google ? "Google" : "Microsoft")")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button("Sign out") { remote.signOut() }
                            .buttonStyle(.bordered)
                        Button("Retry connection") { Task { await remote.resolve() } }
                            .buttonStyle(.bordered)
                    }
                } else {
                    Text("Remote access isn't configured in this build (no OAuth client ids). The app works LAN-direct; add the FoundryXOAuth Info.plist keys + a host to enable remote.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Remote")
            .toolbar {
                if dismissable {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
                }
            }
            .task { await remote.restore() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(statusText).font(.subheadline)
            Spacer()
        }
    }

    private var statusColor: Color {
        switch remote.status {
        case .connected: return .green
        case .resolving: return .orange
        case .noHost, .error: return .red
        case .signedOut, .unconfigured: return .gray
        }
    }
    private var statusText: String {
        switch remote.status {
        case .unconfigured: return "Remote not available in this build"
        case .signedOut: return "Signed out"
        case .resolving: return "Connecting…"
        case .connected: return "Connected to your host\(remote.email.map { " · \($0)" } ?? "")"
        case .noHost: return "Signed in, but no Mac is your host yet — open Foundry on your Mac → Remote host → “Make this machine the host”."
        case .error(let e): return e
        }
    }
}
