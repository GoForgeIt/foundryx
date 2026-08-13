import XCTest
import Foundation
import BrineSwiftCore
import CryptoKit
@testable import FoundryXKit

/// Brine driver for `features/prologue-binding.feature`.
///
/// ## What this establishes, and what it deliberately does not
///
/// The conformance target's `prologue-bytes` element is a conjunction of three questions.
/// Question 3 — *a transcript completed for one bound address must not complete against
/// another* — has been recorded `not-reached` for every measurement this program has taken,
/// because `crates/foundry-relay/src/serve.rs` stops at the `101` on purpose and there is
/// no post-upgrade transcript for a prologue to be mixed into. Re-derived at foundry
/// `afaba943`: `grep -rni prologue --include='*.rs' crates/` → **0 hits**.
///
/// `not-reached` was therefore doing two jobs at once: *nothing answered* and *nobody knew
/// how to ask*. This file retires the second, for the hermetic case. The question is asked
/// here against this repository's own `NoiseXXInitiator` and `NoiseXXResponder`, and it is
/// graded by mutations that make it fail.
///
/// **TWO OVERSTATEMENTS CORRECTED 2026-08-13, both of them universals nobody counted.**
/// (1) This paragraph used to call these "the only two peers that exist". They are not:
/// `crates/foundryx-tunnel` in the foundry repository speaks `Noise_XX_25519_ChaChaPoly_BLAKE2s`
/// through `snow` (`src/lib.rs:34`) and carries golden vectors declared to be "the interop
/// contract the iOS Swift client" must match (`tests/handshake_vectors.rs:1`). They are the
/// only two peers THIS TARGET can reach, which is a fact about the target and not about the
/// world. (2) Retiring "nobody knew how to ask" is narrower than it sounded: the day the
/// relay grows a post-upgrade transcript, `ContractElements.prologue` still has no live
/// differential to drive and deliberately THROWS rather than inventing one. What exists is
/// an oracle for the property, not an adapter to a real subject.
///
/// **It does not serve the element and it must never be read as serving it.** `Package.swift`
/// places `FoundryXBrineTests` outside `FoundryXConformanceTests`'s dependency closure exactly
/// so that "a conformance obligation met inside this runner would be met against our own
/// responder" is a fact of the build graph, and `scripts/check-conformance-topology.py`
/// asserts it. The register's `served` for `prologue-bytes` stays `false`.
///
/// ## Why an in-process handshake, and the analogy that does NOT hold
///
/// A prologue is mixed into the transcript hash rather than asserted about the wire
/// (`NoiseXX.swift:209-211` and `:317-319` take `prologue: Data` and `mixHash` it). What a peer
/// bound is therefore not recoverable from any single message — only *completed* or *failed*
/// distinguishes agreement from disagreement — so an oracle for the differential has to run a
/// handshake, and the only two peers in existence are these.
///
/// **The tempting justification is wrong and is recorded so nobody reaches for it again.** The
/// contract register grades `version-negotiation`'s two surviving mutations *"where they are
/// observable — the relay's own in-process vector table"*, and it is NOT the same move: that
/// table is inside the relay, which is the subject. `NoiseXXInitiator` is not. A gpt-5.6-sol
/// review named the difference, and it is the reason this file lives outside the conformance
/// target rather than inside it with the analogy pinned to the front. What is graded here is
/// an ORACLE, not a subject; the subject is still missing and the element is still not served.
///
/// ## The mutations that grade these scenarios
///
/// Recorded in `evidence/prologue-binding/` and re-runnable:
///
///  - **M1** — drop `sym.mixHash(prologue)` from the INITIATOR only. The matched run stops
///    completing, so scenario 1 reddens.
///  - **M2** — drop it from BOTH peers, which is what "the prologue is not load-bearing"
///    actually means. Every mismatched run starts completing, so scenarios 2, 3 and 4 redden.
///    **This is the mutation the element turns on.**
///  - **M3** — drop it from the RESPONDER only. Scenario 1 reddens.
///  - **M4** — this driver's own oracle: give the mismatch scenarios identical prologues.
///    Scenario 2 reddens, which proves its verdict is computed from the input rather than
///    asserted.
final class PrologueBindingFeatureTests: XCTestCase {

    func testPrologueBindingFeature() async throws {
        try await PrologueBindingRunner.run(
            "prologue-binding",
            registry: StepRegistry(PrologueBindingSteps.make(world: PrologueBindingWorld())),
            expectedScenarios: 6)
    }
}

