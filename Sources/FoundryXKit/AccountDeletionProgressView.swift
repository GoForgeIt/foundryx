import SwiftUI
import Grain

// AccountDeletionProgressView — the page the person watches while "delete
// everything now" runs, and the page that tells them WHICH step refused.
//
// It replaces a bare `ProgressView()` overlay. A spinner over a destructive,
// irreversible, minutes-long operation says nothing about what has already been
// destroyed, and on failure the app fell back to one line naming a step that
// does not exist ("preparing"). Every row here comes from a step the deletion
// lifecycle actually announced.

public struct AccountDeletionProgressView: View {
    @ObservedObject private var model: AccountDeletionProgressModel
    /// Offered ONLY when the failure is retryable. A retry button on a failure
    /// that can never succeed is worse than no button.
    private let onRetry: () -> Void
    private let onClose: () -> Void

    public init(
        model: AccountDeletionProgressModel,
        onRetry: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.onRetry = onRetry
        self.onClose = onClose
    }

    private var presentation: AccountDeletionProgressPresentation {
        model.presentation
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stepList
                if let failure = presentation.failure {
                    failureBlock(failure)
                }
                if presentation.isFinished {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("deletion-progress-done")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .grainBackground()
        .navigationTitle("Deleting your account")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("deletion-progress")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if presentation.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(presentation.headline)
                    .grainTextStyle(.body)
                    .foregroundStyle(
                        presentation.failure == nil
                            ? GrainColor.textMain : GrainColor.dangerRed)
                    .accessibilityIdentifier("deletion-progress-headline")
            }
            Text("\(presentation.completedCount) of \(presentation.totalCount) steps finished")
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
            if presentation.isRunning {
                Text("Don't close the app until this finishes — your account stays closed until every erase step completes.")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presentation.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(marker(step.state))
                        .grainTextStyle(.caption)
                        .foregroundStyle(tint(step.state))
                        .frame(width: 16, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(step.title)
                        .grainTextStyle(.body)
                        .foregroundStyle(tint(step.state))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title), \(spoken(step.state))")
                .accessibilityIdentifier("deletion-step-\(step.id)")
            }
        }
    }

    private func failureBlock(
        _ failure: AccountDeletionProgressFailure
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure.title)
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.dangerRed)
                .accessibilityIdentifier("deletion-failure-title")
            Text(failure.message)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("deletion-failure-message")
            HStack(spacing: 16) {
                if failure.isRetryable {
                    Button("Try again", action: onRetry)
                        .accessibilityIdentifier("deletion-retry")
                }
                Button("Close", action: onClose)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(GrainColor.dangerRed.opacity(0.08)))
    }

    private func marker(_ state: AccountDeletionProgressStep.State) -> String {
        switch state {
        case .waiting: return "○"
        case .running: return "◐"
        case .finished: return "●"
        case .failed: return "✕"
        }
    }

    private func spoken(_ state: AccountDeletionProgressStep.State) -> String {
        switch state {
        case .waiting: return "not started"
        case .running: return "in progress"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }

    private func tint(
        _ state: AccountDeletionProgressStep.State
    ) -> Color {
        switch state {
        case .waiting: return GrainColor.textFaint
        case .running: return GrainColor.textMain
        case .finished: return GrainColor.textMuted
        case .failed: return GrainColor.dangerRed
        }
    }
}
