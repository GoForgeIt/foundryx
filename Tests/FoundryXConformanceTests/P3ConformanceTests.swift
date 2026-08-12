import XCTest
import Foundation
import BrineSwiftCore

/// The non-hermetic P3 conformance target.
///
/// There is no injected responder in this file and no `XCTSkip` in this target. A
/// machine that cannot start the relay fails here, loudly, naming what was missing.
final class P3ConformanceTests: XCTestCase {

    /// Held across the run so the teardown scenario can assert against the same pids
    /// and directories the bring-up recorded, and so `tearDown` can make a second,
    /// idempotent pass if a scenario failed before the teardown scenario ran.
    private var world: ConformanceWorld!

    override func tearDown() {
        world?.fixture?.teardown()
        world = nil
        super.tearDown()
    }

    func testP3ConformanceFeature() async throws {
        let w = ConformanceWorld()
        world = w
        try await ConformanceFeatureDriver.run("p3-conformance",
                                               registry: StepRegistry(P3ConformanceSteps.make(world: w)),
                                               expectedScenarios: 7)
    }
}

final class ConformanceWorld: @unchecked Sendable {
    var fixture: RelayProcessFixture?
    var client: P3Client?
    var lastExchange: P3Client.Exchange?
    var rejectionRun: ContractElementDriver.RejectionRun?
    var drivenElements: [ContractElement] = []
    var teardownReport: RelayProcessFixture.TeardownReport?

    /// The number of externally reachable refusal causes the driver declares. The run
    /// reports what it exercised and the check asserts the two are equal, so deleting
    /// a cause is red rather than a smaller silent pass.
    let declaredRefusalCauses = 6

    func requireFixture() throws -> RelayProcessFixture {
        guard let f = fixture else { throw ConformanceStepError("no relay was started") }
        return f
    }
    func requireClient() throws -> P3Client {
        guard let c = client else { throw ConformanceStepError("no client was made") }
        return c
    }
    func requireExchange() throws -> P3Client.Exchange {
        guard let e = lastExchange else { throw ConformanceStepError("no exchange has happened yet") }
        return e
    }
}

