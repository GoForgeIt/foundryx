import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Drives `features/person-pick.feature` against the REAL pick-first seams (track
/// 20260717T1700_pick_existing_person): `PersonPicker` (filter / hint / ordered /
/// showCreateNew), `SpeakerConfirmIntent.pick` (the entity bind), and the durable
/// `SpeakerConfirmQueue` (the offline binding that survives relaunch). Hermetic: no
/// network, no SwiftUI — the sheet's pick logic is exercised directly.
final class PersonPickFeatureTests: XCTestCase {

    func testPersonPickFeature() async throws {
        let world = PersonPickWorld()
        defer { world.cleanup() }
        let registry = StepRegistry(PersonPickSteps.make(world: world))
        try await BrineFeatureRunner.run("person-pick", registry: registry)
    }
}

// MARK: - world

private final class PersonPickWorld: @unchecked Sendable {
    let dir: URL
    let captureId = "cap-pick"
    let slot = "speaker_1"

    /// The directory of existing people the door would proxy.
    var people: [KnownPerson] = []
    /// The slot's REVEALED inferred name, when tentatively matched (else nil = unknown).
    var inferredName: String?
    /// The list the sheet would SHOW on open (ordered; hinted first) — the pick-list.
    var shownList: [KnownPerson] = []
    /// The voiceprint hint's entityId (annotate + sort; pre-selects nothing).
    var hintEntityId: String?

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    func seedPeople() {
        people = [
            KnownPerson(entityId: "e-nick", displayName: "Nick Rinard",
                        aliases: ["Nick", "Nicholas"], lastSeenMs: 9_000),
            KnownPerson(entityId: "e-dana", displayName: "Dana Lee", lastSeenMs: 7_500),
            KnownPerson(entityId: "e-greg", displayName: "Greg Rinard", lastSeenMs: 6_000),
        ]
    }

    func pending() -> [SpeakerConfirmQueue.Entry] { SpeakerConfirmQueue.pending(baseDir: dir) }
}

private enum PersonPickSteps {
    static func make(world w: PersonPickWorld) -> [StepDefinition] {
        [
            // ── Givens ────────────────────────────────────────────────────────
            defineStep("people I have named before") { ctx, _, _ in
                w.seedPeople()
                return ctx
            },
            defineStep("the speaker is tentatively matched to \"Nick\"") { ctx, _, _ in
                w.inferredName = "Nick"
                return ctx
            },
            defineStep("my computer cannot be reached") { ctx, _, _ in
                // Offline is modeled by NOT shipping — the local enqueue must still bind.
                return ctx
            },

            // ── Whens ─────────────────────────────────────────────────────────
            defineStep("I open the tag sheet for an unnamed speaker") { ctx, _, _ in
                w.hintEntityId = PersonPicker.hintEntityId(inferredName: w.inferredName, in: w.people)
                w.shownList = PersonPicker.ordered(persons: w.people, hintEntityId: w.hintEntityId)
                return ctx
            },
            defineStep("I open the tag sheet for that speaker") { ctx, _, _ in
                w.hintEntityId = PersonPicker.hintEntityId(inferredName: w.inferredName, in: w.people)
                w.shownList = PersonPicker.ordered(persons: w.people, hintEntityId: w.hintEntityId)
                return ctx
            },
            defineStep("I type \"nic\" to find a person") { ctx, _, _ in
                w.shownList = PersonPicker.filter("nic", in: w.people)
                return ctx
            },
            defineStep("I type \"Zoe Vega\" to find a person") { ctx, _, _ in
                w.shownList = PersonPicker.filter("Zoe Vega", in: w.people)
                w.inferredName = "Zoe Vega"   // stash the query for the create-new gate
                return ctx
            },
            defineStep("I type \"Nicholas\" to find a person") { ctx, _, _ in
                w.shownList = PersonPicker.filter("Nicholas", in: w.people)
                w.inferredName = "Nicholas"
                return ctx
            },
            defineStep("I pick the existing person \"Nick Rinard\"") { ctx, _, _ in
                guard let nick = w.people.first(where: { $0.displayName == "Nick Rinard" }) else {
                    throw BrineStepError("seed missing Nick Rinard")
                }
                let intent = SpeakerConfirmIntent.pick(person: nick)
                // Local-first: durably enqueue the pick (name + entityId), never the old id.
                SpeakerConfirmQueue.enqueue(captureId: w.captureId, slot: w.slot,
                                            name: intent.name, speakerId: intent.speakerId,
                                            entityId: intent.entityId, baseDir: w.dir)
                return ctx
            },

            // ── Thens ─────────────────────────────────────────────────────────
            defineStep("I can choose from the existing people") { ctx, _, _ in
                guard w.shownList.count == w.people.count, !w.shownList.isEmpty else {
                    throw BrineStepError("the pick-list did not offer the existing people")
                }
                return ctx
            },
            defineStep("the existing person \"Nick Rinard\" is offered") { ctx, _, _ in
                guard w.shownList.first?.displayName == "Nick Rinard" else {
                    throw BrineStepError("autocomplete did not surface Nick Rinard first: \(w.shownList.map(\.displayName))")
                }
                return ctx
            },
            defineStep("\"Nick Rinard\" is surfaced as the likely person") { ctx, _, _ in
                guard w.hintEntityId == "e-nick" else {
                    throw BrineStepError("the voiceprint hint did not resolve to Nick: \(String(describing: w.hintEntityId))")
                }
                guard w.shownList.first?.entityId == "e-nick" else {
                    throw BrineStepError("the likely person was not floated to the top")
                }
                return ctx
            },
            defineStep("no person is selected until I choose one") { ctx, _, _ in
                // Nothing durable exists yet — the hint sorts/annotates but binds nothing.
                guard w.pending().isEmpty else {
                    throw BrineStepError("a hint pre-selected a person (bound before the human chose)")
                }
                return ctx
            },
            defineStep("creating a new person is offered") { ctx, _, _ in
                guard PersonPicker.showCreateNew(query: w.inferredName ?? "", in: w.people) else {
                    throw BrineStepError("create-new was not offered when nobody matched")
                }
                return ctx
            },
            defineStep("creating a new person is not offered") { ctx, _, _ in
                guard !PersonPicker.showCreateNew(query: w.inferredName ?? "", in: w.people) else {
                    throw BrineStepError("create-new was offered though an existing person matched")
                }
                return ctx
            },
            defineStep("the saved change binds that person's existing identity") { ctx, _, _ in
                guard let entry = w.pending().first(where: { $0.slot == w.slot }) else {
                    throw BrineStepError("the pick lost its durable intent")
                }
                guard entry.entityId == "e-nick" else {
                    throw BrineStepError("the pick did not bind the existing entity: \(String(describing: entry.entityId))")
                }
                guard entry.name == "Nick Rinard" else {
                    throw BrineStepError("the pick lost the person's display name")
                }
                return ctx
            },
            defineStep("the saved change carries no stale speaker guess") { ctx, _, _ in
                guard let entry = w.pending().first(where: { $0.slot == w.slot }) else {
                    throw BrineStepError("the pick lost its durable intent")
                }
                guard entry.speakerId == nil else {
                    throw BrineStepError("the pick rode a stale speakerId (\(entry.speakerId!)) — Lore would bind the wrong record")
                }
                return ctx
            },
            defineStep("the pick is saved on my phone with the person's identity") { ctx, _, _ in
                guard w.pending().first?.entityId == "e-nick" else {
                    throw BrineStepError("the offline pick did not save with the entity binding")
                }
                return ctx
            },
            defineStep("the binding is still there after the app relaunches") { ctx, _, _ in
                // Re-read the durable queue from disk (a relaunch has no in-memory state).
                let reloaded = SpeakerConfirmQueue.pending(baseDir: w.dir)
                guard reloaded.first?.entityId == "e-nick" else {
                    throw BrineStepError("the entity binding was lost across relaunch")
                }
                return ctx
            },
        ]
    }
}
