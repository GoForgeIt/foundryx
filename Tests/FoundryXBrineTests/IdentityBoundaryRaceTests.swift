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
        let transitionEntered = DispatchSemaphore(value: 0)
        let transitionFinished = DispatchSemaphore(value: 0)
        let transitionError = LockedRaceError()
        let ordering = LockedRaceOrdering()

        CaptureAccountScope.setAfterAccountBindingGuardHookForTests {
            readerGuarded.signal()
            _ = releaseReader.wait(timeout: .now() + 5)
        }

        DispatchQueue.global().async {
            _ = CaptureAccountScope.currentAccountBinding()
            ordering.record(.readerExited)
            readerFinished.signal()
        }
        XCTAssertEqual(readerGuarded.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(
            CaptureAccountScope.isExposurePublicationGuardHeldForTests,
            "the guarded reader must hold the identity-transition serialization gate")

        let newIdentity = fixture.identity(subject: "new-owner")
        let newScope = try CaptureAccountScope.key(for: newIdentity)
        DispatchQueue.global().async {
            transitionEntered.signal()
            do {
                try CaptureAccountScope.activateForTests(newIdentity)
            } catch {
                transitionError.store(error)
            }
            ordering.record(.transitionExited)
            transitionFinished.signal()
        }

        XCTAssertEqual(
            transitionEntered.wait(timeout: .now() + 2), .success,
            "the identity transition never entered its worker")
        XCTAssertTrue(
            CaptureAccountScope.waitUntilExposurePublicationGuardIsContendedForTests(
                timeout: 2),
            "the identity transition must wait on the reader-held serialization gate")
        releaseReader.signal()
        XCTAssertEqual(readerFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(transitionFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            ordering.events, [.readerExited, .transitionExited],
            "the identity transition must remain blocked until the guarded reader exits")
        try fixture.seedWidgetPayload(owner: newScope, title: "New account note")
        CaptureAccountScope.setAfterAccountBindingGuardHookForTests(nil)

        XCTAssertNil(transitionError.value)
        XCTAssertNotEqual(oldBinding.scope, newScope)
        XCTAssertEqual(CaptureWidgetSnapshotStore.activeOwnerForTests, newScope)
        XCTAssertEqual(
            CaptureWidgetSnapshotStore.read().lastFinishedTitle,
            "New account note")
    }
}

private final class LockedRaceOrdering: @unchecked Sendable {
    enum Event: Equatable { case readerExited, transitionExited }
    private let lock = NSLock()
    private var stored: [Event] = []
    var events: [Event] { lock.withLock { stored } }
    func record(_ event: Event) { lock.withLock { stored.append(event) } }
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
