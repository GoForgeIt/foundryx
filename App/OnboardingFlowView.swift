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
    let onDone: () -> Void

    private enum Step { case welcome, voice, ambient }
    @State private var step: Step = .welcome

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
        guard !OnboardingPrefs.completed else { return }
        OnboardingPrefs.completed = true
        onDone()
    }

    @ViewBuilder private var welcome: some View {
        Spacer()
        Text("Welcome to FoundryX").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
        Text("Your conversations, captured and remembered — on your devices. Two quick things make it yours.")
            .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
            .multilineTextAlignment(.center)
            .padding(.top, GrainSpacing.x2)
        Spacer()
        GrainButton("Get started", variant: .filled, size: .regular) { step = .voice }
        GrainButton("Skip for now", variant: .text, size: .regular) { finish() }
            .padding(.bottom, GrainSpacing.x4)
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

    private let passage = """
    “I’m teaching FoundryX my voice so it knows when it’s really me. \
    When I ask for something in a conversation — look something up, remember a task, \
    or reach my agent — it should listen to me, and only me. \
    A voice is a kind of key, and this one is mine.”
    """

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
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
                Label("Voice captured", systemImage: "checkmark.circle.fill")
                    .grainTextStyle(.body).foregroundStyle(GrainColor.sage)
                Text("It will enroll as your voiceprint next time your computer brain is connected.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x4) {
            Text("Ambient intelligence").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("While you record, your phone can privately notice moments like “I'll have to look that up” and offer to help — everything stays on your phone until you accept a suggestion.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
            Text("Off by default. You can change this any time in Settings.")
                .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)

            Spacer()
            GrainButton("Turn it on", variant: .filled, size: .regular) {
                UserDefaults.standard.set(true, forKey: AmbientPrefs.enabledKey)
                onDone()
            }
            GrainButton("Not now", variant: .outlined, size: .regular) { onDone() }
                .padding(.bottom, GrainSpacing.x4)
        }
    }
}
