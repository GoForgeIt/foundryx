// OnboardingFlowView — the first-run flow (runs ONCE, after the first sign-in):
//   1. Welcome — what FoundryX does, one breath.
//   2. Teach your voice — a ~20s read-aloud stored as the OWNER voice sample
//      (ambient track 20260710T2030 v3 AC2: the proof that later lets only the
//      owner command their agent). Skippable; honest retry when too short.
//   3. Ambient intelligence — an explicit OPT-IN (default OFF; declining changes
//      nothing). Mirrors the Settings toggle.
// Every step is skippable and reachable again from Settings; completing OR
// dismissing the flow sets the once-flag so it never re-prompts
// (features/onboarding-voice-and-ambient.feature).
//
// App target: uses MicFrameSource (mic permission + 20ms Opus frames — the same
// pipeline capture uses) and Grain components. FoundryXKit types are same-module.

import SwiftUI
import Grain

/// First-run flag, one place (mirrors AmbientPrefs' style).
enum OnboardingPrefs {
    static let completedKey = "foundryx.onboarding.completed"
    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: completedKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    /// Migration: a user with recordings predates this flow — mark them onboarded
    /// silently so the wizard never interrupts an established install
    /// (feature: "an already-onboarded user is never re-prompted").
    ///
    /// B2 (track 20260714T1800): this suppresses ONLY the voice/consent
    /// onboarding. The persona WELCOME has its own independent flag
    /// (`WelcomePrefs`, `foundryx.welcome.seen`) that migration never touches —
    /// established installs still see the welcome once after the update.
    static func migrateIfPriorUse(baseDir: URL) {
        guard !completed else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? []
        if entries.contains(where: { $0.hasPrefix("omi-") || $0.hasPrefix("mic-") }) {
            completed = true
        }
    }
}

struct OnboardingFlowView: View {
    let baseDir: URL
    /// Track 20260715T1502: when the welcome ALREADY fronted the app (the connect
    /// gate marked it seen), the flow starts at the voice step so a fresh install
    /// never meets the welcome twice (AC3/AC4). Settings' "Replay the full
    /// first-run tour" leaves this false — the full tour still opens with it.
    var skipWelcome: Bool = false
    let onDone: () -> Void

    private enum Step { case welcome, voice, ambient }
    @State private var step: Step

    init(baseDir: URL, skipWelcome: Bool = false, onDone: @escaping () -> Void) {
        self.baseDir = baseDir
        self.skipWelcome = skipWelcome
        self.onDone = onDone
        _step = State(initialValue: skipWelcome ? .voice : .welcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome: welcome
            case .voice: OnboardingVoiceStep(baseDir: baseDir) { step = .ambient }
            case .ambient: OnboardingAmbientStep { finish() }
            }
        }
        .padding(GrainSpacing.x6)
        .grainBackground()
        .interactiveDismissDisabled(false)
        .onDisappear { finish() }   // dismissing counts as done — never re-prompt
    }

    private func finish() {
        // Set the once-flag on first completion; ALWAYS call onDone so a re-run
        // from Settings ("Show the welcome tour") can still dismiss itself.
        if !OnboardingPrefs.completed { OnboardingPrefs.completed = true }
        // The flow OPENED with the persona welcome, so it counts as seen —
        // the standalone welcome must not re-present over a finished flow.
        WelcomePrefs.markSeen()
        onDone()
    }

    @ViewBuilder private var welcome: some View {
        PersonaWelcomeStep(onStart: { step = .voice }, onSkip: { finish() })
    }
}

// MARK: - The persona-routed welcome (track 20260713T0901)

/// The Night Shift welcome: one skeleton, words + artwork routed by persona
/// (features/persona-welcome.feature; layout per the prototype `renderWelcome`,
/// track 20260714T1800 §2). Copy comes from PersonaCopy, the fixed skeleton from
/// PersonaWelcomeLayout — THE tweak points once the design locks. The quiet
/// "What brings you here?" switch sits ABOVE the art and re-renders the screen
/// in place; the choice persists and is editable in Settings. Either action
/// marks the welcome seen (B2) — "Set up later" dismisses it forever.
// WelcomeConnectStatus moved to FoundryXKit (Sources/FoundryXKit/WelcomeFrontDoor.swift)
// so the connect-pill mapping is pure + `swift test`-covered (track 20260715T1502 re-cut).

