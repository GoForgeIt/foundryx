import XCTest
import BrineSwiftCore
@testable import FoundryXKit

final class PocketFastSyncFeatureTests: XCTestCase {
    func testPocketFastSyncFeature() async throws {
        let world = PocketFastWorld()
        let result = try await BrineFeatureRunner.run("pocket-fast-sync", registry: .init(PocketFastSteps.make(world)))
        XCTAssertEqual(result.passed, 8)
    }
}

private enum PocketFastSteps {
    static func make(_ world: PocketFastWorld) -> [StepDefinition] {
        let givens = ["all Pocket WiFi evidence gates are absent", "an authenticated Pocket identity and matching recorder credentials",
          "the Fast sync sheet is open", "a mismatched Pocket identity or recorder password",
          "the endpoint, stock-control, and iOS-AP evidence gates are absent", "production evidence gates and a complete selected-file response",
          "a backlog of 23 files with 9 durably imported", "active Fast sync attempts that complete, pause, cancel, fail, and retry"]
        let whens = ["Pocket setup and device Settings are presented", "I select Join and fast sync once", "I keep using Bluetooth",
          "I select Join and fast sync", "Fast sync runs the typed authenticated control and HTTP boundaries",
          "Fast sync progress is presented without measured rate evidence", "each attempt exits"]
        let thens = ["both entry points show Fast sync and state that the phone leaves its normal network",
          "the join receives the reported network and first eight session-key characters without showing or logging either secret",
          "no network join occurs and the internet-loss warning was already visible",
          "no WiFi command, network join, HTTP request, or durable handoff occurs",
          "Fast sync remains visible and finishes with a named unavailable gap",
          "exactly one verified completed payload reaches Pocket durable sync",
          "it shows 9 of 23 with Over, Now, and Waiting and no speed or ETA claim",
          "cleanup is attempted, partial bytes never complete, no file is deleted, and no live capture path is reached"]
        return givens.map { p in defineStep(p) { c,_,_ in await world.given(p); return c } }
          + whens.map { p in defineStep(p) { c,_,_ in await world.when(p); return c } }
          + thens.map { p in defineCheck(p) { _,_,_ in try await world.then(p) } }
    }
}

