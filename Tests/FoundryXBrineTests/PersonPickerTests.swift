import XCTest
@testable import FoundryXKit

/// Unit coverage for the "pick an existing person" logic (track 20260717T1700):
///  • PersonPicker.filter — autocomplete over display name + aliases, ranked.
///  • PersonPicker.hintEntityId / .ordered — the voiceprint HINT (annotate + sort, NEVER
///    pre-select), preserving human authority.
///  • PersonPicker.exactMatch / .showCreateNew — the create-new fallback gate (pick-first).
///  • KnownPerson decode — the door reply shape (snake_case, bare array OR envelope).
///  • The entity-id bind — the confirm intent, the durable queue, and the door body — so a
///    pick attaches an EXISTING person instead of minting a duplicate.
final class PersonPickerTests: XCTestCase {

    private func people() -> [KnownPerson] {
        [
            KnownPerson(entityId: "e-nick", displayName: "Nick Rinard",
                        aliases: ["Nick", "Nicholas"], lastSeenMs: 5_000),
            KnownPerson(entityId: "e-greg", displayName: "Greg Rinard",
                        aliases: [], lastSeenMs: 3_000),
            KnownPerson(entityId: "e-dana", displayName: "Dana Lee",
                        aliases: [], lastSeenMs: 9_000),
            KnownPerson(entityId: "e-nad", displayName: "Nadège Blanc",
                        aliases: [], lastSeenMs: 1_000),
        ]
    }

    // MARK: filter / autocomplete

    func testBlankQueryReturnsAllMostRecentFirst() {
        let out = PersonPicker.filter("", in: people())
        XCTAssertEqual(out.map(\.entityId), ["e-dana", "e-nick", "e-greg", "e-nad"],
                       "blank query = the whole directory, most-recently-heard first")
    }

    func testPrefixQueryAutocompletesToTheExistingPerson() {
        // "nic" should surface Nick Rinard (via the "Nick"/"Nicholas" alias prefix) — the
        // "Do you mean Nick Rinard?" bind, so the user never retypes a dupe.
        let out = PersonPicker.filter("nic", in: people())
        XCTAssertEqual(out.first?.entityId, "e-nick")
    }

    func testSurnameMatchesBothRinards() {
        let out = PersonPicker.filter("rinard", in: people())
        XCTAssertEqual(Set(out.map(\.entityId)), ["e-nick", "e-greg"],
                       "a shared surname surfaces both people to disambiguate")
    }

    func testExactBeatsPrefixBeatsSubstringInRanking() {
        let ppl = [
            KnownPerson(entityId: "e-sub", displayName: "Jonic Adams", lastSeenMs: 100),   // substring "nic"
            KnownPerson(entityId: "e-exact", displayName: "Nic", lastSeenMs: 1),            // exact "nic"
            KnownPerson(entityId: "e-prefix", displayName: "Nicole", lastSeenMs: 1),        // prefix "nic"
        ]
        let out = PersonPicker.filter("nic", in: ppl)
        XCTAssertEqual(out.map(\.entityId), ["e-exact", "e-prefix", "e-sub"],
                       "exact > leading-prefix > loose substring, regardless of recency")
    }

    func testDiacriticInsensitiveMatch() {
        XCTAssertEqual(PersonPicker.filter("nadege", in: people()).first?.entityId, "e-nad")
        XCTAssertEqual(PersonPicker.filter("NADÈGE", in: people()).first?.entityId, "e-nad")
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(PersonPicker.filter("zoe", in: people()).isEmpty)
    }

    // MARK: voiceprint hint (annotate + sort, NEVER pre-select)

    func testHintResolvesInferredNameToTheLikelyPerson() {
        XCTAssertEqual(PersonPicker.hintEntityId(inferredName: "Nick", in: people()), "e-nick")
    }

    func testHintIsNilForWeakOrUnknownSlot() {
        // A weak/unknown slot reveals no inferred name (nil/blank) → NO hint (no nudge).
        XCTAssertNil(PersonPicker.hintEntityId(inferredName: nil, in: people()))
        XCTAssertNil(PersonPicker.hintEntityId(inferredName: "   ", in: people()))
    }

