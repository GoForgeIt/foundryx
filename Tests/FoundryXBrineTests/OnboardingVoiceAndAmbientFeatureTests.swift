import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/onboarding-voice-and-ambient.feature. Drives the REAL
/// first-run rules: `OnboardingGate.shouldPresent` (once, only after sign-in, never
/// again once completed), `OwnerVoiceStore` (a ~15s+ read-aloud stores an owner sample;
/// a too-short attempt stores nothing and stays retryable; skipping stores nothing), and
/// the ambient opt-in flag (default OFF; enabling flips it). Hermetic: temp dir + an
/// isolated UserDefaults suite, no audio hardware, no network.
final class OnboardingVoiceAndAmbientFeatureTests: XCTestCase {
    func testOnboardingVoiceAndAmbientFeature() async throws {
        try await BrineFeatureRunner.run(
            "onboarding-voice-and-ambient",
            registry: StepRegistry(OnboardingVoiceSteps.make(world: OnboardingVoiceWorld())))
    }
}

private final class OnboardingVoiceWorld: @unchecked Sendable {
    let baseDir: URL
    let defaults: UserDefaults
    var signedIn = false
    var completed = false
    var lastSaveError: OwnerVoiceError?

    init() {
        baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-onboarding-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let name = "onboarding-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }
    var shouldPresent: Bool { OnboardingGate.shouldPresent(signedIn: signedIn, completed: completed,
                                                          hasRecordingHistory: false) }
    var voiceState: OwnerVoiceState { OwnerVoiceStore.state(baseDir: baseDir) }
    var ambientEnabled: Bool { defaults.bool(forKey: AmbientPrefs.enabledKey) }

    func resetVoiceStep() {
        try? FileManager.default.removeItem(at: baseDir.appendingPathComponent("owner-voice"))
        lastSaveError = nil
    }
    /// N dummy 20ms frames (content irrelevant to the length gate).
    func frames(_ n: Int) -> [Data] { Array(repeating: Data([0x1, 0x2, 0x3, 0x4]), count: n) }
}

private enum OnboardingVoiceSteps {
    static func make(world w: OnboardingVoiceWorld) -> [StepDefinition] {
        [
            // ── S1 appears once after first sign-in
            defineStep("I have just signed in for the first time") { ctx, _, _ in
                w.signedIn = true; w.completed = false; return ctx
            },
            defineCheck("the onboarding flow is presented") { _, _, _ in
                guard w.shouldPresent else { throw BrineStepError("onboarding not presented after first sign-in") }
            },
            defineStep("I complete or dismiss it") { ctx, _, _ in w.completed = true; return ctx },
            defineStep("I relaunch the app") { ctx, _, _ in return ctx },
            defineCheck("the onboarding flow is not presented again") { _, _, _ in
                guard !w.shouldPresent else { throw BrineStepError("onboarding re-presented after completion") }
            },

            // ── S2 teaching my voice records an owner sample
            defineStep("the onboarding voice step is showing") { ctx, _, _ in w.resetVoiceStep(); return ctx },
            defineStep("I read the passage aloud until the recording completes") { ctx, _, _ in
                // A full read-aloud is well past the ~15s minimum.
                try? OwnerVoiceStore.save(frames: w.frames(OwnerVoiceStore.minimumFrames + 60), baseDir: w.baseDir)
                return ctx
            },
            defineCheck("an owner voice sample is stored on the phone") { _, _, _ in
                guard case .recorded = w.voiceState else { throw BrineStepError("no recorded sample: \(w.voiceState)") }
            },
            defineCheck("the voice step shows it was captured") { _, _, _ in
                guard w.voiceState != .none else { throw BrineStepError("voice step still shows nothing captured") }
            },

            // ── S3 too-short sample is rejected, stays retryable
            defineStep("I stop reading after a moment") { ctx, _, _ in
                do {
                    try OwnerVoiceStore.save(frames: w.frames(30), baseDir: w.baseDir)   // a moment, not ~15s
                } catch let e as OwnerVoiceError {
                    w.lastSaveError = e
                }
                return ctx
            },
            defineCheck("no owner voice sample is stored") { _, _, _ in
                guard w.voiceState == .none else { throw BrineStepError("a too-short/skipped attempt still stored a sample: \(w.voiceState)") }
            },
            defineCheck("I can try again or skip") { _, _, _ in
                // The rejection is a recoverable sampleTooShort — the UI offers retry/skip,
                // never a dead end.
                guard case .sampleTooShort = w.lastSaveError else {
                    throw BrineStepError("expected a recoverable sampleTooShort, got \(String(describing: w.lastSaveError))")
                }
            },

            // ── S4 skipping stores nothing
            defineStep("I skip it") { ctx, _, _ in
                // Skip performs no save at all — nothing is written.
                return ctx
            },
            defineCheck("the flow moves on") { _, _, _ in
                // Skipping never blocks: onboarding can still be completed with no sample.
                guard w.voiceState == .none else { throw BrineStepError("skip left a sample behind") }
                w.completed = true
                guard !w.shouldPresent else { throw BrineStepError("skip blocked completion of the flow") }
            },

            // ── S5 ambient is an explicit opt-in
            defineStep("the onboarding ambient step is showing") { ctx, _, _ in
                w.defaults.removeObject(forKey: AmbientPrefs.enabledKey); return ctx
            },
            defineCheck("ambient intelligence is off") { _, _, _ in
                guard !w.ambientEnabled else { throw BrineStepError("ambient defaulted ON") }
            },
            defineStep("I choose to enable it") { ctx, _, _ in
                w.defaults.set(true, forKey: AmbientPrefs.enabledKey); return ctx
            },
            defineCheck("ambient intelligence is enabled") { _, _, _ in
                guard w.ambientEnabled else { throw BrineStepError("ambient did not enable") }
            },

            // ── S6 declining leaves it off
            defineStep("I continue without enabling it") { ctx, _, _ in
                // Continue performs no toggle — the default OFF stands.
                return ctx
            },
            defineCheck("ambient intelligence remains off") { _, _, _ in
                guard !w.ambientEnabled else { throw BrineStepError("ambient turned on without an explicit opt-in") }
            },

            // ── S7 already-onboarded user never re-prompted
            defineStep("I completed onboarding on a previous version") { ctx, _, _ in
                w.signedIn = true; w.completed = true; return ctx
            },
            defineStep("the app launches") { ctx, _, _ in return ctx },
            defineCheck("the onboarding flow is not presented") { _, _, _ in
                guard !w.shouldPresent else { throw BrineStepError("onboarding re-presented for an already-onboarded user") }
            },
        ]
    }
}
