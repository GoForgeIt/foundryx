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
import AVFoundation
import Grain

/// First-run flag, one place (mirrors AmbientPrefs' style).
enum OnboardingPrefs {
    static let completedKey = "foundryx.onboarding.completed"
    static var completed: Bool {
        get {
            AccountPreferences.value(
                AccountPreferenceCatalog.onboardingCompleted,
                default: false)
        }
        set {
            _ = AccountPreferences.write(
                newValue,
                for: AccountPreferenceCatalog.onboardingCompleted)
        }
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

    /// The live capture surface, when the caller has one. The ending's first-note step
    /// drives the REAL capture path, so without a manager the flow stops after the
    /// ambient step exactly as it used to (Settings' "replay the tour" passes one; any
    /// future call site that cannot simply gets the old ending).
    var manager: CaptureManager? = nil
    /// The account-scoped brain preference the destination step writes. `BrainChoice` IS
    /// the destination choice — there is deliberately no second preference for it.
    ///
    /// NON-OPTIONAL, deliberately. It used to default to nil and the destination step
    /// fell back to `brains ?? BrainStore()` — a throwaway store that SWALLOWS the
    /// choice. Every "connect me to my Vault" tap on that path would have written the
    /// brain nobody reads, silently, with nothing red anywhere. Both call sites already
    /// pass the app's store; this makes that a compile-time fact.
    var brains: BrainStore
    /// Chose the Vault at the destination step — the host hands off to the Vault funnel
    /// (cell provisioning) instead of just closing the flow.
    var onChooseVault: (() -> Void)? = nil

    @State private var step: OnboardingStep
    /// What the user said in their first note, handed to the ask-it step.
    @State private var firstNoteText = ""

    init(baseDir: URL,
         skipWelcome: Bool = false,
         manager: CaptureManager? = nil,
         brains: BrainStore,
         onChooseVault: (() -> Void)? = nil,
         onDone: @escaping () -> Void) {
        self.baseDir = baseDir
        self.skipWelcome = skipWelcome
        self.manager = manager
        self.brains = brains
        self.onChooseVault = onChooseVault
        self.onDone = onDone
        _step = State(initialValue: skipWelcome ? .voice : .welcome)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome: welcome
            case .voice: OnboardingVoiceStep(baseDir: baseDir) { step = .ambient }
            case .ambient:
                OnboardingAmbientStep {
                    // The ending exists only where the real capture path is reachable.
                    if manager != nil { step = .firstNote } else { finish() }
                }
            case .firstNote:
                if let manager {
                    OnboardingFirstNoteStep(manager: manager, live: manager.live,
                                            onNext: { text in
                                                firstNoteText = text
                                                step = .askIt
                                            },
                                            onSkip: { finish() })
                } else {
                    Color.clear.onAppear { finish() }
                }
            case .askIt:
                OnboardingAskItStep(noteText: firstNoteText,
                                    answerer: makeSystemNoteAnswerer()) { step = .destination }
            case .destination:
                OnboardingDestinationStep(
                    brains: brains,
                    onChooseVault: {
                        // Mark the flow done BEFORE handing off: the funnel is a separate
                        // surface, and a user who backs out of it must not be re-onboarded.
                        markComplete()
                        onDone()
                        onChooseVault?()
                    },
                    onFinish: { _ in finish() })
            }
        }
        .padding(GrainSpacing.x6)
        .grainBackground()
        .interactiveDismissDisabled(false)
        .onDisappear { finish() }   // dismissing counts as done — never re-prompt
    }

    private func finish() {
        markComplete()
        onDone()
    }

    /// Set the once-flags without dismissing. Split out from `finish()` because the
    /// Vault hand-off needs the flow marked done BEFORE the funnel takes over.
    private func markComplete() {
        // Set the once-flag on first completion; `finish()` ALWAYS calls onDone so a
        // re-run from Settings ("Show the welcome tour") can still dismiss itself.
        if !OnboardingPrefs.completed { OnboardingPrefs.completed = true }
        // The flow OPENED with the persona welcome, so it counts as seen —
        // the standalone welcome must not re-present over a finished flow.
        WelcomePrefs.markSeen()
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
    var onRetryCleanup: (() -> Void)? = nil
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
            if let retry = signIn.onRetryCleanup {
                GrainButton("Retry cleanup", variant: .filled, size: .sm) {
                    retry()
                }
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
    /// Which passage words have actually been HEARD. A byte-count bar says how long is
    /// left; this says whether the mic is picking the reader up — the one thing that
    /// matters when the output is a voice key. Purely additive: when the OS has no
    /// on-device recogniser nothing lights up and enrolment behaves exactly as before.
    @State private var progress = PassageProgress(passage: OwnerVoicePassage.text)
    @State private var listener: LiveTranscribing?
    @State private var listenTask: Task<Void, Never>?
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

    /// The read-aloud doubles as the product introduction — it lives in FoundryXKit
    /// (`OwnerVoicePassage`) because the matcher is tested against it.
    private var passage: String { OwnerVoicePassage.text }

    /// The passage with every heard word locked in at full strength and the rest muted,
    /// so the reader can see where they are. Built as ONE `AttributedString` (a run per
    /// word) rather than folding `Text + Text`: the latter nests a
    /// `ConcatenatedTextStorage` per word and blows the main-thread stack — the same
    /// trap `LiveTranscriptTicker.styledText` documents.
    private var styledPassage: Text {
        var attributed = AttributedString()
        for (i, word) in progress.words.enumerated() {
            var run = AttributedString((i == 0 ? "" : " ") + word)
            let heard = progress.states[i] == .spoken
            run.foregroundColor = heard ? GrainColor.ink : GrainColor.textMuted.opacity(0.55)
            if heard { run.inlinePresentationIntent = .stronglyEmphasized }
            attributed.append(run)
        }
        return Text(attributed)
    }

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

            styledPassage
                .grainTextStyle(.body)
                .padding(GrainSpacing.x4)
                .background(RoundedRectangle(cornerRadius: GrainRadius.card, style: .continuous).fill(GrainColor.forgeBlueBg))
                .accessibilityIdentifier("enrolment-passage")

            switch phase {
            case .intro:
                GrainButton("Start reading", variant: .filled, size: .regular) { start() }
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
        progress = PassageProgress(passage: OwnerVoicePassage.text)
        phase = .recording(0)
        let source = MicFrameSource()
        startListening(on: source)
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
        stopListening()
    }

    /// Tap the SAME mic the enrolment recorder is using and run the on-device live
    /// transcriber over it, folding whatever it hears into the passage matcher.
    ///
    /// Strictly best-effort. Every failure here is swallowed: an OS with no recogniser
    /// (`defaultFactory` returns nil), a denied speech-recognition authorisation, or a
    /// mid-read error all leave the passage unlit while the read-aloud, the length gate
    /// and the stored sample carry on untouched. Enrolling a voice must never be
    /// blocked by speech recognition being unavailable.
    private func startListening(on source: MicFrameSource) {
        guard let transcriber = LiveTranscription.defaultFactory()() else { return }
        listener = transcriber
        source.onPCM = { buffer in transcriber.append(buffer) }
        listenTask = Task {
            do { try await transcriber.start() } catch { return }   // no preview, no harm
            for await live in transcriber.transcript {
                let heard = live.displayText
                await MainActor.run { progress.consume(heard) }
            }
        }
    }

    private func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        let t = listener
        listener = nil
        guard let t else { return }
        Task { _ = await t.finish() }
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

/// THE SAMPLE NUDGE'S ERRAND — owned here, not in a SwiftUI body.
///
/// `AmbientNotifier.postPreview` reports from whatever queue the notification centre calls
/// back on, so the outcome needs a MainActor-isolated home. A `@MainActor final class` is
/// implicitly Sendable, which is what lets the `@Sendable` report closure carry it across
/// that boundary without dragging the (non-Sendable) view along.
///
/// It is a MODEL rather than a value the view's closure writes into because `swift test`
/// cannot compile `App/`: a decision taken inside a `View` body is untestable by
/// construction, which is exactly how "We just sent a sample nudge" shipped over a function
/// that had sent nothing. Everything the step decides is here, where the app-hosted
/// scenario lane can drive it and assert on what it settled to.
///
/// It also OWNS THE CLOCK. A centre that never calls back is indistinguishable from a
/// swallowed early return, and both used to leave the step reading "Checking whether the
/// sample nudge can go out" forever, with no way out of the screen but the promise
/// unresolved. After `patience` seconds with no answer the step says the sample did not go
/// out — which is true, and is the one thing the old code could never say.
@MainActor
final class AmbientSampleNudge: ObservableObject {
    /// What the phone actually did. `.pending` only until the first answer arrives.
    @Published private(set) var attempt: AmbientNudgeAttempt = .pending
    /// Has the user turned it on? Drives which half of the step is showing.
    @Published private(set) var isOn = false
    /// Has a sample been asked for at all? Until it has, `attempt` is `.pending` because
    /// nothing has been tried — which is a different thing from waiting on an answer, and a
    /// surface that cannot tell them apart says "checking" before anyone has tapped.
    @Published private(set) var hasFired = false

    /// How long to wait for the phone before saying the sample did not go out. A
    /// constructor argument with a production default — not a hidden environment knob — so
    /// a scenario can wait a fraction of a second instead of ten.
    private let patience: TimeInterval
    private var clock: Task<Void, Never>?
    /// EXACTLY ONE outcome is recorded. Whichever answer arrives first — the centre's or
    /// the clock's — wins, and the other is ignored.
    private var settled = false

    init(patience: TimeInterval = 10) { self.patience = patience }

    /// What the "Turn it on" button does, in full. Ambient intelligence goes on (that write
    /// stands whatever the sample does), the agent gets its default name, and the sample
    /// nudge is fired at the step that just promised one.
    func turnOn() {
        _ = AmbientPrefs.setEnabled(true)
        // The agent answers to "Foundry" out of the box (renameable in Settings) — a named
        // agent is the invocation ritual.
        if AmbientPrefs.agentName() == nil {
            _ = AmbientPrefs.setAgentName("Foundry")
        }
        isOn = true
        fireSample()
    }

    /// Fire the sample and start the clock. Also the Settings entry point, where ambient
    /// intelligence is already on and only the sample is wanted.
    func fireSample() {
        settled = false
        hasFired = true
        attempt = .pending
        clock?.cancel()
        clock = Task { [weak self, patience] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, patience) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.record(.unavailable)
        }
        AmbientNotifier.postPreview { [weak self] outcome in
            Task { @MainActor in self?.record(outcome) }
        }
    }

    /// The single settle point. Public so the app-hosted scenarios can drive the step's
    /// reaction to an outcome directly as well as through the real notifier.
    func record(_ outcome: AmbientNudgeAttempt) {
        guard !settled else { return }
        settled = true
        clock?.cancel()
        clock = nil
        attempt = outcome
    }

    /// The step's words, keyed on what actually happened. Never a literal in a body.
    var said: OnboardingAmbientConfirmation {
        OnboardingAmbientStepCopy.confirmation(for: attempt)
    }
}

struct OnboardingAmbientStep: View {
    let onDone: () -> Void
    /// The step used to announce "We just sent a sample nudge" on the line after calling a
    /// function that, with no account bound, posted nothing and returned silently. Every
    /// decision it makes now lives in the model, where a test can run it (FX-4a).
    @StateObject private var nudge = AmbientSampleNudge()

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            Text("Ambient intelligence").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("While you're taking a note, your phone can privately notice moments like “I'll have to look that up” and offer to help — everything stays on your phone until you accept a suggestion.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
            Text("Off by default. You can change this any time in Settings.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

            // Worked examples BEFORE the decision. The sample push notification fires
            // only after consent, which meant the first concrete thing the user ever saw
            // arrived once they had already agreed — they were consenting to something
            // they had not seen. These are inert: no action closure reaches the broker,
            // and nothing here is stored as a real card
            // (features/onboarding-ambient-preview.feature).
            if !nudge.isOn {
                ScrollView { AmbientPreviewCards() }
                    .frame(maxHeight: 300)
            }

            if nudge.isOn {
                // Every word here comes from FoundryXKit, keyed on what the notifier
                // actually reported — a literal in this body could not know, and that is
                // precisely how the false claim shipped.
                let said = nudge.said
                Label(said.headline, systemImage: said.symbolName)
                    .grainTextStyle(.body)
                    .foregroundStyle(said.claimsNudgeSent ? GrainColor.sage : GrainColor.textMuted)
                Text(said.detail)
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }

            Spacer()
            if nudge.isOn {
                GrainButton("Done", variant: .filled, size: .regular) { onDone() }
                    .padding(.bottom, GrainSpacing.x4)
            } else {
                // Deterministic first-feel: the sample nudge fires NOW, while they're
                // looking, so the first real one is familiar — and notification permission
                // is asked for HERE, at the step that promises one. Whatever comes back is
                // what the screen says; nothing is assumed, and nothing is decided in this
                // body, which no test in this repository can execute.
                GrainButton("Turn it on", variant: .filled, size: .regular) { nudge.turnOn() }
                GrainButton("Not now", variant: .outlined, size: .regular) { onDone() }
                    .padding(.bottom, GrainSpacing.x4)
            }
        }
    }
}