    func testHintNeverInventsAMatch() {
        XCTAssertNil(PersonPicker.hintEntityId(inferredName: "Zoe", in: people()),
                     "a name with no directory match yields no hint (honest, never invented)")
    }

    func testOrderedFloatsTheHintedPersonFirstButSelectsNothing() {
        // The hinted person is sorted to the TOP; the return is only an ORDER — no row is
        // marked chosen. (The sheet renders nothing selected until a human taps.)
        let out = PersonPicker.ordered(persons: people(), hintEntityId: "e-nick")
        XCTAssertEqual(out.first?.entityId, "e-nick", "the likely person is easiest to reach")
        XCTAssertEqual(Set(out.map(\.entityId)), Set(people().map(\.entityId)),
                       "ordering drops no one and adds no one")
    }

    func testOrderedWithoutHintIsPlainRecencyOrder() {
        let out = PersonPicker.ordered(persons: people(), hintEntityId: nil)
        XCTAssertEqual(out.map(\.entityId), ["e-dana", "e-nick", "e-greg", "e-nad"])
    }

    // MARK: create-new gate (pick-first: the exception, only when nothing matches)

    func testCreateNewHiddenWhenAnExistingPersonMatchesExactly() {
        XCTAssertFalse(PersonPicker.showCreateNew(query: "Nicholas", in: people()),
                       "an exact alias match must bind the existing person, not mint a dupe")
        XCTAssertFalse(PersonPicker.showCreateNew(query: "nick rinard", in: people()))
    }

    func testCreateNewShownOnlyWhenNothingMatches() {
        XCTAssertTrue(PersonPicker.showCreateNew(query: "Zoe Vega", in: people()))
        XCTAssertFalse(PersonPicker.showCreateNew(query: "   ", in: people()),
                       "a blank query offers nothing")
    }

