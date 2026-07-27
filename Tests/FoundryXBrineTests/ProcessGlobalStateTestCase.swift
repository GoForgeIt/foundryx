import XCTest
@testable import FoundryXKit

/// THE FIX FOR A LIVE, CROSS-SUITE HAZARD (track 20260722T1244, part 2/9).
///
/// Capture source remains phone-global while the capture runtime settings are now backed
/// by the active account's scoped preference snapshot. Both are process-global test state.
/// The dangerous value is `omiCaptureDesiredState`:
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
/// that mutates process-global capture settings inherits this class. It installs a private,
/// in-memory account preference owner for every test, so a suite can pause or shorten the
/// silence gap without writing another suite's owner. The phone-owned source is restored
/// separately.
///
/// `scripts/ci-gates.sh lint` fails the build if a NEW suite mutates these settings without
/// inheriting this class — which is what makes the fix non-regressable rather than a
/// convention that decays.
class ProcessGlobalStateTestCase: XCTestCase {

    private var savedSource: CaptureSourceKind?
    private var savedLegacyAccountPreferences: [String: Any]?
    private var preferenceDefaults: ProcessGlobalPreferenceDefaults?
    private var preferenceContainer: URL?
    private static let fixtureScope = "acct-0000000000000001"
    // Hostless iOS XCTest reuses com.apple.dt.xctest.tool across invocations. Keep
    // already-shipped unscoped account choices out of each scoped test's preconditions,
    // then put the caller's exact domain back in tearDown.
    private static let legacyAccountPreferenceKeys = [
        AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey,
        AccountPreferenceCatalog.captureSilenceGapSeconds.canonicalKey,
    ]

    override func setUp() {
        super.setUp()
        savedSource = CaptureSettings.captureSource
        savedLegacyAccountPreferences = Dictionary(
            uniqueKeysWithValues: Self.legacyAccountPreferenceKeys.compactMap {
                key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            })
        for key in Self.legacyAccountPreferenceKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        _ = UserDefaults.standard.synchronize()

        let defaults = ProcessGlobalPreferenceDefaults()
        preferenceDefaults = defaults
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "foundryx-capture-preference-fixture-\(UUID().uuidString)",
                isDirectory: true)
        preferenceContainer = container
        try? FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(container)
        CaptureAccountScope.setDefaultsForTests(defaults)
        do {
            try CaptureAccountScope.installAccountResolutionForTests(
                scope: Self.fixtureScope)
            let binding = try XCTUnwrap(
                CaptureAccountScope.currentScopedPreferenceBinding())
            let snapshot = AccountPreferenceSnapshot(
                scope: binding.scope,
                generation: binding.generation,
                values: [
                    AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey:
                        .string(OmiCaptureDesiredState.listening.rawValue),
                    AccountPreferenceCatalog.captureSilenceGapSeconds.canonicalKey:
                        .double(CaptureSettings.defaultGapSeconds),
                    AccountPreferenceCatalog.captureSourceEnabledOverrides.canonicalKey:
                        .boolDictionary([:]),
                ])
            XCTAssertTrue(
                CaptureAccountScope.installAccountPreferenceSnapshot(
                    snapshot,
                    as: binding))
        } catch {
            XCTFail("could not install isolated capture preference owner: \(error)")
        }
        CaptureSettings.captureSource = .omi
    }

    override func tearDown() {
        if let v = savedSource { CaptureSettings.captureSource = v }
        CaptureAccountScope.resetTestEnvironment()
        if let savedLegacyAccountPreferences {
            for key in Self.legacyAccountPreferenceKeys {
                if let value = savedLegacyAccountPreferences[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            _ = UserDefaults.standard.synchronize()
        }
        self.savedLegacyAccountPreferences = nil
        preferenceDefaults = nil
        if let preferenceContainer {
            try? FileManager.default.removeItem(at: preferenceContainer)
        }
        preferenceContainer = nil
        savedSource = nil
        super.tearDown()
    }
}

/// Capture-mechanics fixtures with no authenticated account still have a real owner:
/// `acct-none`. Materialize that signed-out activation snapshot first and prove its
/// fresh intent is fail-closed, then explicitly select listening because subclasses
/// exercise an already-authorized ambient recording. This keeps `.absent` reserved for
/// unresolved restoration instead of letting ordinary test construction fall into it.
class SignedOutListeningCaptureTestCase: ProcessGlobalStateTestCase {

    override func setUp() {
        super.setUp()
        do {
            try CaptureAccountScope.signOutForTests()
            let signedOut = try XCTUnwrap(
                CaptureAccountScope.currentAccountPreferenceSnapshot())
            XCTAssertEqual(signedOut.scope, "acct-none")
            XCTAssertEqual(
                signedOut.presence(
                    for: AccountPreferenceCatalog.captureOMIDesiredState),
                .value(OmiCaptureDesiredState.paused.rawValue),
                "a fresh signed-out activation snapshot must explicitly fail closed")

            CaptureSettings.omiCaptureDesiredState = .listening
            XCTAssertEqual(
                CaptureAccountScope.currentAccountPreferenceSnapshot()?
                    .presence(
                        for: AccountPreferenceCatalog.captureOMIDesiredState),
                .value(OmiCaptureDesiredState.listening.rawValue),
                "an active-capture fixture must explicitly select listening")
        } catch {
            XCTFail(
                "could not install the signed-out capture activation snapshot: \(error)")
        }
    }
}

/// Unit suites need deterministic preference durability without sharing CFPreferences
/// domains. The account-data-isolation feature and deletion integration tests retain
/// real suite-backed UserDefaults coverage; this store isolates capture mechanics.
private final class ProcessGlobalPreferenceDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }

    override func synchronize() -> Bool {
        true
    }
}

