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
                                               expectedScenarios: 8)
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
    let declaredRefusalCauses = 8

    /// How many elements are CONJUNCTIONS, and how many questions they carry between
    /// them. Held here, in the target's source, so that silently deleting an element's
    /// parts takes THREE coordinated edits (driver, register, and this) rather than
    /// two. The part comparison's own non-vacuity check is global — `partsCompared > 0`
    /// — so without these two numbers, dropping every prologue part from both the
    /// driver and the register would leave the negotiation parts keeping it green.
    /// MOVED 2026-08-13, from 2/6, when `host-binding-before-upgrade` became a conjunction.
    /// It had been a single wire observation — the bound address upgrades, the unbound one
    /// does not — and the relay's auth middle took that observation's discrimination away:
    /// eighteen refusal causes now write identical bytes, so "the unbound address answered
    /// 403" no longer says the refusal was about host binding. The third question asks the
    /// door's own seam which conjunct decided. See `ContractElements.hostBinding`.
    let declaredPartBearingElements = 3
    let declaredTotalParts = 9

    /// How many DIRECT handshake-peer constructor sites this target's own sources hold,
    /// and which files drive the five contract elements.
    ///
    /// This pair replaces a universal nobody counted. `features/p3-conformance.feature`
    /// used to open with "there is no injected responder anywhere in this target", and
    /// that was FALSE for as long as it stood: `DoorFixture.swift` builds a real
    /// `NoiseXXResponder` because P1's observable requires a real counterpart. The number
    /// is deliberately about CONSTRUCTOR SITES IN THIS DIRECTORY and not about which peers
    /// run — P1 also reaches an initiator indirectly, inside FoundryXKit, and no census of
    /// these files can see that. See `ConformancePeerCensus` for what it does and does not
    /// cover.
    let declaredInProcessPeerSites = 1
    /// WIDENED 2026-08-13. The element drive used to be two files; making the client
    /// conforming to the relay's auth middle gave it four more — the BIP-340 primitive, the
    /// canonical encoder, the community's signed log, and the reader for the door's seam.
    /// Each one is a place a peer could be constructed next to the drive, so each is named
    /// here: a census over the two files it used to be would have stopped covering most of
    /// the code that now decides the verdicts.
    let declaredElementDriveSources = ["ContractElements.swift", "P3Client.swift",
                                       "Secp256k1Schnorr.swift", "FoundryCanonicalBody.swift",
                                       "CommunityMembershipLog.swift", "DoorSeamLog.swift"]

    /// How many questions the run may record `not-reached`.
    ///
    /// Declared for the same reason `declaredTotalParts` is: a question that quietly stops
    /// being recorded unasked, or one that quietly starts, is a change to what this target
    /// claims it could not measure, and it should take an edit here to make it.
    let declaredNotReachedParts = 1

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
                    request: P3Client.conforming(host: f.boundHost, community: f.communityPid, identity: f.identity))
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
                w.lastExchange = try w.requireClient().exchange(request: P3Client.namingNoCommunity(host: f.boundHost, community: f.communityPid, identity: f.identity))
                return ctx
            },
            defineStep("a client asks for an address the deployment binds, naming a community it is not bound to") { ctx, _, _ in
                let f = try w.requireFixture()
                w.lastExchange = try w.requireClient().exchange(request: P3Client.namingWrongCommunity(host: f.boundHost, identity: f.identity))
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
                    throw ConformanceStepError("the run exercised \(run.causesExercised) refusal stimuli and the target declares \(w.declaredRefusalCauses). A stimulus that stopped being driven is not a smaller pass.")
                }
                print("CONFORMANCE: externally reachable refusal stimuli exercised = \(run.causesExercised) (covering 7 distinct in-process RefusalCause variants — see the register)")
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
            defineCheck("each element's individual questions are answered exactly as the register declares them") { _, _, _ in
                let register = try ContractElementRegister.load()
                let declaredByID = Dictionary(uniqueKeysWithValues: register.rows.map { ($0.id, $0.parts) })
                var partsCompared = 0
                var disagreements: [String] = []
                for element in w.drivenElements {
                    let declared = declaredByID[element.id] ?? nil
                    let observed = element.partMap
                    // Absence has to agree in both directions too. An element that grew
                    // parts without the register growing them, or the reverse, is a
                    // silent divergence between the declaration and the drive.
                    guard let declared else {
                        if !observed.isEmpty {
                            disagreements.append("  \(element.id): the run answered \(observed.keys.sorted()) and the register declares no parts for it")
                        }
                        continue
                    }
                    guard !observed.isEmpty else {
                        disagreements.append("  \(element.id): the register declares parts \(declared.keys.sorted()) and the run answered none")
                        continue
                    }
                    for name in Set(declared.keys).union(observed.keys).sorted() {
                        partsCompared += 1
                        let d = declared[name] ?? "<not declared>"
                        let o = observed[name] ?? "<not answered>"
                        if d != o { disagreements.append("  \(element.id) / \(name): declared \(d), observed \(o)") }
                    }
                    // The verdict must be the conjunction it claims to be, so a `served`
                    // hand-edited away from its own parts is red rather than believed.
                    let allMet = element.parts.allSatisfy { $0.verdict == .met }
                    if element.served != allMet {
                        disagreements.append("  \(element.id): served=\(element.served) but its parts are \(observed) — the verdict is not the conjunction of its questions")
                    }
                }
                // A comparison over zero parts reports clean and proves nothing — and
                // `> 0` is not enough either: with two part-bearing elements, dropping
                // one element's parts from BOTH the driver and the register leaves the
                // other's parts holding this green. The shape is asserted as NUMBERS.
                guard partsCompared > 0 else {
                    throw ConformanceStepError("the part comparison examined 0 parts across \(w.drivenElements.count) elements — a comparison over nothing is not a pass")
                }
                let partBearing = w.drivenElements.filter { !$0.parts.isEmpty }.count
                guard partBearing == w.declaredPartBearingElements else {
                    throw ConformanceStepError("\(partBearing) element(s) carried parts and this target declares \(w.declaredPartBearingElements). An element that stopped asking its questions is not a smaller pass.")
                }
                guard partsCompared == w.declaredTotalParts else {
                    throw ConformanceStepError("the run compared \(partsCompared) parts and this target declares \(w.declaredTotalParts)")
                }
                guard disagreements.isEmpty else {
                    throw ConformanceStepError("the register and the wire disagree, question by question:\n"
                                               + disagreements.joined(separator: "\n"))
                }
                print("CONFORMANCE: element parts compared = \(partsCompared), disagreements = 0")
                for element in w.drivenElements where !element.parts.isEmpty {
                    let rendered = element.parts.map { "\($0.name)=\($0.verdict.rawValue)" }.joined(separator: ", ")
                    print("CONFORMANCE: PARTS — \(element.id): \(rendered)")
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

            // WHY an element is unserved, reported strictly OUTSIDE `served`.
            //
            // `not-reached` is a third verdict on purpose — a question the run could not
            // ask, recorded as unasked rather than answered. That is honest and it is also
            // the most comfortable place in this file for a question to go and never come
            // back. So two things happen here, neither of which can move the count:
            //
            //  * each unserved element is CLASSIFIED — was the subject asked and did it
            //    not do the thing, or was the question never put to it — so a reader can
            //    tell "the relay refused" from "the relay has no such phase" without
            //    reading the driver; and
            //  * `not-reached` is required to be WAITING ON SOMETHING. A question recorded
            //    unasked while every question it depends on has been answered is a
            //    question that was droppable, and this says so by name.
            //
            // The second is not the same assertion the driver makes at
            // `ContractElements.swift` part 3, which throws when part 2 becomes MET. That
            // one is specific to `prologue-bytes` and lives in the drive; this one is a
            // property of every part-bearing element and is checked after the fact, so an
            // element that grows parts later inherits it.
            defineCheck("every unserved element names which of its questions were answered no and which were never asked") { _, _, _ in
                var partsInspected = 0
                var reported: [String] = []
                for e in w.drivenElements {
                    partsInspected += e.parts.count
                    guard !e.served else { continue }
                    let unasked = e.parts.filter { $0.verdict == .notReached }.map { $0.name }
                    let refused = e.parts.filter { $0.verdict == .unmet }.map { $0.name }
                    // NOT "the subject did not answer". For prologue-bytes the relay DID
                    // answer the existence question — by closing the socket inside a
                    // measured window — and it is the differential that was never put to
                    // it. Collapsing those two into one adjective is how a reader ends up
                    // believing the relay went silent on a question it in fact refused.
                    let answeredNo = refused.isEmpty
                        ? "answered no: this element's single question"
                        : "answered no: \(refused.joined(separator: ", "))"
                    let neverAsked = unasked.isEmpty
                        ? "never asked: none"
                        : "never asked: " + unasked.map { "\($0) (blocked by \((e.blockedBy[$0] ?? []).joined(separator: ", ")))" }.joined(separator: ", ")
                    reported.append("\(e.id): \(answeredNo); \(neverAsked)")
                }
                let unservedCount = w.drivenElements.filter { !$0.served }.count
                guard reported.count == unservedCount else {
                    throw ConformanceStepError("\(unservedCount) element(s) are unserved and \(reported.count) were reported on")
                }
                // Non-vacuity. When every element is served there is nothing to report and
                // this step must still have looked at something, so the number asserted is
                // the parts inspected — which cannot be zero at any tip this target declares.
                guard partsInspected == w.declaredTotalParts else {
                    throw ConformanceStepError("the unserved-reason report inspected \(partsInspected) parts and this target declares \(w.declaredTotalParts)")
                }
                print("CONFORMANCE: unserved elements reported = \(reported.count) of \(w.drivenElements.count), over \(partsInspected) part(s) — this is a REPORT, not a verdict; it changes no `served` and no part")
                for line in reported {
                    print("CONFORMANCE: UNSERVED-REASON — \(line)")
                }
            },
            defineCheck("every unasked question names what blocks it, and everything it names was answered no") { _, _, _ in
                var notReachedSeen = 0
                for e in w.drivenElements {
                    let verdicts = Dictionary(uniqueKeysWithValues: e.parts.map { ($0.name, $0.verdict) })
                    for (name, verdict) in verdicts where verdict == .notReached {
                        notReachedSeen += 1
                        let blockers = e.blockedBy[name] ?? []
                        guard !blockers.isEmpty else {
                            throw ConformanceStepError("""
                            \(e.id) / \(name) is recorded NOT REACHED and names nothing that blocked it. \
                            `not-reached` means a question the run COULD NOT ask; one that nothing is blocking \
                            is a question that was dropped.
                            """)
                        }
                        for blocker in blockers {
                            guard let bv = verdicts[blocker] else {
                                throw ConformanceStepError("\(e.id) / \(name) says it is blocked by `\(blocker)`, which is not a question of this element (\(verdicts.keys.sorted()))")
                            }
                            guard bv == .unmet else {
                                throw ConformanceStepError("""
                                \(e.id) / \(name) is recorded NOT REACHED and says it is blocked by `\(blocker)`, \
                                which was answered \(bv.rawValue). A question whose blocker has been answered is a \
                                question the run could have asked.
                                """)
                            }
                        }
                    }
                }
                guard notReachedSeen == w.declaredNotReachedParts else {
                    throw ConformanceStepError("the run recorded \(notReachedSeen) not-reached question(s) and this target declares \(w.declaredNotReachedParts). A question that stopped being recorded unasked is not a smaller pass, and one that started is not a silent one.")
                }
                print("CONFORMANCE: not-reached questions = \(notReachedSeen), each naming a blocker that was answered unmet")
            },

            // ---------------------------------------------------------------- the peers
            defineCheck("the number of direct handshake-peer constructor sites in this target is the number it declares") { _, _, _ in
                let files = try ConformancePeerCensus.targetSwiftFiles()
                guard files.count > 0 else {
                    throw ConformanceStepError("the peer census examined 0 files — a census over nothing reports clean and proves nothing")
                }
                let sites = try ConformancePeerCensus.sites(in: files)
                guard sites.count == w.declaredInProcessPeerSites else {
                    throw ConformanceStepError("""
                    this target's own sources hold \(sites.count) direct handshake-peer constructor site(s) and it \
                    declares \(w.declaredInProcessPeerSites): \(sites.isEmpty ? "none found" : sites.joined(separator: ", ")). \
                    A site added here is a second in-process peer inside a target whose headline metric is a spawned \
                    relay's contract; the site that is here is P1's door, and removing it is P1 losing the real \
                    counterpart its observable is defined against.
                    """)
                }
            },
            defineCheck("the sources that drive the five contract elements contain none of them") { _, _, _ in
                let sources = try ConformancePeerCensus.elementDriveSources(w.declaredElementDriveSources)
                let sites = try ConformancePeerCensus.sites(in: sources)
                guard sites.isEmpty else {
                    throw ConformanceStepError("""
                    the five contract elements are driven from \(w.declaredElementDriveSources.joined(separator: ", ")) \
                    and \(sites.count) handshake-peer constructor site(s) appear there: \(sites.joined(separator: ", ")). \
                    An element verdict computed against a peer this target built is a verdict about this repository, \
                    not about the relay.
                    """)
                }
            },
            defineCheck("the files examined for both counts are reported, with what the census cannot see") { _, _, _ in
                let all = try ConformancePeerCensus.targetSwiftFiles()
                let drive = try ConformancePeerCensus.elementDriveSources(w.declaredElementDriveSources)
                let names = try ConformancePeerCensus.peerTypeNames()
                print("CONFORMANCE: peer census examined \(all.count) target file(s) for direct constructor calls to \(names.joined(separator: ", ")) — \(w.declaredInProcessPeerSites) site(s) declared; element-drive census examined \(drive.count) file(s) and requires 0")
                print("CONFORMANCE: peer census CANNOT SEE — a peer reached indirectly. P1 dials through the production client, which builds an initiator inside FoundryXKit (RelayTransport.swift / DoorConnection.swift); no census of this directory sees that, and this count is a lexical census of DIRECT constructor calls, not a claim about which peers run.")
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
