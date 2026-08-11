import XCTest
@testable import FoundryXKit

final class AccountSurfaceCompletenessTests: XCTestCase {
    func testRegistryHasExactlyOneConformerForEveryManifestCase() throws {
        XCTAssertEqual(
            Set(AccountSurfaceID.allCases),
            Set(AccountSurfaceRegistry.surfaceIDs))
        XCTAssertEqual(
            AccountSurfaceRegistry.surfaceIDs.count,
            Set(AccountSurfaceRegistry.surfaceIDs).count,
            "a surface is registered more than once")

        let token = UUID().uuidString.lowercased()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "foundryx-surface-completeness-\(token)", isDirectory: true)
        let name = "foundryx.surface-completeness.\(token)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CaptureWidgetSnapshotStore.setDefaultsForTesting(defaults)
        AuthStore.setIdentityEraseForTests { .alreadyClean }
        AccountLiveActivityBoundary.endAllForTests = { .alreadyClean }
        defer {
            AccountLiveActivityBoundary.endAllForTests = nil
            AuthStore.setIdentityEraseForTests(nil)
            CaptureWidgetSnapshotStore.resetDefaultsForTesting()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let binding = CaptureAccountScope.AccountBinding(
            root: root.appendingPathComponent("acct-0000000000000001"),
            scope: "acct-0000000000000001",
            generation: 1)
        let operationOutcomes = [
            AccountSurfaceRegistry.attachAll(binding),
            AccountSurfaceRegistry.detachAll(previous: binding),
            AccountSurfaceRegistry.eraseAll(binding, defaults: defaults),
            // Verification walks the SAME manifest. A surface that answers
            // "already erased" without being covered here is a surface the
            // deletion would call finished without ever checking.
            AccountSurfaceRegistry.verifyAll(binding, defaults: defaults),
        ]
        for outcomes in operationOutcomes {
            XCTAssertEqual(Set(outcomes.keys), Set(AccountSurfaceID.allCases))
            for (surface, outcome) in outcomes {
                if case .retainedByDesign(let reason) = outcome {
                    XCTAssertFalse(
                        reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(surface.rawValue) retained state without a reason")
                }
            }
        }
    }

    func testEveryFoundryPersistenceLiteralIsClassified() throws {
        let root = try repositoryRoot()
        let roots = ["Sources", "App", "Widget"]
        var swiftFiles: [URL] = []
        for relative in roots {
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            let files = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            swiftFiles.append(contentsOf: files)
        }
        XCTAssertGreaterThan(swiftFiles.count, 150, "source scan found too few Swift files")

        let foundryPattern = try NSRegularExpression(
            pattern: #"\"(foundryx\.[a-zA-Z0-9._-]+)\""#)
        let servicePattern = try NSRegularExpression(
            pattern: #"\"(com\.goforgeit\.foundryx\.(?:auth|cell|door))\""#)
        var foundryKeys = Set<String>()
        var services = Set<String>()
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            foundryKeys.formUnion(matches(foundryPattern, in: text))
            services.formUnion(matches(servicePattern, in: text))
        }
        XCTAssertGreaterThan(foundryKeys.count, 45, "source scan found too few foundryx.* literals")
        XCTAssertEqual(services.count, 3, "keychain service scan did not find all three services")

        let unknownKeys = foundryKeys.subtracting(Self.keyClassifications.keys)
        let staleKeys = Set(Self.keyClassifications.keys).subtracting(foundryKeys)
        XCTAssertTrue(unknownKeys.isEmpty, "unclassified foundryx.* keys: \(unknownKeys.sorted())")
        XCTAssertTrue(staleKeys.isEmpty, "classified keys no longer found: \(staleKeys.sorted())")
        let unknownServices = services.subtracting(Self.serviceClassifications.keys)
        XCTAssertTrue(unknownServices.isEmpty, "unclassified keychain services: \(unknownServices.sorted())")
        for (key, classification) in Self.keyClassifications {
            if case .nonIdentity(let reason) = classification {
                XCTAssertFalse(reason.isEmpty, "\(key) has no non-identity reason")
            }
        }
    }

    private func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Sources").path) else {
            throw BrineStepError("repository root could not be located from #filePath")
        }
        return root
    }

    private func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}

private extension AccountSurfaceCompletenessTests {
    enum Classification {
        case surface(AccountSurfaceID)
        case nonIdentity(String)
    }

