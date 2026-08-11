import SwiftUI

/// Deck-faithful rendering for T2. Transport and custody stay in FoundryXKit; this view receives
/// state and emits intents so it can never manufacture an identity or touch a credential.
struct PocketOnboardingView: View {
    enum Screen {
        case setup, didNotFinish, acceptedNotDurable, ready, keepBothApps, education
        /// Design §3.6 — the state every Pocket setup is actually in today. Provisioning is
        /// gated (T2 req 3), so this is what "Set up Pocket" honestly leads to.
        case setupUnavailable
        /// The one case §3.6 never covered: the owner already HAS this recorder's key,
        /// because another app set the recorder up. Entering it is not minting it, so this
        /// screen exists without the provisioning gate moving at all.
        case enterExistingKey
    }

    let screen: Screen
    /// What the last submission earned, already worded by
    /// `PocketSessionKeyEntryPresentation`. The view never composes this itself — a sentence
    /// invented in a SwiftUI body is a second, unasserted implementation of the app's voice.
    var keyEntryMessage: String? = nil
    var isSubmittingKey: Bool = false
    var onSubmitKey: ((String) -> Void)? = nil
    let action: (String) -> Void

    /// The candidate the owner is typing. It lives here for exactly as long as it takes to
    /// hand to the kit's coordinator — `onSubmitKey` clears it — and goes nowhere else: no
    /// log, no diagnostic, no analytics, no error string.
    @State private var sessionKeyDraft = ""

    /// THE APP-SWITCHER SNAPSHOT IS A FILE ON DISK. Every time iOS backgrounds this app it
    /// writes a picture of the visible window into the container, outside the Keychain and
    /// outside anything this app deletes. Someone re-checking their HCI trace mid-entry
    /// backgrounds this exact screen, so the screen has to be uninteresting by then.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch screen {
            case .education: education
            case .enterExistingKey: keyEntry
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
        case .setupUnavailable: return .setupUnavailable
        case .education, .enterExistingKey: return .setup
        }
    }

    /// THE FIELD, AND THE HONEST ACCOUNT OF WHERE THE VALUE COMES FROM.
    ///
    /// Every sentence below is drawn from `PocketSessionKeyEntryPresentation` — including the
    /// two capture routes, which are rendered from `sections` rather than typed out here, so
    /// dropping one of them fails a test instead of quietly shipping half the instructions.
    private var keyEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(PocketSessionKeyEntryPresentation.title)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 12)
                Text(PocketSessionKeyEntryPresentation.intro)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)

                Text(PocketSessionKeyEntryPresentation.fieldLabel.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                // SECURE ENTRY, AND NOT FOR THE DOTS.
                //
                // A session key in a plain `TextField` is a credential rendered in cleartext:
                // it goes into the window snapshot iOS writes on backgrounding, it is read
                // aloud by VoiceOver, it is captured by screen recording and mirroring — and,
                // worst, every character is delivered to whatever third-party keyboard has
                // Full Access, which has network. `isSecureTextEntry` is the ONLY thing that
                // makes iOS fall back to the system keyboard; `autocorrectionDisabled` does
                // not. `.password` keeps the value out of keyboard learning, and
                // `.asciiCapable` keeps the field from producing characters the protocol
                // cannot carry in the first place.
                SecureField(PocketSessionKeyEntryPresentation.fieldPrompt,
                            text: $sessionKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .textContentType(.password)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .privacySensitive()
                    .disabled(isSubmittingKey)
                    .accessibilityIdentifier("pocket-session-key-field")

                // WHAT SECURE ENTRY COSTS, PAID BACK WITHOUT THE CREDENTIAL. Typing 16
                // characters off a Wireshark trace into a field you cannot read is how a typo
                // happens, and a typo is expensive. A COUNT is not a credential — the same
                // reason `PocketSessionKeyDefect.wrongLength` carries an `Int`.
                Text(PocketSessionKeyEntryPresentation.progress(entered: sessionKeyDraft.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .accessibilityIdentifier("pocket-session-key-progress")

                if let keyEntryMessage {
                    Text(keyEntryMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .accessibilityIdentifier("pocket-session-key-message")
                }

                Button(PocketSessionKeyEntryPresentation.submitAction) {
                    // HANDED OVER AND DROPPED. The coordinator owns it from here; keeping a
                    // copy in view state past the submission buys nothing and keeps a live
                    // credential in the view hierarchy for as long as the screen is up.
                    let candidate = sessionKeyDraft
                    sessionKeyDraft = ""
                    onSubmitKey?(candidate)
                }
                .buttonStyle(PocketActionButtonStyle(primary: true))
                .disabled(isSubmittingKey)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .accessibilityIdentifier("pocket-session-key-submit")

                ForEach(Array(PocketSessionKeyEntryPresentation.sections.enumerated()),
                        id: \.offset) { _, section in
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
        .navigationTitle(PocketSessionKeyEntryPresentation.title)
        // THE SNAPSHOT NEVER SEES THE FIELD. iOS takes its window picture as the app leaves
        // the foreground, so the cover has to be up by `.inactive`, not by `.background`.
        .overlay {
            if scenePhase != .active { keyEntryPrivacyShield }
        }
    }

    /// Opaque, and opaque on purpose — a blur or a redaction still photographs the layout of
    /// what it is covering, and this cover exists to make the picture worthless.
    private var keyEntryPrivacyShield: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
            .accessibilityHidden(true)
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

extension PocketOnboardingView {
    /// The key-entry wiring as a MODIFIER rather than as constructor arguments.
    ///
    /// Two shipped gates assert that `App/DeviceScreen.swift` contains
    /// `PocketOnboardingView(screen: attach.ceremonyScreen)` and
    /// `PocketOnboardingView(screen: .setupUnavailable)` verbatim — that is how they hold
    /// "a tap that lands on the gated setup state reaches the §3.6 screen". Widening the
    /// initialiser would have quietly made both of them unfalsifiable, so the extra state
    /// arrives here instead and the call sites keep the shape those gates read.
    func keyEntry(message: String?,
                  isSubmitting: Bool,
                  onSubmit: @escaping (String) -> Void) -> PocketOnboardingView {
        var copy = self
        copy.keyEntryMessage = message
        copy.isSubmittingKey = isSubmitting
        copy.onSubmitKey = onSubmit
        return copy
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
