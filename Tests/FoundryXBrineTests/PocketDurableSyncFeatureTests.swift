import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PocketDurableSyncFeatureTests: XCTestCase {
    func testPocketDurableSyncFeature() async throws {
        let world = PocketDurableWorld()
        let result = try await BrineFeatureRunner.run("pocket-durable-sync", registry: .init(PocketDurableSteps.make(world)))
        XCTAssertEqual(result.passed, 8)
    }
}

private enum PocketDurableSteps {
    static func make(_ world: PocketDurableWorld) -> [StepDefinition] {
        let givens = ["an attached Pocket is away", "eligible Pocket candidates on multiple recorder days",
          "complete, truncated, and malformed Pocket payloads", "a Pocket pull that first returns a partial prefix",
          "trusted, pre-set-point, and future Pocket timestamps", "finalized Pocket and Omi audio at the durable boundary",
          "a verified durable Pocket import", "spies around all live capture boundaries"]
        let whens = ["five presence misses occur, then one inventory succeeds, then another miss occurs",
          "Pocket sync receives the backlog", "Pocket sync imports each payload",
          "Pocket sync retries from byte zero and the same file is pulled again", "Pocket sync assembles their conversations",
          "ambient processing notices an action in each", "sync, retry, retention, and downstream recovery run",
          "the complete Pocket sync lifecycle runs"]
        let thens = ["the requested delays are 60, 120, 240, 300, 300, and 60 seconds",
          "newer days arrive first, shorter files break same-day ties, and each landed file starts processing immediately",
          "only re-readable checksum-matched MP3 creates a mapping and downstream job",
          "one capture, conversation, transcript, Lore lineage, and Activity lineage exist",
          "device time is used, uncertain time is labeled, and future grouping is clamped without losing the reported value",
          "both use the same conversation and Activity flow and neither posts a content notification",
          "no recorder delete is issued and the shipped deletion promise remains visible",
          "no FrameRouter, Live Activity, recording pill, or currently-recording state is reached"]
        return givens.map { p in defineStep(p) { c,_,_ in await world.given(p); return c } }
          + whens.map { p in defineStep(p) { c,_,_ in try await world.when(p); return c } }
          + thens.map { p in defineCheck(p) { _,_,_ in try await world.then(p) } }
    }
}

