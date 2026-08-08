import SwiftUI

/// Deck-faithful rendering for T2. Transport and custody stay in FoundryXKit; this view receives
/// state and emits intents so it can never manufacture an identity or touch a credential.
struct PocketOnboardingView: View {
    enum Screen { case setup, didNotFinish, acceptedNotDurable, ready, keepBothApps, education }

    let screen: Screen
    let action: (String) -> Void

    var body: some View {
        Group {
            switch screen {
            case .education: education
            default: ceremony(presentation)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var presentation: PocketSetupPresentation {
        switch screen {
        case .setup: return .setup
        case .didNotFinish: return .didNotFinish
        case .acceptedNotDurable: return .acceptedNotDurable
        case .ready: return .ready
        case .keepBothApps: return .keepBothApps
        case .education: return .setup
        }
    }

    private func ceremony(_ value: PocketSetupPresentation) -> some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 1).frame(width: 132, height: 132)
                Circle().stroke(Color.secondary.opacity(0.12), lineWidth: 1).frame(width: 94, height: 94)
                if screen == .ready { Text("READY").font(.caption.weight(.semibold)).foregroundStyle(.green) }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 30)

            Text(value.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            if !value.body.isEmpty {
                Text(value.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                    .padding(.top, 10)
            }
            Spacer()
            VStack(spacing: 12) {
                ForEach(Array(value.actions.enumerated()), id: \.offset) { index, title in
                    Button(title) { action(title) }
                        .buttonStyle(PocketActionButtonStyle(primary: index == 0))
                }
            }
        }
        .padding(20)
    }

    private var education: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("How your recorder works").font(.largeTitle.bold()).padding(.bottom, 28)
                ForEach(Array(PocketDeviceEducation.presentation.sections.enumerated()), id: \.offset) { _, section in
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    Text(section.body)
                        .font(.body)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("How it works")
    }
}

private struct PocketActionButtonStyle: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(primary ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(primary ? Color.accentColor : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(primary ? 0 : 0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
