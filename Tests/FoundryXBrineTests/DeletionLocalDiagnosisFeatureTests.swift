import XCTest
@testable import FoundryXKit
import BrineSwiftCore

/// Seams for `deletion-local-diagnosis.feature`.
///
/// Drives the REAL `CurrentOwnerSelectiveDeletionRunner` against the REAL
/// `SelectiveDeletionIntegrationFixture` (a genuine on-disk container, defaults,
/// secret store and exposure coordinator) — the same harness the lifecycle unit
/// tests use. Nothing about the gate is stubbed; only the identity handed in
/// varies, which is exactly the axis the gate judges.
///
/// Each scenario asserts the COMMAND's two observable effects: the record it
/// emitted, and the data it did NOT destroy. Checking only the record would let a
/// refusal that quietly erased something pass.
final class DeletionLocalDiagnosisFeatureTests: XCTestCase {

    @MainActor final class World {
        var fixture: SelectiveDeletionIntegrationFixture?
        var containerOpened = false
        var otherAccountIntact = false
        var threw = false

        func reset() {
            fixture?.cleanup()
            fixture = nil
            containerOpened = false
            otherAccountIntact = false
            threw = false
            DeletionRecorder.shared.clear()
        }
    }

    func testDeletionLocalDiagnosisScenarios() async throws {
        let w = await World()
        defer { Task { @MainActor in w.reset() } }

        try await BrineFeatureRunner.run("deletion-local-diagnosis", registry: StepRegistry([

            defineStep("an erase is attempted for an identity that does not own the data") { ctx, _, _ in
                await MainActor.run { w.reset() }
                let fixture = try SelectiveDeletionIntegrationFixture(legacyProof: .ownedByB)
                await MainActor.run { w.fixture = fixture }
                // identityA does NOT own the B-scoped data in the fixture.
                let runner = CurrentOwnerSelectiveDeletionRunner(
                    container: fixture.root,
                    defaults: fixture.defaults,
                    secretStore: fixture.secrets,
                    pairingServices: (cell: fixture.cellService, door: fixture.doorService),
                    exposureCoordinator: fixture.exposureCoordinator,
                    identityProvider: { fixture.identityA })
                do {
                    try await runner.eraseVerifiedCurrentOwner()
                } catch {
                    await MainActor.run { w.threw = true }
                }
                let intact = fixture.allScopedBInputsRemainPresent
                await MainActor.run { w.otherAccountIntact = intact }
                return ctx
            },

            defineStep("an erase is attempted with no proven identity") { ctx, _, _ in
                await MainActor.run { w.reset() }
                let opened = DeletionCompletionFlag()
                let runner = CurrentOwnerSelectiveDeletionRunner(
                    containerProvider: {
                        opened.markFinished()
                        return FileManager.default.temporaryDirectory
                    },
                    defaults: .standard,
                    secretStore: DeletionTypedSecretStore(),
                    pairingServices: (cell: "cell.test", door: "door.test"),
                    exposureCoordinator: AccountExposureCoordinator(),
                    identityProvider: { nil })
                do {
                    try await runner.eraseVerifiedCurrentOwner()
                } catch {
                    await MainActor.run { w.threw = true }
                }
                let touched = opened.isFinished
                await MainActor.run { w.containerOpened = touched }
                return ctx
            },

            defineCheck("the refusal is recorded with its cause") { _, _, _ in
                let lines = DeletionRecorder.shared.recorded()
                guard await MainActor.run(body: { w.threw }) else {
                    throw BrineStepError("the gate did not refuse at all")
                }
                guard lines.contains(where: { $0.contains("account.delete.local") }) else {
                    throw BrineStepError(
                        "the refusal left no record — the person is told 'deletion is "
                        + "pending' and nobody can tell which refusal it was: \(lines)")
                }
                // A bare "blocked" is what we already had and could not act on.
                guard lines.contains(where: {
                    $0.contains("owner_unproven") || $0.contains("failed")
                        || $0.contains("store_blocked")
                }) else {
                    throw BrineStepError("recorded that it refused, but not WHY: \(lines)")
                }
            },

            defineCheck("nothing belonging to the other account was erased") { _, _, _ in
                guard await MainActor.run(body: { w.otherAccountIntact }) else {
                    throw BrineStepError(
                        "a refused erase destroyed the other account's data anyway")
                }
            },

            defineCheck("the data container was never opened") { _, _, _ in
                guard await MainActor.run(body: { !w.containerOpened }) else {
                    throw BrineStepError(
                        "the gate opened the container BEFORE proving the identity")
                }
            },

            defineCheck("the record is held somewhere the erase cannot remove") { _, _, _ in
                // The recorder ships to the relay diag sink and keeps an in-memory
                // copy. Neither lives in the account container, so the record
                // outlives the data it describes — a record written into the store
                // being erased would vanish with the thing it documents.
                let before = DeletionRecorder.shared.recorded().count
                guard before > 0 else {
                    throw BrineStepError("no record to survive anything")
                }
                if let root = await MainActor.run(body: { w.fixture?.root }) {
                    let inContainer = FileManager.default
                        .enumerator(at: root, includingPropertiesForKeys: nil)?
                        .allObjects
                        .compactMap { ($0 as? URL)?.lastPathComponent }
                        .contains { $0.contains("deletion-record") } ?? false
                    guard !inContainer else {
                        throw BrineStepError(
                            "the deletion record is stored INSIDE the container the "
                            + "deletion erases — it would vanish with its subject")
                    }
                }
            },
        ]))
    }
}
