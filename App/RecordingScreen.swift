// RecordingScreen — the full-screen recording surface (prototype fullflow2 scene 09,
// `renderRecording` / `.recording-screen`). When the phone mic is recording (or an
// Omi session is active) this presents over Capture as a `.fullScreenCover`.
//
// The one moving instrument the user meets everywhere (GrainVoiceRing) is the hero,
// breathing with live mic energy; the elapsed clock reads in its center and again in
// the floating island status; a provisional title and a word-by-word live transcript
// build as you speak; ambient suggestions stack only when one actually exists; and a
// primary "End and save" foot closes the capture.
//
// Assembled from existing primitives — GrainVoiceRing, ElapsedLabel (paused-aware),
// ProvisionalLiveTitle, LiveTranscript.renderedSegments, GrainSuggestionCard — so the
// live behaviour matches the inline strip it supersedes. All colour via GrainColor
// tokens; light + dark. (FoundryXKit types are same-module — the App target compiles
// Sources/FoundryXKit directly; Grain is a package import.)

import SwiftUI
import Grain

/// One ambient suggestion row for the recording screen. Memory suggestions tint amber,
/// agent suggestions tint forge. Built by the presenter from a REAL source — the screen
/// renders only the rows it is handed (it never fabricates a suggestion).
struct RecordingSuggestion: Identifiable {
    let id = UUID()
    let tint: GrainSuggestionTint
    let systemImage: String
    let eyebrow: String
    let title: String
    let body: String
    let actionLabel: String
    let action: () -> Void
}

/// A frozen snapshot to render the screen from without a live mic — DEV screen-proof
/// (`-Screen recording`): a fixed clock origin + a seeded live transcript so every
/// section renders for a screenshot. `nil` in production (the screen reads live manager
/// state).
struct RecordingPreview {
    let since: Date
    let transcript: LiveTranscript
}

struct RecordingScreen: View {
    @ObservedObject var manager: CaptureManager
    /// The resolved door target (parity with the inline instrument's wiring; kept for
    /// any transcript/detail handoff the foot may grow).
    let target: DoorTarget
    /// The current ambient suggestions to stack — pass `[]` to render nothing (the
    /// section collapses when there is no real suggestion).
    var suggestions: [RecordingSuggestion] = []
    /// DEV-only frozen data (see `RecordingPreview`); `nil` uses live manager state.
    var preview: RecordingPreview? = nil
    /// End the capture and dismiss (mic → stop; Omi → end the current conversation).
    var onEnd: () -> Void = {}

    /// A stable fallback origin for the clock if no WAL is active yet (real recording
    /// always has an active WAL; this only guards the first frame / edge cases).
    @State private var fallbackStart = Date()

