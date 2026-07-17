import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/recording-instrument.feature (track 20260717T0600). Wires
/// every scenario — the original ring/title/pill behavior AND the new hero-live-tile
/// scenarios — to the REAL pure FoundryXKit helpers the Capture surface renders from:
/// `LiveHeroPresentation.slot`, `RecordingRingModel.energy`, `ProvisionalLiveTitle.title`,
/// and `RecordingPillState.visible`. No view, no mic — the durable decisions the screen
/// obeys, pinned as executed tests (the feature file was previously documentation-only).
final class LiveHeroTileTests: XCTestCase {
    func testRecordingInstrumentFeature() async throws {
        try await BrineFeatureRunner.run("recording-instrument",
                                         registry: StepRegistry(LiveHeroSteps.make(world: .init())))
    }
}

/// The capture surface's state, reduced to exactly the inputs the pure helpers consume.
/// Each Given fully resets it so scenarios don't bleed into one another.
private final class LiveHeroWorld: @unchecked Sendable {
    var isRecordingMic = false
    var hasActiveSession = false     // manager.active != nil
    var connected = false            // an ambient source is connected
    var paused = false
    var onCaptureTab = true
    var minimized = false
    var recorderOpen = false         // the full recording screen is presented
    var ended = false
    var transcript = ""              // finalized spoken words
    var meterLevel = 0.0

    /// The existing capture gate: the live surface shows when a source is connected or
    /// the phone mic is recording.
    var isShowingCapture: Bool { connected || isRecordingMic }

    var slot: LiveHeroPresentation.Slot {
        LiveHeroPresentation.slot(isShowingCapture: isShowingCapture,
                                  hasActiveSession: hasActiveSession,
                                  isRecordingMic: isRecordingMic,
                                  isPaused: paused)
    }

    var liveTile: LiveHeroPresentation.LiveTile? {
        if case .liveTile(let t) = slot { return t }
        return nil
    }

    var ringEnergy: Double {
        RecordingRingModel.energy(meterLevel: meterLevel, paused: paused)
    }

    var provisionalTitle: String? { ProvisionalLiveTitle.title(from: transcript) }

    // The ROLLING whole-conversation title machinery (track 20260717T1015): the same
    // context accumulator + heuristic + arbiter chain CaptureManager drives.
    var titleCtx = RollingTitleContext()
    var titleState: LiveTitleState?
    var displayTail = ""             // what the OLD title derived from (bounded tail)

    var lastExternalTitle = ""
    /// The EXTERNAL (Fireworks-via-door) refresh that arrives on the backoff cadence:
    /// routed through the SAME arbiter the manager uses, at the external tier.
    func externalRefresh(_ text: String) {
        lastExternalTitle = text
        titleState = LiveTitleArbiter.merged(current: titleState, candidateText: text, tier: .external)
    }
    /// A later on-device (Foundation Models) guess between external ticks.
    func onDeviceGuess(_ text: String) {
        titleState = LiveTitleArbiter.merged(current: titleState, candidateText: text, tier: .model)
    }

    /// One finalized utterance lands: context + bounded display tail + a heuristic
    /// refresh through the arbiter — the manager's per-final path in miniature.
    func speakFinal(_ line: String) {
        titleCtx.ingest(final: line)
        displayTail = LiveTranscriptBuffer.boundedTail(
            displayTail.isEmpty ? line : displayTail + " " + line)
        if let t = WholeConversationTitle.heuristic(from: titleCtx.text) {
            titleState = LiveTitleArbiter.merged(current: titleState, candidateText: t,
                                                 tier: .heuristic)
        }
    }

    var pillVisible: Bool {
        RecordingPillState.visible(recordingActive: isRecordingMic || hasActiveSession,
                                   onCaptureTab: onCaptureTab, minimized: minimized)
    }

    func reset() {
        isRecordingMic = false; hasActiveSession = false; connected = false
        paused = false; onCaptureTab = true; minimized = false
        recorderOpen = false; ended = false; transcript = ""; meterLevel = 0
        titleCtx = RollingTitleContext(); titleState = nil; displayTail = ""
    }

    /// The canonical "recording, on the capture page" starting state used by several
    /// scenarios: mic recording, an active session, on-screen, with real spoken words
    /// and voice on the meter.
    func startRecordingOnCapturePage() {
        reset()
        isRecordingMic = true
        hasActiveSession = true
        onCaptureTab = true
        meterLevel = 0.6
        transcript = "Let's plan the launch for the October release and split the work"
    }
}

