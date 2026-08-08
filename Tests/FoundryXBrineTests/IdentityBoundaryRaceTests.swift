import XCTest
@testable import FoundryXKit

final class IdentityBoundaryRaceTests: XCTestCase {
    func testOldReaderCannotRestampWidgetAfterAccountSwitch() throws {
        let fixture = try IdentityRaceFixture()
        defer { fixture.cleanup() }

        let oldBinding = try fixture.activate(subject: "old-owner")
        let readerGuarded = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        let transitionFinished = DispatchSemaphore(value: 0)
        let transitionError = LockedRaceError()

        CaptureAccountScope.setAfterAccountBindingGuardHookForTests {
            readerGuarded.signal()
            _ = releaseReader.wait(timeout: .now() + 5)
        }

        DispatchQueue.global().async {
            _ = CaptureAccountScope.currentAccountBinding()
            readerFinished.signal()
        }
        XCTAssertEqual(readerGuarded.wait(timeout: .now() + 2), .success)

        let newIdentity = fixture.identity(subject: "new-owner")
        let newScope = try CaptureAccountScope.key(for: newIdentity)
        DispatchQueue.global().async {
            do {
                try CaptureAccountScope.activateForTests(newIdentity)
            } catch {
                transitionError.store(error)
            }
            transitionFinished.signal()
        }

        let transitionBeatReader =
            transitionFinished.wait(timeout: .now() + 0.25) == .success
        XCTAssertFalse(
            transitionBeatReader,
            "the identity transition must remain blocked until the guarded reader exits")
        if transitionBeatReader {
            try fixture.seedWidgetPayload(owner: newScope, title: "New account note")
        }
        releaseReader.signal()
        XCTAssertEqual(readerFinished.wait(timeout: .now() + 2), .success)
        if !transitionBeatReader {
            XCTAssertEqual(transitionFinished.wait(timeout: .now() + 2), .success)
            try fixture.seedWidgetPayload(owner: newScope, title: "New account note")
        }
        CaptureAccountScope.setAfterAccountBindingGuardHookForTests(nil)

        XCTAssertNil(transitionError.value)
        XCTAssertNotEqual(oldBinding.scope, newScope)
        XCTAssertEqual(CaptureWidgetSnapshotStore.activeOwnerForTests, newScope)
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.read().lastFinishedTitle,
            "New account note")
    }
}

private final class LockedRaceError: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var value: Error? { lock.withLock { stored } }
    func store(_ error: Error) { lock.withLock { stored = error } }
}

private final class IdentityRaceFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults

    init() throws {
        let token = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-identity-race-\(token)", isDirectory: true)
        defaultsName = "foundryx.identity-race.\(token)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        CaptureAccountScope.resetTestEnvironment()
        CaptureAccountScope.setContainerForTests(root)
        CaptureAccountScope.setDefaultsForTests(defaults)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)
    }

    func activate(subject: String) throws -> CaptureAccountScope.AccountBinding {
        try CaptureAccountScope.activateForTests(identity(subject: subject))
        return try XCTUnwrap(CaptureAccountScope.currentAccountBinding())
    }

    func identity(subject: String) -> AuthIdentity {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
        let payload = Data(#"{"sub":"\#(subject)"}"#.utf8)
        let token = [header, payload].map {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }.joined(separator: ".") + ".test-signature"
        return AuthIdentity(
            provider: AuthProvider.google.rawValue,
            idToken: token,
            refreshToken: nil,
            expiresAt: .distantFuture,
            email: "\(subject)@example.test")
    }

    func seedWidgetPayload(owner: String, title: String) throws {
        defaults.set(owner, forKey: CaptureWidgetSnapshotStore.activeOwnerKey)
        defaults.set(
            try JSONEncoder().encode(CaptureWidgetSnapshotStore.Envelope(
                owner: owner,
                snapshot: CaptureWidgetSnapshot(lastFinishedTitle: title))),
            forKey: CaptureWidgetSnapshotStore.key)
        _ = defaults.synchronize()
    }

    func cleanup() {
        CaptureAccountScope.setAfterAccountBindingGuardHookForTests(nil)
        CaptureWidgetSnapshotStore.resetDefaultsForTesting()
        CaptureAccountScope.resetTestEnvironment()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