    static let keyClassifications: [String: Classification] = [
        "foundryx.account.signup-posted": .surface(.legacySignupMarker),
        "foundryx.action-button.choice": .surface(.actionButtonChoice),
        "foundryx.ambient.agentName": .surface(.accountPreferences),
        "foundryx.ambient.enabled": .surface(.accountPreferences),
        "foundryx.ambient.grading": .surface(.accountPreferences),
        "foundryx.ambient.othersInline": .surface(.accountPreferences),
        "foundryx.auth.signed-in": .surface(.signedInMirror),
        "foundryx.battery.monitored.name": .surface(.batteryMonitoredDevice),
        "foundryx.battery.monitored.uuid": .surface(.batteryMonitoredDevice),
        "foundryx.brain.choice": .surface(.accountPreferences),
        "foundryx.capture-account-activation.v2": .surface(.activationRecord),
        "foundryx.capture-account-scope": .surface(.activationRecord),
        "foundryx.capture.omi-desired-state": .surface(.accountPreferences),
        "foundryx.capture.silence-gap-seconds": .surface(.accountPreferences),
        "foundryx.capture.source": .surface(.captureSourceChoice),
        "foundryx.capture.sources.added": .surface(.userAddedCaptureSources),
        "foundryx.capture.sources.enabled-overrides": .surface(.accountPreferences),
        "foundryx.capture.widget-snapshot": .surface(.widgetSnapshotPayload),
        "foundryx.capture.widget-snapshot.active-owner": .surface(.widgetActiveOwner),
        "foundryx.cell.authMode": .surface(.cellBinding),
        "foundryx.cell.url": .surface(.cellBinding),
        "foundryx.door.url": .surface(.doorBinding),
        "foundryx.models.cache.v1": .surface(.accountPreferences),
        "foundryx.omi.central": .surface(.bleCentralRestoration),
        "foundryx.omi.last-connected": .surface(.omiPairing),
        "foundryx.omi.peripheral-id": .surface(.omiPairing),
        "foundryx.omi.peripheral-name": .surface(.omiPairing),
        "foundryx.onboarding.completed": .surface(.accountPreferences),
        "foundryx.onboarding.persona": .surface(.accountPreferences),
        "foundryx.vault.checkoutAttempt.id": .surface(.accountPreferences),
        "foundryx.vault.checkoutAttempt.plan": .surface(.accountPreferences),
        "foundryx.waitlist.joined": .surface(.accountPreferences),
        "foundryx.welcome.letStraightIn": .surface(.accountPreferences),
        "foundryx.welcome.seen": .surface(.accountPreferences),

        "foundryx.battery-ble": .nonIdentity("Dispatch queue label for the battery BLE worker"),
        "foundryx.capture": .nonIdentity("ActivityKit attribute kind, not persisted identity"),
        "foundryx.capture-account-identity-did-change": .nonIdentity("process notification name"),
        "foundryx.capture-account-migration": .nonIdentity("Dispatch queue label"),
        "foundryx.capture-account-persistence": .nonIdentity("Dispatch queue label"),
        "foundryx.capture-account.preference-mutation-depth": .nonIdentity("thread-local recursion marker"),
        "foundryx.capture-wal": .nonIdentity("Dispatch queue label"),
        "foundryx.device-ble": .nonIdentity("Dispatch queue label for the device BLE worker"),
        "foundryx.device-ref.v1": .nonIdentity("hash domain separator, not persisted state"),
        "foundryx.diag.perfOverlay": .nonIdentity("device diagnostic preference with no account content"),
        "foundryx.install.marker.v1": .nonIdentity(
            "a boolean naming no account: it records only that this install's container has been seen before, so a reinstall (which clears the container but NOT the keychain) can be told apart from an ordinary launch"),
        "foundryx.mic-source": .nonIdentity("Dispatch queue label"),
        "foundryx.omi-ble": .nonIdentity("Dispatch queue label for the Omi source"),
        "foundryx.omi-restoration-owner": .nonIdentity("Dispatch queue label"),
        "foundryx.recording-device-attach":
            .nonIdentity("Dispatch queue label for the connect-probe BLE worker"),
        "foundryx.omi-restoration-spool": .nonIdentity("Dispatch queue label"),
        "foundryx.replay-source": .nonIdentity("test/replay Dispatch queue label"),
        "foundryx.speaker-confirm-queue": .nonIdentity("Dispatch queue label"),
        "foundryx.stall-watchdog": .nonIdentity("diagnostic Dispatch queue label"),
        "foundryx.stress-churn": .nonIdentity("performance harness Dispatch queue label"),
        "foundryx.synthetic-mic": .nonIdentity("performance harness Dispatch queue label"),
    ]

    static let serviceClassifications: [String: AccountSurfaceID] = [
        "com.goforgeit.foundryx.auth": .keychainIdentity,
        "com.goforgeit.foundryx.cell": .cellBearerSecret,
        "com.goforgeit.foundryx.door": .doorBearerSecret,
    ]
}
