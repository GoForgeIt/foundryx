import XCTest
@testable import FoundryXKit

/// THE FIX FOR A LIVE, CROSS-SUITE HAZARD (track 20260722T1244, part 2/9).
///
/// `CaptureSettings` is backed by `UserDefaults.standard` — PROCESS-GLOBAL for the whole test
/// binary, and durable across test classes. The dangerous one is `omiCaptureDesiredState`:
///
///   • SEVEN suites call `CaptureManager.pause()`, which persists `.paused` by design (the
///     user's capture intent is supposed to survive an app restart);
///   • TWENTY-PLUS suites construct a `CaptureManager`, whose `init` READS that value to
///     decide whether the fresh manager is born paused;
///   • only THREE of them defended themselves.
///
/// So whether a given suite passes depended on which suite XCTest happened to run before it.
/// `SpeechGatedCaptureTests` documented this in its own setUp: it had been "surviving only
/// because alphabetical ordering happened to leave `.listening` behind. That is luck, not
/// isolation."
///
/// The instruction for this track was explicit: fix the SOURCE, don't defend twenty consumers.
/// The source is the seven WRITERS, and this is the one place that discipline lives. Any suite
/// that mutates process-global capture settings inherits this class; it snapshots every
/// `CaptureSettings` key before each test and restores it after, so a suite can pause, change
/// the capture source, or shorten the silence gap as freely as it likes and still leave the
/// process exactly as it found it.
///
/// `scripts/ci-gates.sh lint` fails the build if a NEW suite mutates these settings without
/// inheriting this class — which is what makes the fix non-regressable rather than a
/// convention that decays.
class ProcessGlobalStateTestCase: XCTestCase {

    private var savedDesiredState: OmiCaptureDesiredState?
    private var savedSource: CaptureSourceKind?
    private var savedGap: TimeInterval?

    override func setUp() {
        super.setUp()
        savedDesiredState = CaptureSettings.omiCaptureDesiredState
        savedSource = CaptureSettings.captureSource
        savedGap = CaptureSettings.silenceGapSeconds
        // Start every test from the FIRST-LAUNCH defaults, so a suite's outcome cannot depend
        // on what ran before it. These are the same values a fresh install would read.
        CaptureSettings.omiCaptureDesiredState = .listening
        CaptureSettings.captureSource = .omi
        CaptureSettings.silenceGapSeconds = CaptureSettings.defaultGapSeconds
    }

    override func tearDown() {
        if let v = savedDesiredState { CaptureSettings.omiCaptureDesiredState = v }
        if let v = savedSource { CaptureSettings.captureSource = v }
        if let v = savedGap { CaptureSettings.silenceGapSeconds = v }
        savedDesiredState = nil; savedSource = nil; savedGap = nil
        super.tearDown()
    }
}

/// The gate that proves the isolation actually isolates. A test that pauses leaves `.paused`
/// persisted in the process; the base class must hand the NEXT test `.listening` regardless.
/// (Both halves run inside one test, so this assertion does not itself depend on ordering —
/// which is the whole point.)
final class ProcessGlobalStateIsolationTests: ProcessGlobalStateTestCase {

    func testSetUpRestoresFirstLaunchDefaultsAfterAPolluter() {
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening,
                       "setUp hands every test the first-launch default")

        // A polluter does exactly what `CaptureManager.pause()` does.
        CaptureSettings.omiCaptureDesiredState = .paused
        CaptureSettings.captureSource = .phoneMic
        CaptureSettings.silenceGapSeconds = 7

        // Simulate the next test's boundary: tearDown restores, setUp re-defaults.
        tearDown()
        setUp()

        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening,
                       "a paused predecessor must not decide the next test's initial state")
        XCTAssertEqual(CaptureSettings.captureSource, .omi)
        XCTAssertEqual(CaptureSettings.silenceGapSeconds, CaptureSettings.defaultGapSeconds)
    }
}
