// AmbientDebugView — "What it's noticing": a live readout of the Tier-1 gate
// decision log so the user can WATCH the ambient lane work even when it isn't
// firing (track 20260710T2030 v3). This is the AC0 feedback surface: gate
// pass/skip counts, latency, and the recent decisions — the same log the Temper
// scorer + router council consume.

import SwiftUI
import Grain
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

struct AmbientDebugView: View {
    @State private var decisions: [AmbientDecision] = []

    private var counts: (gatedNo: Int, candidate: Int, skipped: Int) {
        decisions.reduce(into: (0, 0, 0)) { acc, d in
            switch d.outcome {
            case .gatedNo: acc.0 += 1
            case .candidate: acc.1 += 1
            case .skipped: acc.2 += 1
            }
        }
    }

    var body: some View {
        List {
            Section("Summary") {
                let c = counts
                row("Windows evaluated", "\(decisions.count)")
                row("Nothing to do", "\(c.gatedNo)")
                row("Found something", "\(c.candidate)")
                row("Skipped", "\(c.skipped)")
            }
            Section("Recent decisions") {
                if decisions.isEmpty {
                    Text("Nothing yet. Turn ambient on and record — the gate checks your live transcript about every 10 seconds.")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
                }
                ForEach(Array(decisions.suffix(40).reversed().enumerated()), id: \.offset) { _, d in
                    decisionRow(d)
                }
            }
        }
        .navigationTitle("What it's noticing")
        .grainBackground()
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    @ViewBuilder private func decisionRow(_ d: AmbientDecision) -> some View {
        HStack(alignment: .top) {
            Text(icon(d.outcome))
            VStack(alignment: .leading, spacing: 2) {
                if let cand = d.candidate {
                    Text(cand.summary).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                    Text("“\(cand.utterance)”")
                        .grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
                } else {
                    Text(label(d.outcome, reason: d.skipReason))
                        .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                }
                Text("\(d.windowChars) chars · \(d.latencyMs) ms")
                    .grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            Spacer()
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).grainTextStyle(.body); Spacer()
            Text(v).grainTextStyle(.body).foregroundStyle(GrainColor.textMuted) }
    }

    private func icon(_ o: AmbientDecision.Outcome) -> String {
        switch o { case .gatedNo: return "·"; case .candidate: return "✦"; case .skipped: return "⏭" }
    }
    private func label(_ o: AmbientDecision.Outcome, reason: String?) -> String {
        switch o {
        case .gatedNo: return "Nothing to act on"
        case .candidate: return "Found something"
        case .skipped: return "Skipped (\(reason ?? "busy"))"
        }
    }

    private func reload() {
        decisions = AmbientLane.readDecisions(at: AmbientPrefs.decisionLogURL())
    }
}