/// A runner that asserts the EXECUTED count.
///
/// `BrineFeatureRunner` — the shared hermetic driver 90-odd feature tests use — asserts
/// `failures.isEmpty` and `result.failed == 0` and **never asserts how many scenarios ran**.
/// A renamed feature file, a `Background` that throws before the first scenario, or a parse
/// that yields zero scenarios all report green through it. That gap is recorded as a finding
/// rather than repaired here, because widening the shared runner's signature touches every
/// caller in the target and belongs to whoever owns them; this feature carries its own count
/// so that at least this one cannot pass on zero work.
enum PrologueBindingRunner {

    private static func featureText(_ name: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("features/\(name).feature"),
                          encoding: .utf8)
    }

    static func run(_ name: String, registry: StepRegistry, expectedScenarios: Int) async throws {
        let parsed = parseFeatureText(try featureText(name))
        XCTAssertFalse(parsed.features.isEmpty, "no features parsed for \(name)")

        var collected: [JSONValue] = []
        let result = try await Resources.run(parsed.features, registry: registry,
                                             resources: [], collector: { collected.append($0) })

        var failures: [String] = []
        var executed = 0
        for ev in collected {
            guard case .object(let o) = ev, case .string("scenario_end")? = o["type"] else { continue }
            executed += 1
            guard case .string(let status)? = o["status"], status != "passed" else { continue }
            let nm: String = { if case .string(let s)? = o["name"] { return s }; return "?" }()
            let err: String = { if case .string(let e)? = o["error"] { return e }; return "(no error)" }()
            failures.append("[\(status)] \(nm): \(err)")
        }

        XCTAssertGreaterThan(executed, 0,
                             "\(name): ZERO SCENARIOS EXECUTED — this is a gate bug, not a pass")
        XCTAssertEqual(executed, expectedScenarios,
                       "\(name): executed \(executed) scenarios, expected \(expectedScenarios). A scenario that stopped running is not a pass.")
        XCTAssertEqual(result.skipped, 0, "\(name): \(result.skipped) scenarios were skipped")
        XCTAssertTrue(failures.isEmpty, "\(name) scenarios failed:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result.failed, 0, "\(name): expected 0 failed scenarios")
        print("PROLOGUE-BINDING: scenarios executed = \(executed), failed = \(result.failed), skipped = \(result.skipped)")
    }
}

/// One run of the handshake, described by what an observer outside it could tell.
struct PrologueHandshakeRun {
    /// Both peers reached transport mode.
    let completed: Bool
    /// Which message the handshake died on, and with what. Empty when it completed.
    let failedAt: String
    let error: String
    /// Transport keys were produced — asked of BOTH peers, because "the initiator gave up"
    /// and "no channel exists" are different facts.
    let initiatorSplit: Bool
    let responderSplit: Bool
    /// A payload encrypted by each side and read by the other. A handshake that "completes"
    /// into keys that cannot carry traffic has not completed.
    let trafficBothWays: Bool
}

final class PrologueBindingWorld: @unchecked Sendable {

    // ---- PINNED. Every value both peers use, other than the prologue ------------------
    //
    // Static keys AND ephemerals are fixed, so two runs of this world differ in the
    // prologue and in nothing else. Without the pinned ephemerals a failing run and a
    // completing run would differ in four values, and "the prologue caused it" would be an
    // inference rather than an observation.
    let initiatorStatic = Data(repeating: 0x11, count: 32)
    let responderStatic = Data(repeating: 0x22, count: 32)
    let initiatorEphemeral = Data(repeating: 0x33, count: 32)
    let responderEphemeral = Data(repeating: 0x44, count: 32)

    /// What each side binds the handshake to. Set by the Given steps; the only free variable.
    var initiatorPrologue = Data()
    var responderPrologue = Data()

    var run: PrologueHandshakeRun?

    // ---- the stimulus question -------------------------------------------------------
    //
    // A peer that speaks the handshake and is waiting to be spoken to, plus what it did with
    // whatever it was handed. Used by the last two scenarios, which are not about the binding
    // at all but about whether the conformance target's post-upgrade probe is a knock anybody
    // could answer.
    var listeningPeer: NoiseXXResponder?
    var peerCouldRead = false
    var peerReadError = ""
    var peerReply = Data()

