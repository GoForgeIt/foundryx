import XCTest
import Foundation
@testable import FoundryXKit

/// REVIEW PROBE (round 10) — TEMPORARY. Isolates the ONE variable the T5 record leaves
/// unexplained: why the S01 driver's synthetic session is stamped `.discarded` while
/// `CaptureFinalizeTests` — the same frames, the same bar — finalizes.
///
/// Three arms, one variable changed at a time:
///   A  no account binding, closed with `endCurrentConversation()`   (the S01 close)
///   B  account binding,    closed with `endCurrentConversation()`   (the S01 driver)
///   C  account binding,    closed with a SILENT FRAME               (the CaptureFinalizeTests close)
final class ZZFinalizeProbeTests: ProcessGlobalStateTestCase {

    final class ProbeSource: AudioFrameSource, @unchecked Sendable {
        var onFrame: ((Data) -> Void)?
        var onState: ((AudioSourceState) -> Void)?
        func start() {}
        func stop() {}
    }

    actor Finalized {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
        var all: [String] { ids }
    }

    @MainActor
    private func runArm(bindAccount: Bool, closeWithSilentFrame: Bool,
                        label: String) async throws -> String {
        let token = UUID().uuidString
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("finalize-probe-\(token)", isDirectory: true)
        let baseDir = sandbox.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scopeName = "foundryx.finalize-probe.\(token)"
        let scopeDefaults = UserDefaults(suiteName: scopeName)!
        if bindAccount {
            let container = sandbox.appendingPathComponent("documents/foundryx-captures",
                                                           isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            CaptureAccountScope.setContainerForTests(container)
            CaptureAccountScope.setApplicationSupportRootForTests(
                sandbox.appendingPathComponent("application-support", isDirectory: true))
            CaptureAccountScope.setDefaultsForTests(scopeDefaults)
            CaptureAccountScope.setAccountForTests(email: "probe-\(token)@example.com")
            XCTAssertNotNil(CaptureAccountScope.currentAccountBinding(), "\(label): no binding")
        }
        defer {
            if bindAccount {
                try? CaptureAccountScope.signOutForTests()
                CaptureAccountScope.resetTestEnvironment()
                scopeDefaults.removePersistentDomain(forName: scopeName)
            }
        }

        CaptureSettings.captureSource = .omi
        let source = ProbeSource()
        let finalized = Finalized()
        let manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: baseDir,
            source: source,
            finalize: { id, _ in await finalized.add(id) })
        manager.setAutoFinalizeForTests(false)
        manager.setSilenceGap(0)

        source.onState?(.streaming)
        RealOmiFrames.openSession(source.onFrame)
        let deadline = Date().addingTimeInterval(60)
        while manager.active == nil {
            if Date() > deadline { return "\(label): TIMED OUT opening a conversation" }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let id = manager.active!.captureId
        for _ in 0..<(CaptureManager.minVoicedFramesToUpload + 20) {
            source.onFrame?(RealOmiFrames.cachedVoiced)
        }
        try manager.active?.flushAndWait()
        if closeWithSilentFrame {
            source.onFrame?(RealOmiFrames.silent())
        } else {
            _ = manager.endCurrentConversation()
        }
        let deadline2 = Date().addingTimeInterval(60)
        while manager.active?.captureId == id {
            if Date() > deadline2 { return "\(label): TIMED OUT closing" }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let dir = baseDir.appendingPathComponent(id, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasSuffix(".opus") {
            try? Data().write(to: dir.appendingPathComponent(
                String(f.dropLast(5)) + ".ack"), options: [.atomic])
        }
        await manager.retryPendingFinalizes()
        let discarded = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".discarded").path)
        let reason = (try? String(contentsOf: dir.appendingPathComponent(".discarded"),
                                  encoding: .utf8)) ?? "-"
        let opus = files.filter { $0.hasSuffix(".opus") }.count
        let fin = await finalized.all
        return "\(label): discarded=\(discarded) reason=\"\(reason)\" opusSegments=\(opus) "
            + "finalized=\(fin.count)"
    }

    @MainActor
    func testWhichVariableDiscardsTheSyntheticSession() async throws {
        var lines: [String] = []
        lines.append(try await runArm(bindAccount: false, closeWithSilentFrame: false,
                                      label: "A no-binding  + endCurrentConversation"))
        lines.append(try await runArm(bindAccount: true, closeWithSilentFrame: false,
                                      label: "B binding     + endCurrentConversation"))
        lines.append(try await runArm(bindAccount: true, closeWithSilentFrame: true,
                                      label: "C binding     + silent frame"))
        lines.append(try await runArm(bindAccount: false, closeWithSilentFrame: true,
                                      label: "D no-binding  + silent frame"))
        XCTFail("PROBE RESULTS\n" + lines.joined(separator: "\n"))
    }
}
