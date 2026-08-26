import SwiftUI
import Grain

// NOTE: no `import FoundryXKit` — the app target compiles Sources/FoundryXKit directly into
// this same module (see project.yml), so `RecordingJourneyRow` et al. are already in scope;
// importing a non-existent module breaks the Xcode build.

/// WHERE THIS RECORDING IS, DRAWN. Nick tapped Bring over, the recording reached his Vault and
/// was transcribed there, and his phone had nothing to say about any of it.
///
/// THIS VIEW DECIDES NOTHING. Every sentence, every stage and the answer to "may a bar be drawn
/// here" arrive already decided on the `RecordingJourneyRow`s it is handed, because `swift test`
/// compiles the SPM package only and cannot see this file — a rule written here is a rule
/// nothing in this repository can execute. `App/RecordingJourneyBand.swift` is therefore a
/// renderer: it maps `row.state` to a colour and `row.drawsABar` to the presence of a bar, and
/// it spells no stage name and no copy of its own.
///
/// THE BAR IS GATED ON `row.drawsABar` AND ON NOTHING ELSE. `RecordingJourneyMeasure` has no
/// percent case; a fraction can only be read off `.counted(done, of: total)`, which only
/// `progress(done:total:)` can build, and which refuses every denominator nobody measured. This
/// surface has printed an invented number three times — 44-minute rows from an unmeasured
/// divisor, kilobytes read back as bytes, "4 KB" on a 19,770-byte file — and each time the
/// arithmetic was fine.
///
/// IT IS NOT A STEPPER AND IT IS NOT INSIDE A FACE. `ConversationStepper` is banned from the
/// detail faces by the prototype-realignment track and that ban stands; this band sits above the
/// face picker, in the metadata region, and says what is happening rather than drawing a
/// four-dot pipeline over it.
struct RecordingJourneyBand: View {
    let rows: [RecordingJourneyRow]
    /// The provisional-name note, when the name on screen came from the first window. `nil`
    /// for a full name — a permanent badge on a permanent name is noise.
    var provisionalNote: String? = nil

    /// Every stage settled — nothing is in flight and nothing failed.
    ///
    /// ⚠ THE CARD EARNS ITS SPACE ONLY WHILE SOMETHING IS HAPPENING. Nick, on the shipped
    /// build: "each recording now has another card underneath it ... this is great but it takes
    /// so much space". The words matter while a stage is WORKING — they say what the phone is
    /// waiting on. Once every stage is done they say only "this finished", which the row above
    /// already implies, and they cost a whole second card per recording to say it.
    ///
    /// `.cannotHappen` counts as settled: a stage that will never occur is not pending, and a
    /// tier where it can't happen must not be held open by it forever.
    private var allSettled: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.state == .done || $0.state == .cannotHappen }
    }

    var body: some View {
        if rows.isEmpty && provisionalNote == nil {
            EmptyView()
        } else if allSettled && provisionalNote == nil {
            // SETTLED — one inline strip of dots, no card chrome, no per-stage lines. Same
            // stages, same order, same accessibility identifier, a fraction of the height.
            HStack(spacing: GrainSpacing.x1) {
                ForEach(rows, id: \.stage) { row in
                    dot(row.state)
                }
            }
            .accessibilityIdentifier("recording-journey")
            .accessibilityLabel(settledSummary)
        } else {
            VStack(alignment: .leading, spacing: GrainSpacing.x2) {
                if let provisionalNote {
                    Text(provisionalNote)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("recording-name-provisional")
                }
                ForEach(rows, id: \.stage) { row in
                    stageRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GrainSpacing.x3)
            .background(RoundedRectangle(cornerRadius: 12).fill(GrainColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(GrainColor.borderFaint, lineWidth: 1))
            .accessibilityIdentifier("recording-journey")
        }
    }

    /// What the dots say out loud. Collapsing to icons must not cost a screen-reader the
    /// stage names — the strip is a VISUAL compression, not an information one.
    private var settledSummary: String {
        let done = rows.filter { $0.state == .done }.map(\.line)
        return done.isEmpty ? "All steps finished" : done.joined(separator: ", ") + " — finished"
    }

    @ViewBuilder
    private func stageRow(_ row: RecordingJourneyRow) -> some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x1) {
            HStack(spacing: GrainSpacing.x2) {
                dot(row.state)
                Text(row.line)
                    .grainTextStyle(.caption)
                    .foregroundStyle(tint(row.state))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let trailing = countLabel(row.measure) {
                    Text(trailing)
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textFaint)
                        .monospacedDigit()
                }
            }
            // THE ONLY PREDICATE A BAR IS DRAWN FROM.
            if let fraction = row.measure.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(GrainColor.textFaint.opacity(0.2))
                        Capsule().fill(GrainColor.sage)
                            .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    }
                }
                .frame(height: 4)
                .accessibilityIdentifier("recording-journey-bar-\(row.stage.rawValue)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recording-journey-\(row.stage.rawValue)")
    }

    /// A TALLY IS SHOWN AS A COUNT AND NEVER AS A SHARE. `.counted` also renders as a count
    /// beside its bar, because "79 of 100" is the fact and the bar is the picture of it.
    private func countLabel(_ measure: RecordingJourneyMeasure) -> String? {
        switch measure {
        case .none: return nil
        case .tally(let n): return "\(n)"
        case .counted(let done, let total): return "\(done)/\(total)"
        }
    }

    @ViewBuilder
    private func dot(_ state: RecordingJourneyState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(GrainColor.sage)
        case .working:
            Circle().fill(GrainColor.sage).frame(width: 8, height: 8)
        case .waiting:
            Circle().fill(GrainColor.textFaint.opacity(0.4)).frame(width: 8, height: 8)
        case .cannotHappen:
            Image(systemName: "minus.circle")
                .font(.system(size: 12)).foregroundStyle(GrainColor.textFaint)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(GrainColor.amber)
        }
    }

    private func tint(_ state: RecordingJourneyState) -> Color {
        switch state {
        case .done, .working: return GrainColor.ink
        case .waiting, .cannotHappen: return GrainColor.textMuted
        case .failed: return GrainColor.amber
        }
    }
}

/// The band bound to a live status poller — the seam that makes the ladder REACHED rather than
/// merely written. `CaptureStatusPoller` already runs for every visible capture; it now also
/// publishes the journey reading it derived from the same reply, so this costs no extra traffic.
struct CaptureJourneyBand: View {
    @ObservedObject var poller: CaptureStatusPoller
    /// The name currently on screen, so a provisional one can say so. `nil` while unnamed.
    var name: RecordingName? = nil

    var body: some View {
        RecordingJourneyBand(
            rows: RecordingJourneyPresentation.ladder(poller.journey),
            provisionalNote: RecordingNamePresentation.note(for: name))
            .onAppear { poller.start() }
    }
}
