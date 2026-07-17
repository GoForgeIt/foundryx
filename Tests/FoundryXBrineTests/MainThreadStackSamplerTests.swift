import XCTest
@testable import FoundryXKit
#if canImport(Darwin)
import Darwin
#endif

/// MainThreadStackSampler (track 20260717T0900 WS-A) — the cross-thread backtrace sampler
/// that names WHERE a thread is blocked. Driven against a real thread parked in a known
/// state (a semaphore wait): we sample it, then assert we recovered ≥1 resolvable frame
/// with a sane offset and a real image UUID. This is the integration proof that the
/// suspend → thread_get_state → fp-walk → resume → dladdr/LC_UUID pipeline works on the
/// host arch (arm64e / x86_64), so the production path can name a stall from a device.
final class MainThreadStackSamplerTests: XCTestCase {

    /// Thread-safe box for handing the parked thread's mach port back to the test.
    private final class PortBox: @unchecked Sendable {
        private let lock = NSLock()
        private var p: UInt32 = 0
        func set(_ v: UInt32) { lock.lock(); p = v; lock.unlock() }
        func get() -> UInt32 { lock.lock(); defer { lock.unlock() }; return p }
    }

    func testSamplesABlockedThreadWithResolvableFrames() throws {
        #if canImport(Darwin)
        let portBox = PortBox()
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let worker = Thread {
            portBox.set(pthread_mach_thread_np(pthread_self()))
            ready.signal()
            release.wait()            // park in a known blocked state (semaphore wait)
        }
        worker.stackSize = 512 * 1024
        worker.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "worker never reported its port")
        Thread.sleep(forTimeInterval: 0.1)   // let it actually park in release.wait()

        let sampler = MainThreadStackSampler(threadPort: portBox.get())
        let frames = sampler.sample()
        release.signal()                     // unblock the worker regardless of assertions

        XCTAssertFalse(frames.isEmpty, "a parked thread must yield a backtrace")
        // Every frame carries a non-empty binary name and a non-negative offset.
        for f in frames {
            XCTAssertFalse(f.binaryName.isEmpty, "frame resolved to a named image")
            XCTAssertGreaterThanOrEqual(f.offset, 0, "offset into the image is sane")
        }
        // At least one frame resolves to an image whose LC_UUID parsed to a real UUID —
        // that's what lets us atos the frame off-line against the archived dSYM.
        let withUUID = frames.first { !$0.binaryUUID.isEmpty }
        let resolved = try XCTUnwrap(withUUID, "at least one frame carried an image UUID")
        XCTAssertNotNil(UUID(uuidString: resolved.binaryUUID),
                        "the parsed LC_UUID is a canonical 36-char UUID: \(resolved.binaryUUID)")
        #else
        throw XCTSkip("Darwin-only sampler")
        #endif
    }

    /// The sampler NEVER suspends its own thread — that would deadlock the process.
    func testSamplingOwnThreadReturnsEmpty() {
        #if canImport(Darwin)
        let sampler = MainThreadStackSampler(threadPort: pthread_mach_thread_np(pthread_self()))
        XCTAssertTrue(sampler.sample().isEmpty, "sampling self is refused")
        #endif
    }

    /// Before the target port is recorded, sampling is a safe no-op (not a crash).
    func testUnrecordedPortReturnsEmpty() {
        XCTAssertTrue(MainThreadStackSampler(threadPort: 0).sample().isEmpty)
    }

    /// The frames feed straight into the existing hang-stack formatter with kind `stallstack`
    /// — the end-to-end shape a live capture ships.
    func testSampledFramesFormatAsStallStackLines() throws {
        #if canImport(Darwin)
        let portBox = PortBox()
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = Thread {
            portBox.set(pthread_mach_thread_np(pthread_self()))
            ready.signal(); release.wait()
        }
        worker.stackSize = 512 * 1024
        worker.start()
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.1)

        let frames = MainThreadStackSampler(threadPort: portBox.get()).sample()
        release.signal()
        try XCTSkipIf(frames.isEmpty, "no frames sampled (unexpected on Darwin host)")

        let ctx = PerfContext(build: "232", installId: "dead00ff")
        let lines = PerfDiag.hangStackLines(ms: 700, frames: frames, truncated: false,
                                            ctx: ctx, kind: "stallstack")
        XCTAssertTrue(lines.contains { $0.contains(" stallstack ms=700 ") }, "a stallstack line is emitted")
        XCTAssertTrue(lines.contains { $0.contains(" stallimg ms=700 ") }, "an image table line is emitted")
        for line in lines { XCTAssertTrue(line.hasPrefix("perf build=232 dev=dead00ff ")) }
        #else
        throw XCTSkip("Darwin-only sampler")
        #endif
    }
}
