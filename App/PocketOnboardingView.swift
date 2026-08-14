import SwiftUI

/// Deck-faithful rendering for T2. Transport and custody stay in FoundryXKit; this view receives
/// state and emits intents so it can never manufacture an identity or touch a credential.
struct PocketOnboardingView: View {
    enum Screen {
        case setup, didNotFinish, acceptedNotDurable, ready, keepBothApps, education
        /// Reached from the help link with no recorder in hand: nothing was connected, so
        /// there is nothing on this screen to set up.
        case setupUnavailable
        /// The owner already HAS this recorder's key, because another app set the recorder up.
        /// Entering it is not minting it.
        case enterExistingKey
        /// THE DECISION SCREEN, AND THE ONLY DOOR TO A MINT. Because nobody has ever observed
        /// what an already-keyed recorder does with a second key write, the write is a
        /// possibly destructive act and may not happen without an explicit confirmation.
        case mintConsent
        /// The recorder refused the new key — another app owns it, and nothing changed.
        case mintRefused
        /// The recorder acknowledged the key and could not prove it kept it.
        case mintNotVerified
        /// The maker's factory-reset gesture, with the cost stated before the steps.
        case factoryReset
        /// §10 custody: the owner looking at their own recorder's key.
        case keyCustody
        /// This iPhone's secure storage refused the key, so the recorder was never asked.
        case keyNotKept
        /// FoundryX may hold this recorder's key and could not read it. Deliberately NOT the
        /// mint offer: a second key would replace one the recorder may already be using.
        case custodyUnreadable
        /// The recorder never answered the key Solleva holds. Deliberately NOT a caption and
        /// NOT the mint offer: silence is not evidence that the key is wrong, and the way out
        /// is to replace the key or to ask the recorder again.
        case handshakeUnanswered
    }

    let screen: Screen
    /// What the last submission earned, already worded by
    /// `PocketSessionKeyEntryPresentation`. The view never composes this itself — a sentence
    /// invented in a SwiftUI body is a second, unasserted implementation of the app's voice.
    var keyEntryMessage: String? = nil
    var isSubmittingKey: Bool = false
    var onSubmitKey: ((String) -> Void)? = nil
    /// The key this recorder was set up with, and ONLY once the owner has asked to see it.
    /// `nil` covers both "not asked for yet" and "custody has none", which the screen words
    /// differently.
    var revealedKey: String? = nil
    var onRevealKey: (() -> Void)? = nil
    var onCopyKey: (() -> Void)? = nil
    var didCopyKey: Bool = false
    /// Custody was asked and had nothing — a real state after a restore from a backup that
    /// predates the mint, and a different sentence from "you haven't asked yet".
    var revealedKeyIsKnownMissing: Bool = false
    /// WHETHER THE SYNCHRONISED COPY ACTUALLY EXISTS, asked of the store rather than assumed.
    /// It defaults to `false` so a caller that forgets to ask gets the sentence that tells the
    /// owner to write the key down — the safe direction to be wrong in, on a screen whose whole
    /// subject is a credential that cannot be recovered from the hardware.
    var recoveryCopyExists: Bool = false
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
            // EVERY ONE OF THESE DRAWS `drawnActions`, NOT ITS OWN ARRAY. The buttons a screen
            // offers are the whole subject of the state-exit gate, and a body nothing in this
            // repository can execute is the one place they must not be typed a second time.
            case .mintConsent:
                guidance(title: PocketMintConsentPresentation.title,
                         sections: PocketMintConsentPresentation.sections,
                         actions: drawnActions)
            case .mintRefused:
                guidance(title: PocketMintRefusedPresentation.title,
                         sections: [
                            .init(title: "What happened",
                                  body: PocketMintRefusedPresentation.body),
                            .init(title: "What you can do",
                                  body: PocketMintRefusedPresentation.options),
                         ],
                         actions: drawnActions)
            case .mintNotVerified:
                guidance(title: PocketMintNotVerifiedPresentation.title,
                         sections: [
                            .init(title: "What Solleva knows",
                                  body: PocketMintNotVerifiedPresentation.body),
                         ],
                         actions: drawnActions)
            case .factoryReset:
                guidance(title: PocketFactoryResetPresentation.title,
                         sections: PocketFactoryResetPresentation.sections,
                         actions: drawnActions)
            case .keyCustody: keyCustody
            default: ceremony(presentation)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// WHICH COPY A SCREEN DRAWS. Internal rather than private so the app-hosted scenario lane
    /// can hold "the state the model set is the state the view renders" — a model that lands on
    /// a screen the view maps to `.setup` is a dead end with a friendly title, and there is no
    /// other way to notice from outside a `body` nothing in this repository can execute.
    var presentation: PocketSetupPresentation {
        switch screen {
        case .setup: return .setup
        case .didNotFinish: return .didNotFinish
        case .acceptedNotDurable: return .acceptedNotDurable
        case .ready: return .ready
        case .keepBothApps: return .keepBothApps
        case .setupUnavailable: return .setupUnavailable
        case .keyNotKept: return .keyNotKept
        case .custodyUnreadable: return .custodyUnreadable
        case .handshakeUnanswered: return .handshakeUnanswered
        case .education, .enterExistingKey, .mintConsent, .mintRefused, .mintNotVerified,
             .factoryReset, .keyCustody:
            return .setup
        }
    }