    func testExactMatchIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(PersonPicker.exactMatch("nadege blanc", in: people())?.entityId, "e-nad")
        // An alias ("Nick") counts as an exact existing match — binds, never mints.
        XCTAssertEqual(PersonPicker.exactMatch("nick", in: people())?.entityId, "e-nick")
    }

    // MARK: KnownPerson decode (the door reply)

    func testDecodesBareArraySnakeCase() {
        let json = """
        [{"entity_id":"e1","display_name":"Nick Rinard","aliases":["Nick"],"last_seen":42}]
        """.data(using: .utf8)!
        let out = DoorClient.decodePersons(json)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.entityId, "e1")
        XCTAssertEqual(out.first?.displayName, "Nick Rinard")
        XCTAssertEqual(out.first?.aliases, ["Nick"])
        XCTAssertEqual(out.first?.lastSeenMs, 42)
    }

    func testDecodesEnvelopeAndToleratesMissingOptionals() {
        let json = """
        {"persons":[{"entity_id":"e2","display_name":"Dana Lee"}]}
        """.data(using: .utf8)!
        let out = DoorClient.decodePersons(json)
        XCTAssertEqual(out.first?.entityId, "e2")
        XCTAssertEqual(out.first?.aliases, [], "missing aliases → empty, never fatal")
        XCTAssertNil(out.first?.lastSeenMs)
    }

    func testDecodeToleratesEntirelyUnknownShape() {
        XCTAssertTrue(DoorClient.decodePersons(Data("{\"unexpected\":true}".utf8)).isEmpty)
    }

    // MARK: the entity-id bind (dedup at entry)

    func testPickIntentBindsEntityIdAndShipsTheNameNeverTheOldSpeakerId() {
        let person = KnownPerson(entityId: "e-nick", displayName: "Nick Rinard", aliases: ["Nick"])
        let intent = SpeakerConfirmIntent.pick(person: person)
        XCTAssertEqual(intent.entityId, "e-nick", "a pick binds the durable person key")
        XCTAssertEqual(intent.name, "Nick Rinard", "the display name rides for the label")
        XCTAssertNil(intent.speakerId, "a pick must never ride the slot's stale speakerId")
    }

    func testConfirmBodyCarriesEntityId() {
        let body = DoorClient.confirmBody(speakerId: nil, name: "Nick Rinard", entityId: "e-nick")
        XCTAssertEqual(body["entityId"], "e-nick")
        XCTAssertEqual(body["name"], "Nick Rinard")
        XCTAssertNil(body["speakerId"])
    }

    func testConfirmBodyOmitsEmptyFields() {
        let body = DoorClient.confirmBody(speakerId: "", name: "", entityId: "")
        XCTAssertTrue(body.isEmpty, "empty values are omitted — a bare confirm sends nothing")
    }

    func testQueueEntryPersistsEntityIdAcrossReload() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1",
                                    name: "Nick Rinard", entityId: "e-nick", baseDir: dir)
        // Re-read from disk — an OFFLINE pick's entity binding must survive to the drain.
        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.entityId, "e-nick")
        XCTAssertEqual(pending.first?.name, "Nick Rinard")
    }

    func testLegacyQueueEntryWithoutEntityIdStillDecodes() {
        // A jsonl line written before this field must decode (entityId → nil), never crash
        // the drain.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = #"{"captureId":"cap-1","slot":"speaker_1","name":"Old","speakerId":null,"ts":7}"#
        try! (legacy + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("speaker-confirms.jsonl"))
        let pending = SpeakerConfirmQueue.pending(baseDir: dir)
        XCTAssertEqual(pending.first?.name, "Old")
        XCTAssertNil(pending.first?.entityId)
    }

    // MARK: the OFFLINE drain re-ship (the highest-risk path — must not drop the bind)

    /// A private actor so the `@Sendable` drain ship can hand the body it WOULD send back to
    /// the test.
    private actor BodyBox {
        private(set) var value: [String: String]?
        func set(_ v: [String: String]) { value = v }
    }

    func testOfflineDrainReShipCarriesTheEntityBind() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // An OFFLINE pick: durably enqueue name + entityId (no speakerId), as the sheet does.
        SpeakerConfirmQueue.enqueue(captureId: "cap-1", slot: "speaker_1",
                                    name: "Nick Rinard", entityId: "e-nick", baseDir: dir)

        // Drive the SHARED drain with a ship that builds the door body via the SAME
        // `confirmBody` the production drain (CaptureManager.retryPendingSpeakerConfirms)
        // uses — so a regression dropping `entityId: e.entityId` at that call site fails here.
        let seen = BodyBox()
        await SpeakerConfirmFlow.drainPending(
            baseDir: dir,
            ship: { e in
                await seen.set(DoorClient.confirmBody(speakerId: e.speakerId, name: e.name,
                                                      entityId: e.entityId))
                return ConfirmOutcome(captureId: e.captureId, slotLabel: e.slot,
                                      status: "confirmed", speakerId: "sp-real",
                                      speakerName: e.name ?? "", offeredCaptures: [])
            },
            onAuthExpired: { })

        let body = await seen.value
        XCTAssertEqual(body?["entityId"], "e-nick", "the offline re-ship must carry the entity bind")
        XCTAssertNil(body?["speakerId"], "the re-ship must not resurrect a stale speakerId")
        XCTAssertEqual(body?["name"], "Nick Rinard")
        XCTAssertTrue(SpeakerConfirmQueue.pending(baseDir: dir).isEmpty,
                      "a successful ACK drains the entry")
    }

    // MARK: normalize hardening + decode drops unusable rows

    func testNormalizeCollapsesInternalWhitespaceSoATypoStillBinds() {
        // "Nick  Rinard" (double space) must still resolve to the existing person — else the
        // create-new gate would mint a duplicate of an entity that already exists.
        XCTAssertEqual(PersonPicker.exactMatch("Nick  Rinard", in: people())?.entityId, "e-nick")
        XCTAssertFalse(PersonPicker.showCreateNew(query: "Nick   Rinard", in: people()),
                       "a whitespace typo of an existing name must not offer create-new")
        XCTAssertEqual(PersonPicker.filter("nick   rinard", in: people()).first?.entityId, "e-nick")
    }

    func testDecodeDropsRowsMissingEntityIdOrName() {
        let json = """
        [{"entity_id":"e1","display_name":"Nick Rinard"},
         {"display_name":"No Id"},
         {"entity_id":"e3","display_name":""}]
        """.data(using: .utf8)!
        let out = DoorClient.decodePersons(json)
        XCTAssertEqual(out.map(\.entityId), ["e1"],
                       "an un-bindable row (no entity_id) or a nameless row is dropped, never surfaced")
    }
}