private enum LiveHeroSteps {
    static func make(world w: LiveHeroWorld) -> [StepDefinition] {
        [
            // MARK: Givens (each resets the world to a known baseline)

            defineStep("I am recording") { ctx, _, _ in
                w.reset(); w.isRecordingMic = true; w.hasActiveSession = true; w.meterLevel = 0
                return ctx
            },
            defineStep("I am recording and nothing has been said yet") { ctx, _, _ in
                w.reset(); w.isRecordingMic = true; w.hasActiveSession = true; w.transcript = ""
                return ctx
            },
            defineStep("I am recording on the capture page") { ctx, _, _ in
                w.startRecordingOnCapturePage(); return ctx
            },
            defineStep("I am recording and away from the capture page") { ctx, _, _ in
                w.startRecordingOnCapturePage(); w.onCaptureTab = false; return ctx
            },
            defineStep("I am not recording and no source is connected") { ctx, _, _ in
                w.reset(); return ctx
            },
            defineStep("a source is connected with no active conversation") { ctx, _, _ in
                w.reset(); w.connected = true; w.hasActiveSession = false; w.isRecordingMic = false
                return ctx
            },

            // MARK: Whens

            defineStep("someone speaks") { ctx, _, _ in w.meterLevel = 0.85; return ctx },
            defineStep("I pause the recording") { ctx, _, _ in w.paused = true; return ctx },
            defineStep("enough has been said") { ctx, _, _ in
                w.transcript = "Let's plan the launch for the October release and split the work"
                return ctx
            },
            defineStep("I switch to the chat tab") { ctx, _, _ in
                w.onCaptureTab = false; return ctx
            },
            defineStep("I tap the pill") { ctx, _, _ in
                w.onCaptureTab = true; w.minimized = false; w.recorderOpen = true; return ctx
            },
            defineStep("I tap the live tile") { ctx, _, _ in
                // Tapping opens the recorder only when a live recorder is behind the tile.
                if w.liveTile?.hasRecorder == true { w.minimized = false; w.recorderOpen = true }
                return ctx
            },
            defineStep("I end the recording from the pill") { ctx, _, _ in
                w.isRecordingMic = false; w.hasActiveSession = false; w.ended = true; return ctx
            },

            // MARK: Thens — original ring / title / pill behavior

            defineCheck("the ring moves with the voice") { _, _, _ in
                let quiet = RecordingRingModel.energy(meterLevel: 0.05, paused: false)
                guard w.ringEnergy > quiet else {
                    throw BrineStepError("ring energy \(w.ringEnergy) did not rise with the voice")
                }
            },
            defineCheck("the ring goes nearly still") { _, _, _ in
                guard abs(w.ringEnergy - 0.03) < 0.001 else {
                    throw BrineStepError("paused ring energy \(w.ringEnergy) is not the near-still shimmer")
                }
            },
            defineCheck("the recording shows no provisional title") { _, _, _ in
                guard w.provisionalTitle == nil else {
                    throw BrineStepError("a title appeared before enough was said: \(w.provisionalTitle!)")
                }
            },
            defineCheck("a provisional title appears from the spoken words") { _, _, _ in
                guard let title = w.provisionalTitle else { throw BrineStepError("no provisional title") }
                guard w.transcript.hasPrefix(title.replacingOccurrences(of: "…", with: "")) else {
                    throw BrineStepError("title '\(title)' is not drawn from the spoken words")
                }
            },
            defineCheck("it updates in place rather than jumping the layout") { _, _, _ in
                // The title is a pure function of the transcript HEAD → growth never rewrites it.
                let head = w.transcript
                let t1 = ProvisionalLiveTitle.title(from: head)
                let t2 = ProvisionalLiveTitle.title(from: head + " between the two of us next quarter")
                guard t1 == t2 else { throw BrineStepError("title rewrote itself: \(t1 ?? "nil") → \(t2 ?? "nil")") }
            },
            defineCheck("the recording continues") { _, _, _ in
                guard w.isRecordingMic else { throw BrineStepError("recording did not continue off-tab") }
            },
            defineCheck("a recording pill shows the elapsed time") { _, _, _ in
                guard w.pillVisible else { throw BrineStepError("the pill is not visible away from capture") }
            },
            defineCheck("I am back on the capture page") { _, _, _ in
                guard w.onCaptureTab else { throw BrineStepError("the tap did not return to the capture page") }
            },
            defineCheck("the conversation finalizes normally") { _, _, _ in
                guard w.ended, !w.isRecordingMic else { throw BrineStepError("the recording did not finalize") }
            },

            // MARK: Thens — the hero live tile

            defineCheck("the record hero shows the live recording tile") { _, _, _ in
                guard w.liveTile != nil else {
                    throw BrineStepError("hero slot is \(w.slot), expected the live tile")
                }
            },
            defineCheck("the live tile shows the recording ring at hero size") { _, _, _ in
                // The tile always carries the ring; the hero size is a view constant. Pin
                // that the live tile owns the slot (the strip's cramped small ring is gone).
                guard w.liveTile != nil else { throw BrineStepError("no live tile to host the hero ring") }
            },
            defineCheck("the live tile shows the elapsed time from the session start") { _, _, _ in
                guard w.liveTile?.showsElapsed == true else {
                    throw BrineStepError("elapsed not shown though a session start exists")
                }
            },
            defineCheck("the live tile shows the live words being spoken") { _, _, _ in
                guard !w.transcript.isEmpty else {
                    throw BrineStepError("no live words to render in the tile")
                }
            },
            defineCheck("the full recording screen opens") { _, _, _ in
                guard w.recorderOpen else { throw BrineStepError("tapping the tile did not open the recorder") }
            },
            defineCheck("the record hero shows the \"Record a conversation\" call to action") { _, _, _ in
                guard w.slot == .recordCTA else {
                    throw BrineStepError("hero slot is \(w.slot), expected the record CTA")
                }
            },
            defineCheck("the live recording tile is not shown") { _, _, _ in
                guard w.liveTile == nil else { throw BrineStepError("the live tile showed while not recording") }
            },
            defineCheck("the compact recording strip never appears") { _, _, _ in
                // The compact strip was removed from this tab entirely: the only recording
                // presentation is the live tile. There is no state that renders the strip.
                guard w.liveTile != nil else {
                    throw BrineStepError("expected the live tile (the strip is gone), got \(w.slot)")
                }
            },
            defineCheck("the live tile still shows, marked paused") { _, _, _ in
                guard let tile = w.liveTile else { throw BrineStepError("the live tile vanished when paused") }
                guard tile.paused else { throw BrineStepError("the live tile is not marked paused") }
            },
            defineCheck("the elapsed time is still shown") { _, _, _ in
                guard w.liveTile?.showsElapsed == true else {
                    throw BrineStepError("the elapsed clock disappeared while paused")
                }
            },
            defineCheck("the live tile shows no elapsed time") { _, _, _ in
                guard let tile = w.liveTile else { throw BrineStepError("no live tile for the connected source") }
                guard !tile.showsElapsed else {
                    throw BrineStepError("elapsed shown for a connected source with no active WAL")
                }
            },
            defineCheck("the live tile is not tappable to open the recorder") { _, _, _ in
                guard let tile = w.liveTile else { throw BrineStepError("no live tile for the connected source") }
                guard !tile.hasRecorder else {
                    throw BrineStepError("the tile is tappable though no recorder is behind it")
                }
            },

            // MARK: the name reflects the whole conversation (track 20260717T1015)

            defineStep("I am recording and the conversation has moved through several topics") { ctx, _, _ in
                w.startRecordingOnCapturePage()
                w.titleCtx = RollingTitleContext(); w.titleState = nil; w.displayTail = ""
                // It OPENS on the kitchen-renovation budget…
                w.speakFinal("The kitchen renovation budget is the big topic today")
                w.speakFinal("the kitchen budget has to cover cabinets counters and the island")
                w.speakFinal("the kitchen renovation lands around forty thousand total")
                return ctx
            },
            defineStep("the conversation grows well past its opening words") { ctx, _, _ in
                // …wanders through one-off chatter far past the 80-word display tail,
                // and ends on contractor permits.
                for i in 0..<30 {
                    w.speakFinal("then chatterline\(i) unrelatedword\(i) middlebit\(i) fillertoken\(i)")
                }
                w.speakFinal("now the contractor said the timeline depends entirely on permits")
                w.speakFinal("the contractor wants to file the permits paperwork this week")
                w.speakFinal("if permits slip the contractor timeline pushes into June")
                return ctx
            },
            defineCheck("the provisional title reflects the whole conversation so far") { _, _, _ in
                guard let title = w.titleState?.text.lowercased() else {
                    throw BrineStepError("no rolling title after a long conversation")
                }
                // The opening topic has fully slid off the OLD source (the bounded
                // display tail) — yet it still names the conversation.
                guard !w.displayTail.lowercased().contains("kitchen") else {
                    throw BrineStepError("test premise broken: the opening is still in the display tail")
                }
                guard title.contains("kitchen") || title.contains("budget") || title.contains("renovation") else {
                    throw BrineStepError("the title lost the conversation's opening topic: \(title)")
                }
                guard title.contains("contractor") || title.contains("permits") || title.contains("timeline") else {
                    throw BrineStepError("the title ignores where the conversation went: \(title)")
                }
            },
            defineCheck("a settled title does not rewrite itself for minor wording changes") { _, _, _ in
                let before = w.titleState
                // One more benign line re-treading the same topics: the arbiter must
                // hold the settled name (similar candidate → no flicker).
                w.speakFinal("so yes the kitchen budget and the contractor permits as discussed")
                guard w.titleState == before else {
                    throw BrineStepError("the title jittered on a minor change: \(before?.text ?? "nil") → \(w.titleState?.text ?? "nil")")
                }
            },
            defineCheck("a smarter on-device title, when one arrives, replaces the rough one") { _, _, _ in
                w.titleState = LiveTitleArbiter.merged(current: w.titleState,
                                                       candidateText: "Kitchen renovation planning",
                                                       tier: .model)
                guard w.titleState?.tier == .model, w.titleState?.text == "Kitchen renovation planning" else {
                    throw BrineStepError("the model title did not take over: \(String(describing: w.titleState))")
                }
                // …and a later heuristic can never downgrade it.
                w.speakFinal("completely different closing words about travel plans and airports")
                guard w.titleState?.text == "Kitchen renovation planning" else {
                    throw BrineStepError("a heuristic overwrote the model title")
                }
            },
            // MARK: two-tier — external refresh sharpens; offline still names (track 20260717T1500)

            defineStep("the desktop refreshes the title from an external model") { ctx, _, _ in
                w.externalRefresh("Kitchen remodel budget permits and contractor timeline")
                return ctx
            },
            defineCheck("the sharper external title replaces the on-device one") { _, _, _ in
                guard w.titleState?.tier == .external, w.titleState?.text == w.lastExternalTitle else {
                    throw BrineStepError("the external title did not take over: \(String(describing: w.titleState))")
                }
            },
            defineCheck("a later on-device guess never downgrades the external title") { _, _, _ in
                w.onDeviceGuess("A rough on-device kitchen guess")
                guard w.titleState?.tier == .external, w.titleState?.text == w.lastExternalTitle else {
                    throw BrineStepError("an on-device guess downgraded the external title: \(String(describing: w.titleState))")
                }
            },
            defineStep("the desktop is unreachable") { ctx, _, _ in
                // Offline: no external candidate arrives. The standing title is untouched
                // (the manager keeps the on-device title and simply stops asking the door).
                return ctx
            },
            defineCheck("the on-device title still names the conversation") { _, _, _ in
                guard let title = w.titleState?.text, !title.isEmpty else {
                    throw BrineStepError("offline left the conversation with no name")
                }
            },

            defineCheck("the saved conversation's final title still comes from the full pipeline") { _, _, _ in
                // The durable card law, exercised for real: the session's rolling title
                // seeds the card as PROVISIONAL; the pipeline (Kiln) title takes over and
                // can never be downgraded by a later provisional seed.
                let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("brine-rolling-title-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let id = "cap-rolling-title"
                _ = ConversationCardStore.seedProvisional(
                    captureId: id, baseDir: dir, transcript: w.titleCtx.text,
                    title: w.titleState?.text)
                _ = ConversationCardStore.merge(captureId: id, baseDir: dir,
                                                title: "Kitchen reno: budget and permits")
                let seededAgain = ConversationCardStore.seedProvisional(
                    captureId: id, baseDir: dir, transcript: w.titleCtx.text,
                    title: "A provisional pretender")
                let card = ConversationCardStore.load(captureId: id, baseDir: dir)
                guard card?.title == "Kitchen reno: budget and permits", card?.isProvisional == false,
                      seededAgain == false else {
                    throw BrineStepError("the pipeline title is not authoritative: \(String(describing: card))")
                }
            },
        ]
    }
}