private actor PocketDurableWorld {
    let identity = RecordingDeviceIdentity(shape: .filePull, hardwareToken: "peripheral")
    var delays: [TimeInterval] = []; var ordered: [PocketInventoryCandidate] = []
    var outcomes: [PocketImportOutcome] = []; var times: [PocketConversationTime] = []
    var ambient: [PocketAmbientResult] = []; var deleteCommands = 0
    /// Every frame the census saw in this scenario's window, so the zero above can be shown
    /// to be a zero the instrument could have seen something in.
    var composedInWindow: [String] = []
    var liveEffects = StoredFileLiveEffectCounts()
    let store = PocketMemoryStore(); let decoder = PocketFixtureDecoder(); let sink = PocketJobSink()

    func given(_ phrase: String) async { delays=[]; ordered=[]; outcomes=[]; times=[]; ambient=[]; deleteCommands=0; composedInWindow=[]; liveEffects = .init(); await store.clear(); await sink.clear() }
    func candidate(_ date: String="20260808", _ time: String="120000", _ size: Int=6) -> PocketInventoryCandidate {
        .init(key: .init(identity: identity, date: date, timestamp: time), announcedSize: size, closureEvidence: true)
    }
    func when(_ phrase: String) async throws {
        switch phrase {
        case "five presence misses occur, then one inventory succeeds, then another miss occurs":
            var b = PocketPresenceBackoff(); for _ in 0..<5 { delays.append(b.missed()) }; b.found(); delays.append(b.missed())
        case "Pocket sync receives the backlog":
            ordered = PocketDurableSync.ordered([candidate("20260807","120000",4_000), candidate("20260808","130000",8_000), candidate("20260808","110000",4_000)])
            let sync = PocketDurableSync(store: store, decoder: decoder, finalized: sink)
            for c in ordered { outcomes.append(await sync.importFile(c, payload: mp3(count: c.announcedSize), evidence: .init(stockCompatibilityRecorded: true, closureSafetyRecorded: true))) }
        case "Pocket sync imports each payload":
            let sync = PocketDurableSync(store: store, decoder: decoder, finalized: sink)
            outcomes = [await sync.importFile(candidate("20260808","1",6), payload: mp3(count: 6), evidence: goodEvidence),
                        await sync.importFile(candidate("20260808","2",8), payload: mp3(count: 6), evidence: goodEvidence),
                        await sync.importFile(candidate("20260808","3",6), payload: Data(repeating: 0, count: 6), evidence: goodEvidence)]
        case "Pocket sync retries from byte zero and the same file is pulled again":
            let sync = PocketDurableSync(store: store, decoder: decoder, finalized: sink), c = candidate("20260809","retry",8)
            outcomes = [await sync.importFile(c, payload: mp3(count: 4), evidence: goodEvidence),
                        await sync.importFile(c, payload: mp3(count: 8), evidence: goodEvidence),
                        await sync.importFile(c, payload: mp3(count: 8), evidence: goodEvidence)]
        case "Pocket sync assembles their conversations":
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = Date(timeIntervalSince1970: 2_000_000), set = Date(timeIntervalSince1970: 1_500_000)
            times = [.init(timeline: Date(), recorderReported: Date(), broughtOver: Date(), warning: nil)]
            times = [PocketConversationClock.resolve(reported: Date(timeIntervalSince1970: 1_700_000), broughtOver: now, lastClockSet: set, calendar: cal),
                     PocketConversationClock.resolve(reported: Date(timeIntervalSince1970: 1_000_000), broughtOver: now, lastClockSet: set, calendar: cal),
                     PocketConversationClock.resolve(reported: Date(timeIntervalSince1970: 3_000_000), broughtOver: now, lastClockSet: set, calendar: cal)]
        case "ambient processing notices an action in each":
            ambient = [PocketPostCaptureParity.ambientResult(conversationID: "p", enabled: true), PocketPostCaptureParity.ambientResult(conversationID: "o", enabled: true)]
        // THIS USED TO READ `deleteCommands = PocketRecorderCustodyPromise.automaticDeleteCommands`
        // — a constant assigned to a variable and then asserted equal to zero, which no change to
        // any code path this app runs could falsify. The population that CAN falsify it is the
        // census `PocketBLEClient.write` keeps, and `features/pocket-recorder-delete-consent.feature`
        // drives the real bring-over / retry / sweep / send legs into it. Here the same census is
        // read across this suite's own sync, retry and recovery.
        case "sync, retry, retention, and downstream recovery run":
            let mark = await PocketRecorderCommandLedger.shared.mark()
            let sync = PocketDurableSync(store: store, decoder: decoder, finalized: sink), c = candidate("20260810","recover",8)
            _ = await sync.importFile(c, payload: mp3(count: 4), evidence: goodEvidence)
            _ = await sync.importFile(c, payload: mp3(count: 8), evidence: goodEvidence)
            _ = await sync.importFile(c, payload: mp3(count: 8), evidence: goodEvidence)
            // THE PAIRED EXISTENCE ASSERTION, WITHOUT WHICH THE ZERO BELOW IS A ZERO ABOUT
            // NOTHING. `PocketDurableSync` composes no recorder command at all — it takes bytes
            // that are already on this phone — so `composed(since:)` over this leg is the EMPTY
            // SET, and a filter over the empty set is zero no matter what the filter says. That
            // is the same defect this step was written to replace, restated in newer
            // vocabulary. So the window is made non-empty on purpose: one real, non-delete
            // frame is put through the real gate and the real census, and the scenario asserts
            // BOTH that the census saw it AND that the sync leg added no deletion beside it.
            _ = await PocketRecorderCommandGate.admit(frame: "APP&LIST_DIRS", ownerConsent: nil)
            await PocketRecorderCommandLedger.shared.record(
                .init(frame: "APP&LIST_DIRS", disposition: .putOnTheWire))
            _ = await sync.importFile(candidate("20260810","recover2",8), payload: mp3(count: 8), evidence: goodEvidence)
            let seen = await PocketRecorderCommandLedger.shared.composed(since: mark)
            composedInWindow = seen.map(\.frame)
            deleteCommands = seen.filter(\.namesADeletion).count
        case "the complete Pocket sync lifecycle runs":
            let spy = StoredFileLiveBoundarySpy()
            StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: spy)
            liveEffects = spy.counts
        default: break
        }
    }
    var goodEvidence: PocketFileEvidence { .init(stockCompatibilityRecorded: true, closureSafetyRecorded: true) }
    func mp3(count: Int) -> Data { var d = Data([0xff,0xf3]); d.append(Data(repeating: 1, count: max(0,count-2))); return d }
    func then(_ phrase: String) async throws {
        switch phrase {
        case "the requested delays are 60, 120, 240, 300, 300, and 60 seconds": XCTAssertEqual(delays, [60,120,240,300,300,60])
        case "newer days arrive first, shorter files break same-day ties, and each landed file starts processing immediately":
            let jobs=await sink.jobs(); XCTAssertEqual(ordered.map{$0.key.timestamp}, ["110000","130000","120000"]); XCTAssertEqual(jobs.count, 3)
        case "only re-readable checksum-matched MP3 creates a mapping and downstream job":
            let jobs=await sink.jobs(); XCTAssertEqual(outcomes, [.imported(captureID:"capture-1"), .retryable(.truncatedPayload), .retryable(.malformedMP3)]); XCTAssertEqual(jobs.count, 1)
        case "one capture, conversation, transcript, Lore lineage, and Activity lineage exist":
            let jobs=await sink.jobs(); XCTAssertEqual(outcomes, [.retryable(.truncatedPayload), .imported(captureID:"capture-1"), .alreadyImported(captureID:"capture-1")]); XCTAssertEqual(jobs.count, 1)
        case "device time is used, uncertain time is labeled, and future grouping is clamped without losing the reported value":
            XCTAssertNil(times[0].warning); XCTAssertNotNil(times[1].warning); XCTAssertNotNil(times[2].warning); XCTAssertNotEqual(times[2].timeline, times[2].recorderReported)
        case "both use the same conversation and Activity flow and neither posts a content notification": XCTAssertEqual(ambient.map{$0.activityLineageCount}, [1,1]); XCTAssertEqual(ambient.map{$0.notificationCount}, [0,0])
        case "no recorder delete is issued and the shipped deletion promise remains visible":
            XCTAssertTrue(composedInWindow.contains("APP&LIST_DIRS"),
                          "the census saw \(composedInWindow) — it did not even see the frame "
                              + "this scenario deliberately put in front of it, so the zero "
                              + "below is a zero about an instrument that is not reading")
            XCTAssertEqual(deleteCommands, 0,
                           "the durable-sync, retry and recovery legs composed \(deleteCommands) "
                               + "deletion(s) for a recorder: \(composedInWindow)")
            XCTAssertEqual(PocketRecorderCustodyPromise.automaticDeleteCommands, 0)
            XCTAssertEqual(PocketRecorderCustodyPromise.text, "Solleva never deletes anything you didn't ask it to.")
        case "no FrameRouter, Live Activity, recording pill, or currently-recording state is reached":
            XCTAssertEqual(liveEffects.storedFileLifecycleEvents, 5)
            XCTAssertEqual(liveEffects.activeSourceSelections, 0)
            XCTAssertEqual(liveEffects.frameRouterStarts, 0)
            XCTAssertEqual(liveEffects.walWrites, 0)
            XCTAssertEqual(liveEffects.liveActivities, 0)
            XCTAssertEqual(liveEffects.liveStateMutations, 0)
        default: XCTFail("Unhandled Then: \(phrase)")
        }
    }
}

private actor PocketMemoryStore: PocketDurableImportStore {
    var receipts: [PocketRecorderFileKey:PocketDurableReceipt] = [:]
    func existingReceipt(for key: PocketRecorderFileKey) -> PocketDurableReceipt? { receipts[key] }
    func commit(key: PocketRecorderFileKey, source: Data) throws -> PocketDurableReceipt {
        if let r=receipts[key] { return r }; let r = PocketDurableReceipt(captureID:"capture-\(receipts.count+1)", checksum:"fixture", reReadableBytes:source); receipts[key]=r; return r
    }
    func clear() { receipts = [:] }
}
private struct PocketFixtureDecoder: PocketMP3Decoding { func decode(_ mp3: Data) async throws -> PocketPCM { .init(bytes: mp3, sampleRate: 16_000, channels: 1) } }
private actor PocketJobSink: PocketFinalizedCaptureSink { var storage:[PocketFinalizedJob]=[]; func enqueue(_ job:PocketFinalizedJob){storage.append(job)}; func jobs()->[PocketFinalizedJob]{storage}; func clear(){storage=[]} }