    /// EVERY BUTTON THIS SCREEN PUTS IN FRONT OF A PERSON, AND THE BODY ABOVE DRAWS THIS.
    ///
    /// WHY IT EXISTS AT ALL. `presentation` answers only for the screens rendered by `ceremony`;
    /// the four `guidance` screens — the consent decision, a refused mint, an unproven mint, and
    /// the maker's reset — draw arrays of their own, and `presentation` maps every one of them to
    /// `.setup`. So the buttons on the four screens where the owner has the most to decide were
    /// invisible from outside a `body` nothing in this repository can execute. That is exactly
    /// the blind spot the state-exit register is held over, and a register whose measurement had
    /// to guess at four of its rows would be worth nothing.
    ///
    /// IT IS WHAT THE BODY DRAWS, NOT A SECOND OPINION ABOUT IT. Each `guidance` call above
    /// passes `drawnActions`, so this cannot drift from the screen: a divergence would need
    /// somebody to reintroduce the literal array they just took out.
    var drawnActions: [String] {
        switch screen {
        case .mintConsent:      return PocketMintConsentPresentation.actions
        case .mintRefused:      return PocketMintRefusedPresentation.actions
        case .mintNotVerified:  return PocketMintNotVerifiedPresentation.actions
        case .factoryReset:     return PocketFactoryResetPresentation.actions
        // §10 custody draws its reveal / copy / hide as CLOSURES the sheet owns; `Done` is the
        // only one that reaches `action(title)` and therefore the only one the routing table
        // can be asked about.
        case .keyCustody:       return [PocketKeyCustodyPresentation.doneAction]
        // The field's exit is its submit closure, and the education sheet's is the sheet. Neither
        // has a routed button, and `[]` here is the claim rather than an omission.
        case .enterExistingKey, .education: return []
        default:                return presentation.actions
        }
    }

    /// ONE RENDERER FOR EVERY SCREEN THAT IS PROSE PLUS CHOICES. Each of the four screens it
    /// draws is a decision the owner has to make with facts in front of them, so none of them
    /// can be a title and a button — and none of them may have its sentences typed here, which
    /// is why every one arrives as a `PocketEducationSection` from the kit.
    private func guidance(title: String,
                          sections: [PocketEducationSection],
                          actions: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 24)
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    Text(section.body)
                        .font(.body)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 26)
                }
                VStack(spacing: 12) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, label in
                        Button(label) { action(label) }
                            .buttonStyle(PocketActionButtonStyle(primary: index == 0))
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(title)
    }

    /// §10 CUSTODY, ON ITS OWN SCREEN AND NOT IN THE CEREMONY.
    ///
    /// Design §3.4 forbids any reveal, copy, share or export affordance ON THE SETUP SCREEN,
    /// and says in the same breath that surfacing the value is "a separately owned security
    /// change, not a setup step". This is that separate screen. It is reached deliberately from
    /// a recorder the owner already owns, the value is HIDDEN until asked for
    /// (`isRevealedByDefault` is false), and the app-switcher shield the entry field uses
    /// covers this screen for the same reason: the snapshot iOS writes on backgrounding is a
    /// file on disk outside the Keychain.
    private var keyCustody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(PocketKeyCustodyPresentation.title)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 24)

                if let revealedKey {
                    Text(revealedKey)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .privacySensitive()
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("pocket-key-custody-value")
                    HStack(spacing: 12) {
                        Button(PocketKeyCustodyPresentation.copyAction) { onCopyKey?() }
                            .buttonStyle(PocketActionButtonStyle(primary: true))
                            .accessibilityIdentifier("pocket-key-custody-copy")
                        Button(PocketKeyCustodyPresentation.hideAction) { onRevealKey?() }
                            .buttonStyle(PocketActionButtonStyle(primary: false))
                    }
                    .padding(.top, 12)
                    if didCopyKey {
                        Text(PocketKeyCustodyPresentation.copiedConfirmation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                } else {
                    Button(PocketKeyCustodyPresentation.revealAction) { onRevealKey?() }
                        .buttonStyle(PocketActionButtonStyle(primary: true))
                        .accessibilityIdentifier("pocket-key-custody-reveal")
                    if let missing = revealedKeyIsKnownMissing ? PocketKeyCustodyPresentation.missingLine : nil {
                        Text(missing)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                }

                Button(PocketKeyCustodyPresentation.doneAction) { action(PocketKeyCustodyPresentation.doneAction) }
                    .buttonStyle(PocketActionButtonStyle(primary: false))
                    .padding(.top, 16)

                ForEach(Array(PocketKeyCustodyPresentation
                    .sections(hasRecoveryCopy: recoveryCopyExists).enumerated()),
                        id: \.offset) { _, section in
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 28)
                        .padding(.bottom, 8)
                    Text(section.body)
                        .font(.body)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(PocketKeyCustodyPresentation.title)
        .overlay {
            if scenePhase != .active { keyEntryPrivacyShield }
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

    /// The §10 custody wiring, for the same reason and in the same shape as `keyEntry`.
    func keyCustody(revealed: String?,
                    didCopy: Bool,
                    knownMissing: Bool = false,
                    hasRecoveryCopy: Bool = false,
                    onReveal: @escaping () -> Void,
                    onCopy: @escaping () -> Void) -> PocketOnboardingView {
        var copy = self
        copy.revealedKey = revealed
        copy.didCopyKey = didCopy
        copy.revealedKeyIsKnownMissing = knownMissing
        copy.recoveryCopyExists = hasRecoveryCopy
        copy.onRevealKey = onReveal
        copy.onCopyKey = onCopy
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