/// The welcome's sign-in rendition (track 20260715T1502, Nick 2026-07-16): the
/// welcome surface IS the front door — a signed-out user meets the sign-in
/// provider buttons ON the welcome, never the old SignInView connection page.
struct WelcomeSignInActions {
    let providers: [AuthProvider]
    /// An honest caption under the buttons ("Signing in…", an error, or the
    /// unconfigured-build notice). nil = nothing to say.
    let statusText: String?
    let onTap: (AuthProvider) -> Void
}

struct PersonaWelcomeStep: View {
    let onStart: () -> Void
    let onSkip: () -> Void
    /// When non-nil the welcome is standing in as the post-sign-in connect gate:
    /// a quiet status pill renders above the actions and the action labels become
    /// "Take me in" / "Skip the welcome" (track 20260715T1502). nil = the original
    /// first-run + Settings-explorer welcome, unchanged.
    var connect: WelcomeConnectStatus? = nil
    /// When non-nil the welcome is the SIGNED-OUT front door: the action area
    /// renders the sign-in provider buttons instead of Continue / "Take me in",
    /// and nothing marks the welcome seen (seeing the door isn't the ceremony).
    var signIn: WelcomeSignInActions? = nil

    @State private var persona: OnboardingPersona = PersonaPrefs.persona()

    private var copy: PersonaWelcomeCopy { PersonaCopy.welcome(for: persona) }

