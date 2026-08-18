// FoundryXDiagShipping — the ONE place a diagnostic batch leaves this process, and the one
// place that can refuse to let it.
//
// WHAT WAS MEASURED, 2026-08-18. 385 `cmd errand.*` lines reached the LIVE relay's /diag/log
// from `build=1 install=1a255475 device=arm64 battery=-1`, uploading to
// `http://127.0.0.1:1/foundryx/capture`. That is not a handset: `build=1` is a test host,
// `device=arm64` is a simulator, `battery=-1` is a machine with no battery, and port 1 is the
// unreachable address the suites point capture at. The app-hosted scenario suite was shipping
// its own errands into the production diagnostic sink.
//
// WHY THAT IS WORSE THAN NOISE. This log is the instrument this project diagnoses the recorder
// with, and the pollution is CONVINCING: the lines are well-formed, they carry the same
// vocabulary a real errand carries, and they arrive while somebody is watching for a real
// one. The main loop nearly read those errands as Nick's own. An instrument that reports the
// observer's own movements is worse than no instrument, because it is believed.
//
// WHY IT IS A CHOKE POINT AND NOT A FLAG. Three types in this kit POST to the relay's
// /diag/log — `DoorLog` (the batched device log), `RemoteSession` (the pre-sign-in trace) and
// `DeletionRecorder` (the record of an irreversible act). A rule stated three times is a rule
// that holds in two places after the next edit. They all send here, the decision is taken
// once, and the source gate in `ATestRunDoesNotShipIntoTheProductionLogTests` holds that they
// keep doing so.
//
// WHAT IT DOES NOT DO. It does not silence the logs. Everything is still recorded in-process —
// `DoorLog.entries`, `DeletionRecorder.recorded()` — because those are what the suites assert
// on and what `dump()` copies out. Only the leg that leaves the machine is withheld.

import Foundation

public enum FoundryXDiagShipping {

    // MARK: - Is this process a test run?

    /// The environment variables an XCTest host is launched with. Any one of them present means
    /// a test bundle is driving this process — this is how the app-hosted lane looks from
    /// inside the app, where the binary is the shipping app and the argument vector is not.
    public static let testEnvironmentKeys = [
        "XCTestConfigurationFilePath",   // set by xctest / xcodebuild for every bundle it runs
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
    ]

    /// THE DECISION, TAKEN FROM WHAT A TEST PROCESS ACTUALLY LOOKS LIKE.
    ///
    /// Pure, and taking its three facts as parameters, so both answers can be asserted. The
    /// half that matters is the FALSE one: a guard that cannot say "this is a real handset"
    /// would blind the only instrument this project has, which is a worse defect than the one
    /// it is here to fix.
    ///
    /// - Parameter linkedTestFramework: whether XCTest is loaded in this process. This is the
    ///   signal that survives everything else — an app-hosted bundle injected into the shipping
    ///   app has XCTest loaded and the app's own argv.
    /// - Parameter executablePath: `argv[0]`. Catches the swiftpm hostless runner, whose
    ///   executable is `…/FoundryXPackageTests.xctest/Contents/MacOS/FoundryXPackageTests`.
    public static func looksLikeATestProcess(environment: [String: String],
                                            linkedTestFramework: Bool,
                                            executablePath: String) -> Bool {
        if linkedTestFramework { return true }
        for key in testEnvironmentKeys where environment[key] != nil { return true }
        let executable = (executablePath as NSString).lastPathComponent
        if executable == "xctest" { return true }
        if executable.hasSuffix(".xctest") { return true }
        if executable.hasSuffix("PackageTests") { return true }
        return false
    }

    /// WHETHER THIS PROCESS IS A TEST RUN. Read once, at first use, because the answer cannot
    /// change while a process lives and a per-batch re-read would put a `NSClassFromString`
    /// on the log's flush path.
    public static let underTest: Bool = looksLikeATestProcess(
        environment: ProcessInfo.processInfo.environment,
        linkedTestFramework: NSClassFromString("XCTestCase") != nil,
        executablePath: ProcessInfo.processInfo.arguments.first ?? "")

    // MARK: - The one leg off this machine

    private static let counters = Counters()

    /// How many diagnostic batches actually left this process.
    public static var shipped: Int { counters.read().shipped }

    /// How many were REFUSED because this process is a test run.
    ///
    /// IT IS COUNTED, NOT DROPPED SILENTLY, and that is what makes the gate non-vacuous: a test
    /// asserting "nothing shipped" passes just as well when the code path never ran at all.
    /// A withheld batch is proof the sender reached this line and was turned back.
    public static var withheld: Int { counters.read().withheld }

    /// SEND A DIAGNOSTIC BATCH, unless this process is a test run.
    /// - Returns: whether the request was handed to the network.
    @discardableResult
    public static func send(_ request: URLRequest, using session: URLSession = .shared) -> Bool {
        guard !underTest else {
            counters.withhold()
            return false
        }
        counters.ship()
        session.dataTask(with: request).resume()  // fire-and-forget
        return true
    }

    /// Test seam: forget what has been counted, so one test's assertion is not an assertion
    /// about its neighbours. It resets NUMBERS ONLY — there is no way to switch the refusal off.
    public static func resetCountsForTests() { counters.reset() }

    /// The counters, behind a lock. `send` is called from whatever thread flushed.
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var shipped = 0
        private var withheld = 0
        func ship() { lock.lock(); shipped += 1; lock.unlock() }
        func withhold() { lock.lock(); withheld += 1; lock.unlock() }
        func reset() { lock.lock(); shipped = 0; withheld = 0; lock.unlock() }
        func read() -> (shipped: Int, withheld: Int) {
            lock.lock(); defer { lock.unlock() }
            return (shipped, withheld)
        }
    }
}