/// The gate that proves the isolation actually isolates. A test that pauses leaves `.paused`
/// persisted in the process; the base class must hand the NEXT test its explicit listening
/// fixture regardless.
/// (Both halves run inside one test, so this assertion does not itself depend on ordering —
/// which is the whole point.)
final class ProcessGlobalStateIsolationTests: ProcessGlobalStateTestCase {

    func testSetUpRestoresExplicitListeningFixtureAfterAPolluter() {
        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening,
                       "setUp hands every capture-mechanics test an explicit listening choice")

        // A polluter does exactly what `CaptureManager.pause()` does.
        CaptureSettings.omiCaptureDesiredState = .paused
        CaptureSettings.captureSource = .phoneMic
        CaptureSettings.silenceGapSeconds = 7
        let legacyDesiredStateKey =
            AccountPreferenceCatalog.captureOMIDesiredState.canonicalKey
        let legacySilenceGapKey =
            AccountPreferenceCatalog.captureSilenceGapSeconds.canonicalKey
        UserDefaults.standard.set("listening", forKey: legacyDesiredStateKey)
        UserDefaults.standard.set(120, forKey: legacySilenceGapKey)

        // Simulate the next test's boundary: tearDown restores, setUp re-defaults.
        tearDown()
        setUp()

        XCTAssertEqual(CaptureSettings.omiCaptureDesiredState, .listening,
                       "a paused predecessor must not decide the next test's initial state")
        XCTAssertEqual(CaptureSettings.captureSource, .omi)
        XCTAssertEqual(CaptureSettings.silenceGapSeconds, CaptureSettings.defaultGapSeconds)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: legacyDesiredStateKey),
            "a reused test-host domain must not supply an unscoped account choice")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: legacySilenceGapKey),
            "a reused test-host domain must not supply an unscoped account choice")
        UserDefaults.standard.removeObject(forKey: legacyDesiredStateKey)
        UserDefaults.standard.removeObject(forKey: legacySilenceGapKey)
    }
}