    var body: some View {
        ZStack {
            GrainDotField(density: 0.5)
            // Prototype order (PersonaWelcomeLayout.order): wordmark → prompt +
            // persona switch → art → headline + body → actions.
            VStack(spacing: 0) {
                Text("F O U N D R Y X")
                    .font(.system(size: 11, design: .monospaced))
                    .kerning(3)
                    .foregroundStyle(GrainColor.textFaint)
                    .padding(.top, GrainSpacing.x6)

                chooser.padding(.top, GrainSpacing.x4)

                Spacer()
                art
                    .frame(width: 190, height: 190)
                    .padding(.bottom, GrainSpacing.x6)

                headline
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.sub)
                    .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, GrainSpacing.x2)
                    .frame(maxWidth: 300)

                Spacer()
                if let connect {
                    connectPill(connect).padding(.bottom, GrainSpacing.x3)
                }
                if let signIn {
                    signInActions(signIn)
                } else {
                    GrainButton(connect == nil ? PersonaWelcomeLayout.primaryAction : "Take me in",
                                variant: .filled, size: .regular) {
                        WelcomePrefs.markSeen()
                        onStart()
                    }
                    GrainButton(connect == nil ? PersonaWelcomeLayout.quietAction : "Skip the welcome",
                                variant: .text, size: .regular) {
                        WelcomePrefs.markSeen()
                        onSkip()
                    }
                }
                HStack(spacing: 5) {
                    Image(grain: .key).font(.system(size: 10, weight: .light))
                    Text(copy.lockLine)
                }
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                .multilineTextAlignment(.center)
                .padding(.top, GrainSpacing.x2)
                .padding(.bottom, GrainSpacing.x4)
            }
        }
        // Self-contained night surface, so the welcome looks right wherever it's
        // shown (first-run flow, the Settings explorer, the dev preview) — the
        // dot field floats over the Grain night gradient, not bare black.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .grainBackground()
        .animation(.easeOut(duration: 0.35), value: persona)
    }

    /// Headline with the persona's emphasis span in forge blue.
    private var headline: Text {
        let h = copy.headline
        guard !copy.emphasis.isEmpty, let range = h.range(of: copy.emphasis) else {
            return Text(h).foregroundColor(GrainColor.ink)
        }
        let before = String(h[h.startIndex..<range.lowerBound])
        let em = String(h[range])
        let after = String(h[range.upperBound...])
        return Text(before).foregroundColor(GrainColor.ink)
            + Text(em).foregroundColor(GrainColor.forgeBlue)
            + Text(after).foregroundColor(GrainColor.ink)
    }

    /// "What brings you here?" — three quiet rows; choosing re-renders in place.
    private var chooser: some View {
        VStack(spacing: GrainSpacing.x2) {
            Text(PersonaWelcomeLayout.prompt)
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            HStack(spacing: GrainSpacing.x2) {
                ForEach(OnboardingPersona.allCases, id: \.self) { p in
                    Button {
                        persona = p
                        PersonaPrefs.set(p)
                    } label: {
                        Text(p.chooserLabel)
                            .grainTextStyle(.caption)
                            .foregroundStyle(persona == p ? GrainColor.ink : GrainColor.textMuted)
                            .padding(.horizontal, GrainSpacing.x3)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(persona == p ? GrainColor.forgeBlueBg : .clear)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    persona == p ? GrainColor.forgeBlueBorder : GrainColor.borderFaint,
                                    lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The sign-in front door's action area (track 20260715T1502 re-cut): the same
    /// provider buttons the old SignInView carried, now living ON the welcome. An
    /// empty provider list (unconfigured build) shows only the honest caption.
    @ViewBuilder private func signInActions(_ signIn: WelcomeSignInActions) -> some View {
        VStack(spacing: GrainSpacing.x2) {
            ForEach(signIn.providers, id: \.self) { p in
                Button { signIn.onTap(p) } label: {
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
            if let statusText = signIn.statusText {
                Text(statusText)
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, GrainSpacing.x4)
    }

    /// The connect-gate status pill (track 20260715T1502): a small settled/working
    /// dot + the live status text. All Grain tokens — reads correctly light + dark.
    @ViewBuilder private func connectPill(_ status: WelcomeConnectStatus) -> some View {
        HStack(spacing: GrainSpacing.x2) {
            Circle()
                .fill(status.settled ? GrainColor.sage : GrainColor.amber)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.text)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
        }
        .padding(.horizontal, GrainSpacing.x3)
        .padding(.vertical, GrainSpacing.x1)
        .background(Capsule().fill(GrainColor.surfaceElevated))
        .overlay(Capsule().strokeBorder(GrainColor.border, lineWidth: 1))
    }

    @ViewBuilder private var art: some View {
        switch persona {
        case .expert:
            GrainStrikeList(
                lines: ["The filing.", "The chasing.", "The scheduling.", "The follow-ups."],
                survivor: "The judgment stays."
            )
        case .individual:
            GrainCatchRing()
        case .firm:
            GrainPerimeter()
                .frame(width: 170, height: 150)
        }
    }
}

/// The calm "breath" — the brand mark slowly breathing (≈4s in/out, the pace of a
/// resting breath). Used on the welcome step; cheap, no assets, reads as alive
/// rather than loading.
struct BreathingMark: View {
    @State private var inhale = false

    var body: some View {
        ZStack {
            Circle()
                .fill(GrainColor.forgeBlueBg)
                .frame(width: 120, height: 120)
                .scaleEffect(inhale ? 1.12 : 0.96)
                .opacity(inhale ? 0.9 : 0.6)
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(GrainColor.forgeBlue)
                .scaleEffect(inhale ? 1.05 : 0.98)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true)) {
                inhale = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Step 2: teach your voice

/// Records the owner read-aloud through the SAME mic → 20ms-Opus pipeline capture
/// uses, auto-stopping at the target length. Too short = honest retry, never a
/// silent half-sample.
struct OnboardingVoiceStep: View {
    let baseDir: URL
    /// Hide the flow's Continue/Skip footer when hosted standalone in Settings.
    var showsFooter: Bool = true
    let onNext: () -> Void

    /// ~20s of 20ms frames.
    static let targetFrames = 1_000

    private enum Phase: Equatable { case intro, recording(Int), saved, tooShort(Int) }
    @State private var phase: Phase = .intro
    @State private var mic: MicFrameSource?
    @State private var frames: [Data] = []
    /// Live voice energy for the ring, from recent Opus frame sizes (silence
    /// frames are a few bytes; speech frames are tens — the door's VAD uses the
    /// same property). Smoothed on append.
    @State private var ringEnergy: Double = 0.08

    /// Ring organization: how much of the read is done. Settles to 1 on save.
    private var ringOrder: Double {
        switch phase {
        case .intro: return 0.5
        case .recording(let n): return 0.15 + 0.85 * min(1, Double(n) / Double(Self.targetFrames))
        case .saved: return 1
        case .tooShort: return 0.2
        }
    }

    /// The read-aloud doubles as the product introduction: in the ~20 seconds it
    /// takes to speak, it teaches what FoundryX does, where the data lives, the
    /// agent's name, and the "look that up" ritual — so enrolling the voice IS the
    /// walkthrough. Keep any edits speakable (no abbreviations, no URLs).
    private let passage = """
    “This is my FoundryX. It remembers my conversations for me, \
    and everything it hears stays on my own devices. \
    When I say something like ‘I’ll have to look that up,’ \
    it can find the answer in my own memory. \
    And when I call my agent — Foundry — it acts for me, \
    and answers to my voice alone. \
    A voice is a kind of key, and this one is mine.”
    """

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            // The instrument: the SAME ring that later pulses around every recording.
            // Here its order follows the read (chaos → settled band as they finish);
            // its energy follows the live voice (Opus frame size ≈ voice energy).
            ZStack {
                GrainVoiceRing(energy: ringEnergy, order: ringOrder)
                    .frame(width: 132, height: 132)
                Image(grain: .mic)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(GrainColor.forgeBlue)
            }
            .frame(maxWidth: .infinity)

            Text("Teach it your voice").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("Read this aloud (~20 seconds). Your voice becomes the key that lets only YOU command your agent. It never leaves your devices.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)

            Text(passage)
                .grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                .padding(GrainSpacing.x4)
                .background(RoundedRectangle(cornerRadius: 12).fill(GrainColor.forgeBlueBg))

            switch phase {
            case .intro:
                GrainButton("Start recording", variant: .filled, size: .regular) { start() }
            case .recording(let n):
                ProgressView(value: Double(min(n, Self.targetFrames)),
                             total: Double(Self.targetFrames))
                Text("Keep reading… \(max(0, (Self.targetFrames - n) / 50)) s left")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                GrainButton("Stop", variant: .text, size: .regular) { stop() }
            case .saved:
                Label("Your voice is now your key", systemImage: "key.fill")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.sage)
                Text("From here on, your agent answers to you — and only you. The key stays on your devices.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            case .tooShort(let n):
                Text("That was only ~\(n / 50) seconds — a stable voice key needs about 15. Give it another read?")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.dangerRed)
                GrainButton("Try again", variant: .filled, size: .regular) { start() }
            }

            Spacer()
            if showsFooter {
                GrainButton(phase == .saved ? "Continue" : "Skip", variant: .outlined, size: .regular) {
                    stopMicIfNeeded()
                    onNext()
                }
            }
        }
        .onDisappear { stopMicIfNeeded() }
    }

    private func start() {
        frames = []
        phase = .recording(0)
        let source = MicFrameSource()
        source.onFrame = { data in
            Task { @MainActor in
                guard case .recording = phase else { return }
                frames.append(data)
                phase = .recording(frames.count)
                // Frame size → voice energy (smoothed): ~3 bytes silence, ~60+ speech.
                let level = min(1.0, Double(data.count) / 70.0)
                ringEnergy += (level - ringEnergy) * 0.25
                if frames.count >= Self.targetFrames { stop() }
            }
        }
        mic = source
        source.start()
    }

    private func stop() {
        stopMicIfNeeded()
        do {
            try OwnerVoiceStore.save(frames: frames, baseDir: baseDir)
            phase = .saved
        } catch {
            phase = .tooShort(frames.count)
        }
    }

    private func stopMicIfNeeded() {
        mic?.stop()
        mic = nil
    }
}

/// The voice step as a standalone Settings screen ("Your voice" row) — same
/// recorder, no flow chrome. Re-teaching replaces the stored sample.
struct OnboardingVoiceStandalone: View {
    var body: some View {
        ScrollView {
            OnboardingVoiceStep(baseDir: CaptureWAL.documentsCaptures(), showsFooter: false) { }
                .padding(GrainSpacing.x6)
        }
        .navigationTitle("Your voice")
        .grainBackground()
    }
}

// MARK: - Step 3: ambient opt-in

struct OnboardingAmbientStep: View {
    let onDone: () -> Void
    @State private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            Text("Ambient intelligence").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("While you record, your phone can privately notice moments like “I'll have to look that up” and offer to help — everything stays on your phone until you accept a suggestion.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
            Text("Off by default. You can change this any time in Settings.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

            if enabled {
                Label("On — check your lock screen", systemImage: "bell.badge.fill")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.sage)
                Text("We just sent a sample nudge so the first real one is never a surprise. Your agent answers to “Foundry” — rename it in Settings.")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }

            Spacer()
            if enabled {
                GrainButton("Done", variant: .filled, size: .regular) { onDone() }
                    .padding(.bottom, GrainSpacing.x4)
            } else {
                GrainButton("Turn it on", variant: .filled, size: .regular) {
                    UserDefaults.standard.set(true, forKey: AmbientPrefs.enabledKey)
                    // The agent answers to "Foundry" out of the box (renameable in
                    // Settings) — a named agent is the invocation ritual.
                    if UserDefaults.standard.string(forKey: AmbientPrefs.agentNameKey) == nil {
                        UserDefaults.standard.set("Foundry", forKey: AmbientPrefs.agentNameKey)
                    }
                    // Deterministic first-feel: fire the sample nudge NOW, while
                    // they're looking, so the first real one is familiar.
                    AmbientNotifier.postPreview()
                    enabled = true
                }
                GrainButton("Not now", variant: .outlined, size: .regular) { onDone() }
                    .padding(.bottom, GrainSpacing.x4)
            }
        }
    }
}