    /// The tenancy bytes as the conformance drive USED to send them after the `101`: the
    /// bound address followed by the version as u16 big-endian.
    ///
    /// STALE LABEL CORRECTED 2026-08-13 — this used to say "EXACTLY what
    /// `ContractElements.prologue` sends after the `101` today", and that stopped being
    /// true when part 2's probe became a 32-byte opening message. The scenario these bytes
    /// feed is still the one worth having: it is the demonstration that bare tenancy is NOT
    /// something a Noise peer can read as an opening, which is WHY the drive was changed.
    /// Naming it "what the drive sends" would now be a claim about a sibling target that is
    /// false, and this file cannot check it.
    static let tenancyBytesAsTheOldDriveSentThem: Data = prologue(host: "bound.example", version: 1)

    /// True once a Given has actually set both bindings. A When that ran without one would
    /// be measuring two empty prologues, which agree — a green from a scenario that set
    /// nothing up.
    var bindingsDeclared = false

    // The tenancy halves, in the shape `03-protocols.md` P3 names:
    // prologue = (normalized_host || negotiated_version).
    static func prologue(host: String, version: UInt16) -> Data {
        var d = Data(host.utf8)
        d.append(UInt8(truncatingIfNeeded: version >> 8))
        d.append(UInt8(truncatingIfNeeded: version))
        return d
    }

    func require() throws -> PrologueHandshakeRun {
        guard let r = run else { throw BrineStepError("no handshake has been run yet") }
        return r
    }

    /// Run the XX handshake end to end between two real peers and report what happened.
    ///
    /// Nothing here is caught and turned into a status: an unexpected failure is reported
    /// with the stage it happened at, so a scenario that reds because CryptoKit changed
    /// cannot be misread as a scenario that reds because the prologue disagreed.
    func handshake(initiatorPrologue ip: Data, responderPrologue rp: Data) throws -> PrologueHandshakeRun {
        let i = try NoiseXXInitiator(staticPrivate: initiatorStatic,
                                     fixedEphemeral: initiatorEphemeral, prologue: ip)
        let r = try NoiseXXResponder(staticPrivate: responderStatic,
                                     fixedEphemeral: responderEphemeral, prologue: rp)

        var stage = ""
        do {
            stage = "msg1 (initiator → responder)"
            let msg1 = try i.writeMessage()
            _ = try r.readMessage(msg1)

            stage = "msg2 (responder → initiator)"
            let msg2 = try r.writeMessage()
            _ = try i.readMessage(msg2)

            stage = "msg3 (initiator → responder)"
            let msg3 = try i.writeMessage()
            _ = try r.readMessage(msg3)

            stage = "split"
            let (iSend, iRecv) = try i.split()
            let (rSend, rRecv) = try r.split()

            stage = "transport"
            let up = try iSend.encryptWithAd(ad: Data(), plaintext: Data("ping".utf8))
            let upSeen = try rRecv.decryptWithAd(ad: Data(), ciphertext: up)
            let down = try rSend.encryptWithAd(ad: Data(), plaintext: Data("pong".utf8))
            let downSeen = try iRecv.decryptWithAd(ad: Data(), ciphertext: down)

            return PrologueHandshakeRun(
                completed: true, failedAt: "", error: "",
                initiatorSplit: true, responderSplit: true,
                trafficBothWays: upSeen == Data("ping".utf8) && downSeen == Data("pong".utf8))
        } catch {
            // Ask BOTH peers whether they ended up with keys, rather than inferring it
            // from where the throw happened.
            let iSplit = (try? i.split()) != nil
            let rSplit = (try? r.split()) != nil
            return PrologueHandshakeRun(
                completed: false, failedAt: stage, error: "\(error)",
                initiatorSplit: iSplit, responderSplit: rSplit, trafficBothWays: false)
        }
    }
}

enum PrologueBindingSteps {