enum P3ConformanceSteps {
    static func make(world w: ConformanceWorld) -> [StepDefinition] {
        [
            // ---------------------------------------------------------------- background
            defineStep("a relay process started from the binary the deployment's configuration key names") { ctx, _, _ in
                if w.fixture == nil {
                    let f = RelayProcessFixture()
                    // A failure here THROWS, naming the missing relay. It does not skip.
                    try f.start()
                    w.fixture = f
                    w.client = P3Client(port: f.port)
                }
                return ctx
            },
            defineStep("the harness has recorded that process's pid and the digest of the image it is running") { ctx, _, _ in
                let f = try w.requireFixture()
                guard f.pid > 0, kill(f.pid, 0) == 0 else {
                    throw ConformanceStepError("the run recorded pid \(f.pid), and no such process is alive")
                }
                guard f.imageDigest.count == 64, f.imageDigest.allSatisfy({ $0.isHexDigit }) else {
                    throw ConformanceStepError("the run recorded no usable digest for the relay image (got \"\(f.imageDigest)\")")
                }
                return ctx
            },

            // ---------------------------------------------------------------- the conforming client
            defineStep("a client asks for an address the deployment binds, naming the community it is bound to") { ctx, _, _ in
                let f = try w.requireFixture()
                w.lastExchange = try w.requireClient().exchange(
                    request: P3Client.conforming(host: f.boundHost, community: f.communityPid))
                return ctx
            },
            defineCheck("the connection is upgraded") { _, _, _ in
                let r = try w.requireExchange()
                guard r.upgraded else {
                    throw ConformanceStepError("expected an upgrade; the relay answered \(firstLine(r))")
                }
            },
            defineCheck("the relay returns a session token") { _, _, _ in
                let r = try w.requireExchange()
                guard let token = r.sessionToken, !token.isEmpty else {
                    throw ConformanceStepError("the upgrade carried no session token; headers were \(r.text.split(separator: "\r\n").dropFirst().joined(separator: " | "))")
                }
            },

            // ---------------------------------------------------------------- the non-conforming fixtures
            defineStep("a client asks for an address the deployment binds, naming no community at all") { ctx, _, _ in
                let f = try w.requireFixture()
                w.lastExchange = try w.requireClient().exchange(request: P3Client.namingNoCommunity(host: f.boundHost))
                return ctx
            },
            defineStep("a client asks for an address the deployment binds, naming a community it is not bound to") { ctx, _, _ in
                let f = try w.requireFixture()
                w.lastExchange = try w.requireClient().exchange(request: P3Client.namingWrongCommunity(host: f.boundHost))
                return ctx
            },
            defineCheck("the connection is refused") { _, _, _ in
                let r = try w.requireExchange()
                guard r.refused else {
                    throw ConformanceStepError("expected a refusal; the relay answered \(firstLine(r))")
                }
            },
            defineCheck("the connection is never upgraded") { _, _, _ in
                let r = try w.requireExchange()
                guard !r.upgraded else {
                    throw ConformanceStepError("the connection was upgraded — a relay that upgrades and then closes has still upgraded")
                }
            },

            // ---------------------------------------------------------------- the one refusal
            defineStep("the client provokes a refusal by each distinct cause it can reach from outside") { ctx, _, _ in
                w.rejectionRun = try ContractElementDriver.genericRejections(try w.requireClient(), try w.requireFixture())
                return ctx
            },
            defineCheck("every refusal is byte-identical") { _, _, _ in
                guard let run = w.rejectionRun else { throw ConformanceStepError("no refusals were provoked") }
                guard run.identical else { throw ConformanceStepError(run.element.observation) }
            },
            defineCheck("the number of distinct causes exercised is reported") { _, _, _ in
                guard let run = w.rejectionRun else { throw ConformanceStepError("no refusals were provoked") }
                guard run.causesExercised == w.declaredRefusalCauses else {
                    throw ConformanceStepError("the run exercised \(run.causesExercised) refusal causes and the target declares \(w.declaredRefusalCauses). A cause that stopped being driven is not a smaller pass.")
                }
                print("CONFORMANCE: distinct refusal causes exercised = \(run.causesExercised)")
            },

            // ---------------------------------------------------------------- the five elements
            defineStep("the client drives each of the five published contract elements against the relay") { ctx, _, _ in
                w.drivenElements = try ContractElementDriver.driveAll(client: try w.requireClient(),
                                                                     fixture: try w.requireFixture())
                return ctx
            },
            defineCheck("five contract elements are examined") { _, _, _ in
                guard w.drivenElements.count == 5 else {
                    throw ConformanceStepError("the run examined \(w.drivenElements.count) contract elements, not 5")
                }
                let ids = Set(w.drivenElements.map { $0.id })
                guard ids == Set(ContractElementDriver.declaredIds) else {
                    throw ConformanceStepError("the run examined \(ids.sorted()), which is not the published five \(ContractElementDriver.declaredIds.sorted())")
                }
                print("CONFORMANCE: contract elements examined = \(w.drivenElements.count)")
            },
            defineCheck("the elements the relay serves are exactly the elements the register declares served") { _, _, _ in
                let register = try ContractElementRegister.load()
                let observed = Set(w.drivenElements.filter { $0.served }.map { $0.id })
                let declared = register.servedIds
                print("CONFORMANCE: contract elements served = \(observed.count) of \(w.drivenElements.count) — \(observed.sorted())")
                guard observed == declared else {
                    let onlyObserved = observed.subtracting(declared).sorted()
                    let onlyDeclared = declared.subtracting(observed).sorted()
                    let detail = w.drivenElements
                        .filter { onlyDeclared.contains($0.id) || onlyObserved.contains($0.id) }
                        .map { "  \($0.id): served=\($0.served) — \($0.observation)" }
                        .joined(separator: "\n")
                    throw ConformanceStepError("""
                    the register and the wire disagree.
                      declared served but NOT served on the wire: \(onlyDeclared)
                      served on the wire but NOT declared:        \(onlyObserved)
                    \(detail)
                    """)
                }
            },
            defineCheck("every element the relay does not serve is named with what the client observed") { _, _, _ in
                let unserved = w.drivenElements.filter { !$0.served }
                for e in unserved where e.observation.isEmpty {
                    throw ConformanceStepError("element \(e.id) is not served and the run recorded no observation for it")
                }
                for e in unserved {
                    print("CONFORMANCE: NOT SERVED — \(e.id): \(e.observation)")
                }
                for e in w.drivenElements where e.served {
                    print("CONFORMANCE: SERVED — \(e.id): \(e.observation)")
                }
            },

            // ---------------------------------------------------------------- teardown
            defineStep("the harness tears the relay down by the pid it captured") { ctx, _, _ in
                w.teardownReport = try w.requireFixture().teardown()
                return ctx
            },
            defineCheck("no process the harness started is still listening") { _, _, _ in
                guard let r = w.teardownReport else { throw ConformanceStepError("teardown never ran") }
                guard r.stillRunning.isEmpty else {
                    throw ConformanceStepError("\(r.stillRunning.count) process(es) the harness started are still alive: \(r.stillRunning)")
                }
            },
            defineCheck("no scratch directory the harness created is left behind") { _, _, _ in
                guard let r = w.teardownReport else { throw ConformanceStepError("teardown never ran") }
                guard r.stillPresent.isEmpty else {
                    throw ConformanceStepError("\(r.stillPresent.count) scratch director(ies) survived teardown: \(r.stillPresent)")
                }
            },
            defineCheck("the number of candidates examined for each is reported") { _, _, _ in
                guard let r = w.teardownReport else { throw ConformanceStepError("teardown never ran") }
                let f = try w.requireFixture()
                guard r.pidCandidatesExamined == f.startedPids.count, r.pidCandidatesExamined > 0 else {
                    throw ConformanceStepError("teardown examined \(r.pidCandidatesExamined) pid candidates and the run started \(f.startedPids.count). A counter that examines fewer candidates than the run created cannot see a leak.")
                }
                guard r.scratchCandidatesExamined == f.scratchDirs.count, r.scratchCandidatesExamined > 0 else {
                    throw ConformanceStepError("teardown examined \(r.scratchCandidatesExamined) directory candidates and the run created \(f.scratchDirs.count)")
                }
                print("CONFORMANCE: teardown examined \(r.pidCandidatesExamined) pid candidate(s) and \(r.scratchCandidatesExamined) scratch director(ies)")
            },

            // ---------------------------------------------------------------- the census
            defineCheck("the target's own sources contain zero skip sites") { _, _, _ in
                let examined = try ConformanceSkipCensus.filesExamined()
                guard examined > 0 else {
                    throw ConformanceStepError("the skip census examined 0 files — a census over nothing reports clean and proves nothing")
                }
                let hits = try ConformanceSkipCensus.skipSites()
                guard hits.isEmpty else {
                    throw ConformanceStepError("\(hits.count) skip site(s) in this target across \(examined) files: \(hits.joined(separator: ", "))")
                }
                print("CONFORMANCE: skip census examined \(examined) files, found 0 skip sites")
            },
        ]
    }

    private static func firstLine(_ r: P3Client.Exchange) -> String {
        r.text.split(separator: "\r\n").first.map(String.init) ?? "<no reply at all>"
    }
}