    /// The effective live transcript — the frozen preview, else live manager state.
    private var liveT: LiveTranscript { preview?.transcript ?? manager.liveTranscript }
    /// The clock origin — the frozen preview, else the active capture's start, else the fallback.
    private var since: Date { preview?.since ?? manager.active?.status.startedAt ?? fallbackStart }
    private var statusWord: String { manager.isPaused ? "Paused" : "Recording" }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: GrainSpacing.x4) {
                recordingMain
                recordingTitle
                liveTranscript
                suggestionStack
                Spacer(minLength: 0)
                recordingFoot
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 54)
            .padding(.horizontal, GrainSpacing.mobileGutter)   // 18
            .padding(.bottom, 15)

            // 1 — Island status floats just above the ring, centered.
            islandStatus.padding(.top, 44)
        }
        .grainBackground()
    }

    // MARK: 1 — island status (breathing dot · Recording · elapsed), forge tint

    private var islandStatus: some View {
        HStack(spacing: 5) {
            BreathingDot(color: GrainColor.forgeInk, size: 5)
            Text(statusWord)
                .font(GrainFont.sans(8, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(GrainColor.forgeInk)
            ElapsedLabel(since: since, paused: manager.isPaused,
                         font: GrainFont.sans(8, weight: .heavy), color: GrainColor.forgeInk)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 2 — recording main: 176 breathing ring + center overlay + flanking controls

    private var recordingMain: some View {
        ZStack {
            // Ring with the ticking clock + caption in its center.
            ZStack {
                RecordingScreenRing(meter: manager.meter, paused: manager.isPaused)
                VStack(spacing: 2) {
                    ElapsedLabel(since: since, paused: manager.isPaused,
                                 font: GrainFont.sans(30, weight: .semibold), color: GrainColor.ink)
                    Text("Voice ring")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                }
            }
            // Flanking controls span the full width: Stop LEFT, Pause/Resume RIGHT.
            HStack {
                stopButton
                Spacer()
                pauseButton
            }
        }
        .frame(height: 198)
        .frame(maxWidth: .infinity)
    }

    /// Stop / End — surface style icon button (returns to Capture).
    private var stopButton: some View {
        Button(action: onEnd) {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(GrainColor.inkSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(GrainColor.surface))
                .overlay(Circle().strokeBorder(GrainColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End recording")
    }

    /// Pause / Resume — filled forge, switches to amber when paused.
    private var pauseButton: some View {
        Button { manager.togglePause() } label: {
            Image(grain: manager.isPaused ? .play : .pause)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GrainColor.onAccent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(manager.isPaused ? GrainColor.amber : GrainColor.forgeBlue))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(manager.isPaused ? "Resume recording" : "Pause recording")
    }

    // MARK: 3 — recording title (fades in once enough was said)

    @ViewBuilder private var recordingTitle: some View {
        let title = ProvisionalLiveTitle.title(from: liveT.finalizedText)
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(title)
                    .font(GrainFont.sans(15, weight: .semibold))
                    .foregroundStyle(GrainColor.ink)
                    .lineLimit(2)
                Text("Title updates as you speak.")
                    .font(GrainFont.sans(9))
                    .foregroundStyle(GrainColor.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
        .animation(.easeOut(duration: 0.55), value: title)
        .transition(.opacity)
    }

    // MARK: 4 — live transcript (word-by-word: heard = ink, current = forge)

    private var liveTranscript: some View {
        RecordingLiveTranscript(transcript: liveT)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .frame(height: 82, alignment: .topLeading)
            .clipped()
    }

    // MARK: 5 — suggestion stack (only rows that exist)

    @ViewBuilder private var suggestionStack: some View {
        if !suggestions.isEmpty {
            VStack(spacing: 7) {
                ForEach(suggestions) { s in
                    GrainSuggestionCard(
                        systemImage: s.systemImage,
                        tint: s.tint,
                        eyebrow: s.eyebrow,
                        title: s.title,
                        body: s.body,
                        actionLabel: s.actionLabel,
                        onAction: s.action)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 6 — foot: End and save + caption

    private var recordingFoot: some View {
        VStack(spacing: 4) {
            Button(action: onEnd) {
                Text("End and save").frame(maxWidth: .infinity)
            }
            .buttonStyle(.grain(.filled, size: .lg))
            .frame(maxWidth: .infinity)

            Text("Saves this recording and returns to Capture.")
                .font(GrainFont.sans(8.5))
                .foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The 176pt breathing ring, isolated in its own subview so the meter's 12 Hz ticks
/// invalidate ONLY the ring — never the whole RecordingScreen body (the law the old
/// MeterStrip / RecordingRingView obey).
private struct RecordingScreenRing: View {
    @ObservedObject var meter: CaptureManager.AudioMeterModel
    let paused: Bool

    var body: some View {
        GrainVoiceRing(
            energy: RecordingRingModel.energy(meterLevel: Double(meter.levels.last ?? 0), paused: paused),
            order: RecordingRingModel.order)
        .frame(width: 176, height: 176)
        .accessibilityHidden(true)
    }
}

/// A soft breathing dot (opacity pulse ~1.8s) — the live-recording tell in the island.
/// Honors Reduce Motion by holding steady.
private struct BreathingDot: View {
    let color: Color
    var size: CGFloat = 5
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.32 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// The word-by-word live transcript (Feature 4, recording-screen treatment): finalized
/// words read as already-heard `ink`; the still-settling volatile tail reads `forgeBlue`
/// at ~0.75 — the "current" words. Built as a SINGLE `AttributedString` (one run per
/// word) to avoid the nested-`Text` stack recursion on long transcripts (build-89/90
/// SIGSEGV); bounded to the most-recent words. Ephemeral preview — Kiln's transcript is
/// authoritative.
private struct RecordingLiveTranscript: View {
    let transcript: LiveTranscript
    private static let maxLiveWords = 48

    private var styled: Text {
        let segments = transcript.renderedSegments(maxWords: Self.maxLiveWords)
        var attributed = AttributedString()
        for (i, seg) in segments.enumerated() {
            var run = AttributedString((i == 0 ? "" : " ") + seg.text)
            run.foregroundColor = seg.volatile ? GrainColor.forgeBlue.opacity(0.75) : GrainColor.ink
            attributed.append(run)
        }
        return Text(attributed)
    }

    var body: some View {
        styled
            .font(GrainFont.sans(10.5))
            .foregroundStyle(GrainColor.textMuted)   // baseline for any unstyled run
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .multilineTextAlignment(.leading)
    }
}
