import SwiftUI
import Grain

/// The capture surface: an Omi-style timeline of captures, each showing where it
/// is in the pipeline (Recording → Saved on phone → Saved to computer), plus a
/// record control and a global sync indicator so the user can SEE that nothing is
/// lost into the phone — it's held safely and will deliver.
struct CaptureScreen: View {
    @StateObject private var manager: CaptureManager

    init(config: DoorConfig) {
        let target = DoorTarget(baseURL: config.doorURL, bearer: config.bearer)
        _manager = StateObject(wrappedValue: CaptureManager(
            target: target,
            log: DoorLog(),
            makeSource: { OmiBleSource(log: $0) }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            syncBar
            if manager.captures.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: GrainSpacing.x3) {
                        ForEach(manager.captures, id: \.captureId) { wal in
                            CaptureCard(wal: wal)
                        }
                    }
                    .padding(GrainSpacing.x4)
                }
            }
            recordBar
        }
        .grainBackground()
    }

    // Global "your data is safe" signal.
    private var syncBar: some View {
        HStack(spacing: GrainSpacing.x2) {
            if manager.hasPending {
                Circle().fill(GrainColor.amber).frame(width: 8, height: 8)
                Text(syncMessage).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            } else if !manager.captures.isEmpty {
                Circle().fill(GrainColor.sage).frame(width: 8, height: 8)
                Text("All captures saved to computer").grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, GrainSpacing.x4)
        .padding(.vertical, GrainSpacing.x2)
    }

    private var syncMessage: String {
        let n = manager.pendingSegments
        if case .failed = manager.sourceState {
            return "\(n) segment\(n == 1 ? "" : "s") waiting to sync — will retry"
        }
        return "\(n) segment\(n == 1 ? "" : "s") saved on phone · syncing…"
    }

    private var emptyState: some View {
        VStack(spacing: GrainSpacing.x3) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(GrainColor.inkTertiary)
            Text("No captures yet").grainTextStyle(.title).foregroundStyle(GrainColor.ink)
            Text("Connect your Omi and tap Record. Audio is held on your phone and synced to your computer — nothing leaves your devices.")
                .grainTextStyle(.body).foregroundStyle(GrainColor.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal, GrainSpacing.x6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordBar: some View {
        HStack {
            Spacer()
            if manager.active != nil {
                GrainButton("Stop", variant: .destructive, size: .lg) { manager.stopCapture() }
            } else {
                GrainButton("Record", variant: .filled, size: .lg) { manager.startCapture() }
            }
            Spacer()
        }
        .padding(GrainSpacing.x4)
        .overlay(alignment: .top) { Rectangle().fill(GrainColor.borderHairline).frame(height: 1) }
    }
}

/// One capture's card — observes its WAL so the chip advances live.
private struct CaptureCard: View {
    @ObservedObject var wal: CaptureWAL

    var body: some View {
        VStack(alignment: .leading, spacing: GrainSpacing.x2) {
            HStack(spacing: GrainSpacing.x2) {
                Circle().fill(chipColor).frame(width: 9, height: 9)
                Text(chipLabel).grainTextStyle(.body).foregroundStyle(GrainColor.ink)
                Spacer()
                Text(started).grainTextStyle(.caption).foregroundStyle(GrainColor.textFaint)
            }
            Text(detail).grainTextStyle(.caption).foregroundStyle(GrainColor.textMuted)
        }
        .padding(GrainSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).fill(GrainColor.surfaceElevated))
        .overlay(RoundedRectangle(cornerRadius: GrainRadius.lg, style: .continuous).strokeBorder(GrainColor.border, lineWidth: 1))
    }

    private var chipColor: Color {
        switch wal.status.stage {
        case .recording: return GrainColor.forgeBlue
        case .savedOnPhone: return GrainColor.amber
        case .savedToComputer: return GrainColor.sage
        }
    }
    private var chipLabel: String {
        switch wal.status.stage {
        case .recording: return wal.status.streaming ? "🔴 Recording" : "💾 Saved on phone"
        case .savedOnPhone: return "💾 Saved on phone"
        case .savedToComputer: return "✅ Saved to computer"
        }
    }
    private var detail: String {
        let s = wal.status
        let kb = String(format: "%.1f", Double(s.bytes) / 1024)
        let synced = "\(s.syncedSegments)/\(s.totalSegments) segments synced · \(kb) KB"
        if let err = s.lastSyncError, s.pendingSegments > 0 { return "\(synced) · ⏳ \(err)" }
        return synced
    }
    private var started: String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f.string(from: wal.status.startedAt)
    }
}
