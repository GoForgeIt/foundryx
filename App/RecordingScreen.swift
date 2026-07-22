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
// Assembled from existing primitives — GrainVoiceRing, SessionElapsedLabel (session-owned,
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
    /// STABLE identity — derived from the source candidate's key (its utterance), not a
    /// fresh UUID. `recordingSuggestions` is a computed property re-evaluated on every
    /// live-transcript word, so a per-eval UUID would give every row a new identity each
    /// render and thrash `ForEach`/`GrainSuggestionCard` teardown-rebuild while a card is up.
    let id: String
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
    /// The LIVE surface's fast-moving text (transcript · rolling title · candidates).
    /// Observed here rather than through the manager so the several-times-a-second
    /// publishes reach THIS surface without invalidating the library behind it
    /// (track 20260722T1244).
    @ObservedObject var live: CaptureManager.LiveCaptureModel
    /// The resolved door target (parity with the inline instrument's wiring; kept for
    /// any transcript/detail handoff the foot may grow).
    let target: DoorTarget
    /// The current ambient suggestions to stack — a CLOSURE, not a snapshot: candidates
    /// arrive on the live model mid-recording, and this view (not its presenter) is the
    /// one that re-renders when they do. Returns `[]` to render nothing (the section
    /// collapses when there is no real suggestion).
    var suggestions: () -> [RecordingSuggestion] = { [] }
    /// DEV-only frozen data (see `RecordingPreview`); `nil` uses live manager state.
    var preview: RecordingPreview? = nil
    /// End the capture and dismiss (mic → stop; Omi → end the current conversation).
    var onEnd: () -> Void = {}
    /// MINIMIZE the surface — leave the recording RUNNING and return to the app (the
    /// persistent recording pill is the way back). Additive to End/Stop, never a
    /// replacement.
    var onMinimize: () -> Void = {}

    /// The effective live transcript — the frozen preview, else the live model.
    private var liveT: LiveTranscript { preview?.transcript ?? live.transcript }
    /// The effective suggestion rows (evaluated per render — see `suggestions`).
    private var suggestionRows: [RecordingSuggestion] { suggestions() }
    /// The effective session clock — the frozen preview (DEV screenshot path) mapped to a
    /// clock at its origin, else the manager's session-owned `recordingClock`. DERIVED,
    /// never stored: this view holds no timer, so a minimize → restore re-present cannot
    /// reset or double-count the elapsed time (track 20260717T0630).
    private var clock: RecordingClock? {
        if let preview { return RecordingClock(startedAt: preview.since) }
        return manager.recordingClock
    }
    private var statusWord: String { manager.isPaused ? "Paused" : "Recording" }

    var body: some View {
        let rows = suggestionRows
        return ZStack(alignment: .top) {
            VStack(spacing: GrainSpacing.x4) {
                // ONE shared subtree for both layouts, so recordingMain/Title/Transcript
                // keep a STABLE identity across the fill↔compact shift — the breathing
                // ring + clock never rebuild when the first candidate lands. Only the top
                // space flexes: in FILL (no task/notification) it expands so the ring
                // cluster floats generously (prototype); in COMPACT it collapses so the
                // content rides up and the task cards sit directly below it. The foot
                // stays pinned at the bottom either way (prototype `margin-top:auto`).
                Spacer(minLength: 0).frame(maxHeight: rows.isEmpty ? .infinity : 0)
                recordingMain
                recordingTitle
                liveTranscript
                suggestionStack(rows)     // renders nothing when there are no candidates
                Spacer(minLength: 0)
                recordingFoot
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 54)
            .padding(.horizontal, GrainSpacing.mobileGutter)   // 18
            .padding(.bottom, 15)
            .animation(.easeOut(duration: 0.4), value: rows.isEmpty)

            // Minimize — top-leading; leaves the recording RUNNING and returns to the app.
            minimizeButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 48)
                .padding(.leading, GrainSpacing.mobileGutter)

            // 1 — Island status floats just above the ring, centered.
            islandStatus.padding(.top, 44)
        }
        .grainBackground()
        // Belt-and-suspenders (Bug 2): a live capture is always metered. The manager
        // already starts the meter at session begin, but presentation-order races (this
        // cover appearing before the presenter's onDisappear resolves) and covers presented
        // over a NON-capture tab (where CaptureScreen never mounted) mean the recording
        // ring must guarantee its own meter — startMeter() is idempotent.
        .onAppear { manager.startMeter() }
    }

    /// Minimize — a chevron-down surface icon button, distinct from Stop/End. Dismisses
    /// the cover WITHOUT stopping the recording; the persistent pill brings it back.
    private var minimizeButton: some View {
        Button(action: onMinimize) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GrainColor.inkSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(GrainColor.surface))
                .overlay(Circle().strokeBorder(GrainColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Minimize recording")
        .accessibilityIdentifier("minimize-recording")
    }

    // MARK: 1 — island status (breathing dot · Recording · elapsed), forge tint

    private var islandStatus: some View {
        HStack(spacing: 5) {
            BreathingDot(color: GrainColor.forgeInk, size: 5)
            Text(statusWord)
                .font(GrainFont.sans(8, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(GrainColor.forgeInk)
            SessionElapsedLabel(clock: clock,
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
                    SessionElapsedLabel(clock: clock,
                                        font: GrainFont.sans(30, weight: .semibold), color: GrainColor.ink)
                        // The UI proof reads THIS readout by identifier — an app-wide m:ss
                        // text match can latch onto a seeded card's static timestamp.
                        .accessibilityIdentifier("recording-elapsed")
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

    /// The rolling live title — manager-owned (track 20260717T1015): derived from
    /// the WHOLE conversation so far (whole-context salience heuristic + debounced
    /// on-device model refreshes), stabilized so it doesn't jitter. The frozen DEV
    /// preview derives one directly from its seeded transcript.
    private var provisionalTitle: String? {
        if let preview {
            return WholeConversationTitle.heuristic(from: preview.transcript.displayText)
        }
        return live.title
    }

    @ViewBuilder private var recordingTitle: some View {
        let title = provisionalTitle
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(title)
                    .font(GrainFont.sans(15, weight: .semibold))
                    .foregroundStyle(GrainColor.ink)
                    .lineLimit(2)
                    .accessibilityIdentifier("recording-title")
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

    @ViewBuilder private func suggestionStack(_ rows: [RecordingSuggestion]) -> some View {
        if !rows.isEmpty {
            VStack(spacing: 7) {
                ForEach(rows) { s in
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
