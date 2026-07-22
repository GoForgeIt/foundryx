import XCTest
import Foundation
import Combine
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/local-brain-setup.feature. Every scenario drives the REAL
/// `LocalBrainPreparer` + `LocalBrainStatus` — the same types the app's setup banner
/// binds to — with the download, build, clock, and sleep injected, so a 60-second stall
/// is proven in milliseconds and no network is ever touched.
final class LocalBrainSetupFeatureTests: XCTestCase {
    func testLocalBrainSetupFeature() async throws {
        try await BrineFeatureRunner.run("local-brain-setup",
                                         registry: StepRegistry(LocalBrainSetupSteps.make(world: .init())))
    }
}

private final class BrainSetupWorld: @unchecked Sendable {
    let clock = FakeSetupClock()
    let policy = BrainSetupPolicy(stallTimeout: 60, buildTimeout: 180, pollInterval: 2)
    var status: LocalBrainStatus!
    var preparer: LocalBrainPreparer!
    var lastError: (any Error)?
    /// Flips true after the first failing attempt, so "the connection is back" makes the
    /// SAME preparer succeed on retry.
    let connectionDown = Flag()
    /// EVERY phase the status passed through, not just the one it ended on (T1). Checking
    /// only the final `bannerText` cannot see a banner that appeared and then went away —
    /// which is exactly what "I see no setup banner at all" is about.
    let seen = PhaseLog()
    private var observer: AnyCancellable?

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [LocalBrainStatus.Phase] = []
        func reset() { lock.lock(); phases = []; lock.unlock() }
        func append(_ p: LocalBrainStatus.Phase) { lock.lock(); phases.append(p); lock.unlock() }
        var all: [LocalBrainStatus.Phase] { lock.lock(); defer { lock.unlock() }; return phases }
        /// Every banner the user would have seen, in order.
        var banners: [String] { all.compactMap { LocalBrainStatus.bannerText(for: $0) } }
    }

    @MainActor func makeStatus() {
        status = LocalBrainStatus()
        seen.reset()
        observer = status.$phase.sink { [seen] phase in seen.append(phase) }
    }
}

private enum LocalBrainSetupSteps {
    static func make(world w: BrainSetupWorld) -> [StepDefinition] {
        [
            defineStep("the on-device brain needs to fetch its speech model") { ctx, _, _ in
                await w.makeStatus()
                w.lastError = nil
                return ctx
            },

            defineStep("the on-device brain model is already on the phone and healthy") { ctx, _, _ in
                await w.makeStatus()
                w.lastError = nil
                w.preparer = LocalBrainPreparer(
                    steps: .init(download: { onProgress in onProgress(1.0) }, build: {}),
                    policy: w.policy,
                    status: w.status,
                    sleep: { _ in await Task.yield() })
                return ctx
            },

            defineStep("the on-device brain failed to fetch its speech model") { ctx, _, _ in
                await w.makeStatus()
                w.connectionDown.set(true)
                w.preparer = LocalBrainPreparer(
                    steps: .init(
                        download: { _ in
                            if w.connectionDown.isSet { throw URLError(.notConnectedToInternet) }
                        },
                        build: {}),
                    policy: w.policy,
                    status: w.status,
                    sleep: { _ in await Task.yield() })
                do { try await w.preparer.prepare() } catch { w.lastError = error }
                guard await w.status.isFailed else {
                    throw BrineStepError("expected the first attempt to fail")
                }
                return ctx
            },

            defineStep("the download stops making progress") { ctx, _, _ in
                let clock = w.clock
                w.preparer = LocalBrainPreparer(
                    steps: .init(
                        download: { onProgress in
                            onProgress(0.1)                    // 10% lands, then nothing
                            try await Task.sleep(nanoseconds: 120_000_000_000)
                        },
                        build: {}),
                    policy: w.policy,
                    status: w.status,
                    clock: { clock.now },
                    sleep: { d in clock.advance(d); await Task.yield() })
                do { try await w.preparer.prepare() } catch { w.lastError = error }
                return ctx
            },

            defineStep("the download keeps making progress slowly for far longer than the stall limit") { ctx, _, _ in
                let clock = w.clock
                w.preparer = LocalBrainPreparer(
                    steps: .init(
                        download: { onProgress in
                            for i in 1...100 {
                                clock.advance(3)               // 300 virtual seconds total
                                onProgress(Double(i) / 100)
                                await Task.yield()
                            }
                        },
                        build: {}),
                    policy: w.policy,
                    status: w.status,
                    clock: { clock.now },
                    sleep: { _ in await Task.yield() })
                do { try await w.preparer.prepare() } catch { w.lastError = error }
                if clock.now <= w.policy.stallTimeout {
                    throw BrineStepError("the scenario must outlast the stall limit")
                }
                return ctx
            },

            defineStep("I choose to try again and the connection is back") { ctx, _, _ in
                w.connectionDown.set(false)
                let tapped = await MainActor.run { () -> Bool in
                    guard let tap = w.status.retryAction else { return false }
                    tap()
                    return true
                }
                guard tapped else { throw BrineStepError("no retry action was offered") }
                for _ in 0..<300 {
                    if await w.status.phase == .ready { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                return ctx
            },

            defineStep("the app prepares the on-device brain") { ctx, _, _ in
                do { try await w.preparer.prepare() } catch { w.lastError = error }
                return ctx
            },

            defineCheck("I am told the setup failed and how far it got") { _, _, _ in
                let text = await w.status.bannerText
                guard let text, text.contains("setup failed"), text.contains("10%") else {
                    throw BrineStepError("banner did not name the failure and its progress: \(text ?? "nil")")
                }
                guard case .downloadStalled? = w.lastError as? BrainSetupError else {
                    throw BrineStepError("expected a stall error, got \(String(describing: w.lastError))")
                }
            },

            defineCheck("I am offered a way to try again") { _, _, _ in
                guard await w.status.canRetry, await w.status.retryLabel == "Try again" else {
                    throw BrineStepError("no retry affordance on the failure banner")
                }
            },

            defineCheck("I am no longer offered a way to try again") { _, _, _ in
                if await w.status.canRetry { throw BrineStepError("retry still offered after success") }
            },

            defineCheck("I am no longer told it is setting up") { _, _, _ in
                if await w.status.isPreparing {
                    throw BrineStepError("still showing the indefinite setup spinner")
                }
                let text = await w.status.bannerText ?? ""
                if text.hasPrefix("Setting up") {
                    throw BrineStepError("banner still reads as setup: \(text)")
                }
            },

            defineCheck("the on-device brain finishes setting up") { _, _, _ in
                guard await w.status.phase == .ready else {
                    throw BrineStepError("brain not ready: \(await w.status.phase)")
                }
            },

            defineCheck("I am not shown a failure") { _, _, _ in
                if await w.status.isFailed {
                    throw BrineStepError("unexpected failure: \(await w.status.bannerText ?? "")")
                }
            },

            // Judged over the WHOLE attempt, not just its final state (T1): a banner that
            // flashed and vanished is still a banner the user saw, and the old
            // final-state-only check could not fail on it.
            defineCheck("I see no setup banner at all") { _, _, _ in
                if let flashed = w.seen.banners.first {
                    throw BrineStepError(
                        "a setup banner appeared during the attempt: \"\(flashed)\" "
                        + "(phases: \(w.seen.all))")
                }
                if let text = await w.status.bannerText {
                    throw BrineStepError("unexpected banner: \(text)")
                }
            },
        ]
    }
}
