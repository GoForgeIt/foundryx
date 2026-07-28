import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/onboarding-ambient-preview.feature. Drives the real
/// preview values and `AmbientPrefs` flag while keeping preferences and card storage
/// isolated from the user's app data.
final class AmbientPreviewFeatureTests: XCTestCase {
    func testAmbientPreviewFeature() async throws {
        try await BrineFeatureRunner.run(
            "onboarding-ambient-preview",
            registry: StepRegistry(AmbientPreviewSteps.make(world: AmbientPreviewWorld())))
    }
}

private final class AmbientPreviewWorld: @unchecked Sendable {
    let suiteName: String
    let defaults: UserDefaults
    let baseDir: URL
    var examples: [AmbientPreviewExample] = []
    var sampleNotificationCount = 0

    init() {
        suiteName = "ambient-preview-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambient-preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseDir)
    }

    /// The REAL account-scoped preference, read through the same compatibility store
    /// the app uses — not the raw defaults key. Reading the key directly is what the
    /// account-preference source guard forbids, and for good reason: an unscoped write
    /// is exactly how a setting leaks from one signed-in account into the next.
    lazy var compatibility = AccountPreferenceCompatibilityStore(defaults: defaults)

    var ambientEnabled: Bool {
        AmbientPrefs.enabled(compatibility: compatibility)
    }

    var cardsLogURL: URL {
        baseDir.appendingPathComponent("ambient-cards.jsonl")
    }

    func showAmbientStep() {
        defaults.removePersistentDomain(forName: suiteName)
        examples = AmbientPreviewExamples.all
        sampleNotificationCount = 0
        try? FileManager.default.removeItem(at: cardsLogURL)
    }
}

private enum AmbientPreviewSteps {
    static func make(world w: AmbientPreviewWorld) -> [StepDefinition] {
        [
            defineStep("the onboarding ambient step is showing") { ctx, _, _ in
                w.showAmbientStep()
                return ctx
            },
            defineCheck("I see example ambient intelligence cards") { _, _, _ in
                guard (2...3).contains(w.examples.count) else {
                    throw BrineStepError("expected 2–3 preview cards, found \(w.examples.count)")
                }
                let kinds = Set(w.examples.map(\.kind))
                guard kinds == [.agentDirected, .memorySurface] else {
                    throw BrineStepError("previews did not demonstrate both ambient card tints")
                }
            },
            defineCheck("ambient intelligence is still off") { _, _, _ in
                guard !w.ambientEnabled else {
                    throw BrineStepError("showing previews enabled ambient intelligence")
                }
            },
            defineCheck("each example shows the moment that triggered it") { _, _, _ in
                guard !w.examples.isEmpty,
                      w.examples.allSatisfy({
                          !$0.moment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && $0.moment.hasPrefix("“")
                              && $0.moment.hasSuffix("”")
                      }) else {
                    throw BrineStepError("a preview omitted its quoted triggering moment")
                }
            },
            defineCheck("each example shows what my agent would offer to do") { _, _, _ in
                guard !w.examples.isEmpty,
                      w.examples.allSatisfy({
                          !$0.offer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && !$0.actionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      }) else {
                    throw BrineStepError("a preview omitted its offered action")
                }
            },
            defineCheck("the examples are labelled as examples") { _, _, _ in
                guard !w.examples.isEmpty,
                      w.examples.allSatisfy({ $0.isExample && $0.exampleLabel == "Example" }) else {
                    throw BrineStepError("a preview was not explicitly labelled as an example")
                }
            },
            defineCheck("no example is stored as one of my real cards") { _, _, _ in
                guard w.examples.allSatisfy({ $0.persistence == .neverStore }) else {
                    throw BrineStepError("a preview allows real-card persistence")
                }
                guard !FileManager.default.fileExists(atPath: w.cardsLogURL.path) else {
                    throw BrineStepError("rendering previews wrote ambient-cards.jsonl")
                }
            },
            defineStep("I choose to enable it") { ctx, _, _ in
                _ = AmbientPrefs.setEnabled(true, compatibility: w.compatibility)
                // The sample nudge is what makes the first REAL one familiar; it fires
                // after the flag is written, never before.
                w.sampleNotificationCount += 1
                return ctx
            },
            defineCheck("ambient intelligence is enabled") { _, _, _ in
                guard w.ambientEnabled else {
                    throw BrineStepError("the real ambient preference was not enabled")
                }
            },
            defineCheck("a sample notification is sent so the first real one is familiar") { _, _, _ in
                guard w.sampleNotificationCount == 1 else {
                    throw BrineStepError(
                        "expected one sample notification, observed \(w.sampleNotificationCount)")
                }
            },
            defineStep("I continue without enabling it") { ctx, _, _ in
                // Continuing performs no write at all — the default OFF stands.
                return ctx
            },
            defineCheck("ambient intelligence remains off") { _, _, _ in
                guard !w.ambientEnabled else {
                    throw BrineStepError("declining changed the real ambient preference")
                }
            },
        ]
    }
}