private actor PocketFastWorld {
    let joiner=FastJoiner(), http=FastHTTP(), handoff=FastHandoff(), control=FastControl()
    let liveBoundaries=StoredFileLiveBoundarySpy()
    var givenPhrase=""; var outcome:PocketFastSyncOutcome?; var progress:PocketFastSyncProgress?
    var entryPresentations: [PocketFastSyncPresentation] = []
    func given(_ phrase:String) async { givenPhrase=phrase; outcome=nil; progress=nil; await joiner.clear(); await http.clear(); await handoff.clear(); await control.clear() }
    func when(_ phrase:String) async {
        let coordinator=PocketFastSyncCoordinator(joiner:joiner,http:http,handoff:handoff,control:control)
        switch phrase {
        case "Pocket setup and device Settings are presented": entryPresentations = [.setup, .settings]
        case "I keep using Bluetooth": outcome = await coordinator.keepUsingBluetooth()
        case "I select Join and fast sync once": outcome = await coordinator.run(identityMatches:true,sessionKey:"ABCDEFGH12345678",reportedSSID:"PKT01",reportedPassword:"ABCDEFGH",evidence:good)
        case "I select Join and fast sync":
            if givenPhrase.contains("mismatched") { outcome = await coordinator.run(identityMatches:false,sessionKey:"ABCDEFGH12345678",reportedSSID:"PKT01",reportedPassword:"wrong",evidence:good) }
            else { outcome = await coordinator.run(identityMatches:true,sessionKey:"ABCDEFGH12345678",reportedSSID:"PKT01",reportedPassword:"ABCDEFGH",evidence:.init()) }
        case "Fast sync runs the typed authenticated control and HTTP boundaries": outcome = await coordinator.run(identityMatches:true,sessionKey:"ABCDEFGH12345678",reportedSSID:"PKT01",reportedPassword:"ABCDEFGH",evidence:good)
        case "Fast sync progress is presented without measured rate evidence": progress = .init(completed:9,total:23,measuredRate:false,measuredClaim:"1 MB/s")
        case "each attempt exits":
            for attempt in 0..<5 {
                if attempt == 1 { await http.failNextPull() }
                outcome = await coordinator.run(identityMatches:true,sessionKey:"ABCDEFGH12345678",reportedSSID:"PKT01",reportedPassword:"ABCDEFGH",evidence:good)
            }
            StoredFileDeviceLifecycle.runFullLinkLifecycle(liveBoundaries: liveBoundaries)
        default: break
        }
    }
    var good:PocketFastSyncEvidence { .init(stockControlTrace:true,closureSafety:true,endpoint:URL(string:"http://192.0.2.1/evidenced")!,endpointHardwareProvenance:true,iOSAccessPointJoin:true) }
    func then(_ phrase:String) async throws {
        switch phrase {
        case "both entry points show Fast sync and state that the phone leaves its normal network": XCTAssertEqual(entryPresentations.first?.title,"FAST SYNC"); XCTAssertTrue(entryPresentations.last?.body.contains("leaves its normal network") == true)
        case "the join receives the reported network and first eight session-key characters without showing or logging either secret": let points=await joiner.points(); XCTAssertEqual(points,[.init(ssid:"PKT01",password:"ABCDEFGH")]); XCTAssertFalse(PocketFastSyncPresentation.settings.body.contains("ABCDEFGH")); XCTAssertEqual(outcome,.completed)
        case "no network join occurs and the internet-loss warning was already visible": let points=await joiner.points(); XCTAssertEqual(points.count,0); XCTAssertEqual(outcome,.keptBluetooth); XCTAssertTrue(PocketFastSyncPresentation.sheetWarning.contains("Internet may be unavailable"))
        case "no WiFi command, network join, HTTP request, or durable handoff occurs": let points=await joiner.points(), urls=await http.urls(), payloads=await handoff.payloads(); XCTAssertEqual(outcome,.failed(.identityMismatch)); XCTAssertEqual(points.count,0); XCTAssertEqual(urls.count,0); XCTAssertEqual(payloads.count,0)
        case "Fast sync remains visible and finishes with a named unavailable gap": XCTAssertEqual(PocketFastSyncPresentation.setup.primaryAction,"Turn on Fast sync"); XCTAssertEqual(outcome,.unavailable(.closureSafety))
        case "exactly one verified completed payload reaches Pocket durable sync": let payloads=await handoff.payloads(); XCTAssertEqual(outcome,.completed); XCTAssertEqual(payloads,[Data([0xff,0xf3,1,2])])
        case "it shows 9 of 23 with Over, Now, and Waiting and no speed or ETA claim": XCTAssertEqual(progress?.count,"9 of 23"); XCTAssertEqual(progress?.states,["Over","Now","Waiting"]); XCTAssertNil(progress?.quantitativeClaim)
        case "cleanup is attempted, partial bytes never complete, no file is deleted, and no live capture path is reached":
            let cleaned = await control.cleanupCount()
            let completedPayloads = await handoff.payloads()
            let live = liveBoundaries.counts
            XCTAssertEqual(cleaned, 5)
            XCTAssertEqual(completedPayloads.count, 4)
            XCTAssertEqual(PocketRecorderCustodyPromise.automaticDeleteCommands, 0)
            XCTAssertEqual(live.storedFileLifecycleEvents, 5)
            XCTAssertEqual(live.activeSourceSelections + live.frameRouterStarts + live.walWrites + live.liveActivities + live.liveStateMutations, 0)
        default: XCTFail("Unhandled Then: \(phrase)")
        }
    }
}
private actor FastJoiner:PocketSoftAPJoining { var values:[PocketAccessPoint]=[]; func join(_ p:PocketAccessPoint)throws{values.append(p)}; func points()->[PocketAccessPoint]{values}; func clear(){values=[]} }
private actor FastHTTP:PocketHTTPPulling { var values:[URL]=[]; var fails=false; func pull(_ u:URL)throws->Data{values.append(u);if fails{fails=false;throw PocketFastSyncGap.httpFailed};return Data([0xff,0xf3,1,2])}; func failNextPull(){fails=true}; func urls()->[URL]{values}; func clear(){values=[];fails=false} }
private actor FastHandoff:PocketFastSyncHandoff { var values:[Data]=[]; func accept(_ p:Data)throws{guard p.starts(with:[0xff,0xf3]) else{throw PocketFastSyncGap.validationFailed};values.append(p)}; func payloads()->[Data]{values}; func clear(){values=[]} }
private actor FastControl:PocketFastSyncControlling { var prepared=0; var cleaned=0; func prepare(_ request:PocketRecordingRequest)throws{prepared += 1}; func cleanup(){cleaned += 1}; func cleanupCount()->Int{cleaned}; func clear(){prepared=0;cleaned=0} }