    static func make(world w: PrologueBindingWorld) -> [StepDefinition] {
        [
            // ------------------------------------------------------------- background
            defineStep("two peers that already hold everything they need to complete a handshake") { ctx, _, _ in
                w.run = nil
                w.bindingsDeclared = false
                // Non-vacuity for the whole feature: with NO binding declared at all these
                // two peers complete. If they did not, every "the handshake fails" below
                // would be satisfied by a rig that cannot handshake, and the feature would
                // pass while proving nothing about prologues.
                let control = try w.handshake(initiatorPrologue: Data(), responderPrologue: Data())
                guard control.completed, control.trafficBothWays else {
                    throw BrineStepError("""
                    the two peers cannot complete a handshake even with nothing bound \
                    (failed at \(control.failedAt): \(control.error)). Every failure this \
                    feature asserts would then be free. Fix the peers before reading a \
                    single scenario below.
                    """)
                }
                return ctx
            },
            defineStep("every value both peers use is pinned except what each side binds the handshake to") { ctx, _, _ in
                // Asserted, not assumed: two runs with the same bindings must be
                // byte-identical, which is only true if the ephemerals really are pinned.
                let a = try w.handshake(initiatorPrologue: Data("pin".utf8), responderPrologue: Data("pin".utf8))
                let b = try w.handshake(initiatorPrologue: Data("pin".utf8), responderPrologue: Data("pin".utf8))
                guard a.completed, b.completed else {
                    throw BrineStepError("a run with matching bindings did not complete, so nothing below is measurable")
                }
                guard w.initiatorStatic.count == 32, w.responderStatic.count == 32,
                      w.initiatorEphemeral.count == 32, w.responderEphemeral.count == 32,
                      w.initiatorStatic != w.responderStatic,
                      w.initiatorEphemeral != w.responderEphemeral else {
                    throw BrineStepError("the pinned key material is not what this feature says it is")
                }
                return ctx
            },

            // ------------------------------------------------------------- the bindings
            defineStep("both peers bind the handshake to the same address and the same agreed version") { ctx, _, _ in
                let p = PrologueBindingWorld.prologue(host: "community-a.example", version: 1)
                w.initiatorPrologue = p
                w.responderPrologue = p
                w.bindingsDeclared = true
                return ctx
            },
            defineStep("the two peers bind the handshake to different addresses") { ctx, _, _ in
                w.initiatorPrologue = PrologueBindingWorld.prologue(host: "community-a.example", version: 1)
                w.responderPrologue = PrologueBindingWorld.prologue(host: "community-b.example", version: 1)
                w.bindingsDeclared = true
                return ctx
            },
            defineStep("the two peers bind the handshake to the same address but to different agreed versions") { ctx, _, _ in
                w.initiatorPrologue = PrologueBindingWorld.prologue(host: "community-a.example", version: 1)
                w.responderPrologue = PrologueBindingWorld.prologue(host: "community-a.example", version: 2)
                w.bindingsDeclared = true
                return ctx
            },
            defineStep("the two peers bind the handshake to addresses that differ in exactly one byte") { ctx, _, _ in
                let a = PrologueBindingWorld.prologue(host: "community-a.example", version: 1)
                let b = PrologueBindingWorld.prologue(host: "community-b.example", version: 1)
                let differing = zip(a, b).filter { $0 != $1 }.count
                guard a.count == b.count, differing == 1 else {
                    throw BrineStepError("""
                    this scenario claims exactly one differing byte and the two bindings differ \
                    in \(differing) of \(a.count). The claim is the point of the scenario; it is \
                    not rounded off.
                    """)
                }
                w.initiatorPrologue = a
                w.responderPrologue = b
                w.bindingsDeclared = true
                return ctx
            },

            // ------------------------------------------------------------- the run
            defineStep("the two peers run the handshake") { ctx, _, _ in
                guard w.bindingsDeclared else {
                    throw BrineStepError("no scenario declared what either peer binds; two undeclared bindings agree, and a pass from that is a pass from nothing")
                }
                w.run = try w.handshake(initiatorPrologue: w.initiatorPrologue,
                                        responderPrologue: w.responderPrologue)
                return ctx
            },

            // ------------------------------------------------------------- the verdicts
            defineCheck("the handshake completes") { _, _, _ in
                let r = try w.require()
                guard r.completed else {
                    throw BrineStepError("the handshake did not complete: it failed at \(r.failedAt) with \(r.error)")
                }
            },
            defineCheck("each side can read what the other encrypts") { _, _, _ in
                let r = try w.require()
                guard r.trafficBothWays else {
                    throw BrineStepError("the handshake completed but the two transport directions did not round-trip, so the peers hold keys that do not pair")
                }
            },
            defineCheck("the handshake fails") { _, _, _ in
                let r = try w.require()
                guard !r.completed else {
                    throw BrineStepError("""
                    the handshake COMPLETED although the two peers bound it to different things. \
                    The prologue is not load-bearing in this build: a transcript made for one \
                    address would be usable against another, which is the property \
                    design/03-protocols.md P3 step 3 claims for it.
                    """)
                }
                // The failure must be the AEAD refusing the responder's static, at msg2 —
                // not a short buffer, not a length check, and not an exception from
                // somewhere else that happens to look like a refusal.
                guard r.failedAt == "msg2 (responder → initiator)" else {
                    throw BrineStepError("""
                    the handshake failed at \(r.failedAt) rather than at msg2, with \(r.error). \
                    A red for the wrong reason is not evidence that the prologue is bound: msg2 \
                    is where the responder's static arrives sealed under a transcript hash that \
                    includes the prologue, and that is the first place a disagreement can show.
                    """)
                }
            },
            defineCheck("neither side is given transport keys") { _, _, _ in
                let r = try w.require()
                guard !r.initiatorSplit, !r.responderSplit else {
                    throw BrineStepError("""
                    a peer was given transport keys from a handshake that did not complete \
                    (initiator=\(r.initiatorSplit), responder=\(r.responderSplit)). Keys from an \
                    unfinished transcript are a channel nobody authenticated.
                    """)
                }
            },
            defineCheck("a second run that changes nothing but that one byte completes") { _, _, _ in
                let failing = try w.require()
                guard !failing.completed else {
                    throw BrineStepError("the first run completed, so there is no failure for this control to be compared against")
                }
                // Restore the single differing byte and change NOTHING else.
                let restored = w.initiatorPrologue
                let paired = try w.handshake(initiatorPrologue: restored, responderPrologue: restored)
                guard paired.completed, paired.trafficBothWays else {
                    throw BrineStepError("""
                    with the one differing byte restored the handshake still did not complete \
                    (failed at \(paired.failedAt): \(paired.error)). The failing run cannot then \
                    be attributed to that byte.
                    """)
                }
                let differing = zip(w.initiatorPrologue, w.responderPrologue).filter { $0 != $1 }.count
                guard differing == 1 else {
                    throw BrineStepError("the paired runs differ in \(differing) bytes, not 1, so this is not the control it claims to be")
                }
            },

            // ------------------------------------------------- is the drive's knock answerable
            defineStep("a peer that speaks the handshake correctly and is waiting to be spoken to") { ctx, _, _ in
                w.listeningPeer = try NoiseXXResponder(staticPrivate: w.responderStatic,
                                                       fixedEphemeral: w.responderEphemeral)
                w.peerCouldRead = false
                w.peerReadError = ""
                w.peerReply = Data()
                return ctx
            },
            defineStep("it is handed the tenancy bytes on their own") { ctx, _, _ in
                guard let peer = w.listeningPeer else { throw BrineStepError("no listening peer") }
                do {
                    _ = try peer.readMessage(PrologueBindingWorld.tenancyBytesAsTheOldDriveSentThem)
                    w.peerCouldRead = true
                } catch {
                    w.peerCouldRead = false
                    w.peerReadError = "\(error)"
                }
                return ctx
            },
            defineStep("it is handed an opening message of the size the handshake defines") { ctx, _, _ in
                guard let peer = w.listeningPeer else { throw BrineStepError("no listening peer") }
                // An opening message carrying no payload is exactly the sender's 32-byte
                // ephemeral public value. Written out as raw bytes on purpose: the point is
                // what the SIZE and SHAPE of a first message are, not what any particular
                // implementation of a sender would emit.
                let opening = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                guard opening.count == 32 else {
                    throw BrineStepError("an opening value is 32 bytes; this one is \(opening.count)")
                }
                do {
                    _ = try peer.readMessage(opening)
                    w.peerCouldRead = true
                    w.peerReply = try peer.writeMessage()
                } catch {
                    w.peerCouldRead = false
                    w.peerReadError = "\(error)"
                }
                return ctx
            },
            defineCheck("it cannot read them as an opening at all") { _, _, _ in
                guard !w.peerCouldRead else {
                    throw BrineStepError("""
                    a correctly speaking peer ACCEPTED \(PrologueBindingWorld.tenancyBytesAsTheOldDriveSentThem.count) \
                    bytes of bare tenancy as an opening. If that were so, the conformance target's \
                    post-upgrade probe would be a knock, and this scenario would have no point.
                    """)
                }
            },
            defineCheck("it answers with a message of its own") { _, _, _ in
                guard w.peerCouldRead else {
                    throw BrineStepError("a correctly speaking peer could not read a 32-byte opening: \(w.peerReadError)")
                }
                guard !w.peerReply.isEmpty else {
                    throw BrineStepError("the peer read the opening and then said nothing, so an opening is not what makes a peer speak")
                }
            },
        ]
    }
}
