import XCTest
import Foundation
import BrineSwiftCore

/// Brine driver for `features/the-recorder-page-is-rendered-and-held-to-its-words.feature`
/// (Step 10 of the pocket delivery plan).
///
/// EVERY STEP READS REAL FILES — the shipped `App/DeviceScreen.swift`, the shipped proof
/// mount, the shipped UI proof, and the shipped `scripts/ci-gates.sh`. Nothing here is
/// injected, because there is nothing to inject: the subject of this feature is the source
/// of a target `swift test` cannot compile, and the gate is only worth having if it reads
/// what actually ships.
///
/// WHY A SOURCE GATE AND A SIMULATOR RUN ARE BOTH NEEDED, AND NEITHER SUFFICES.
/// The simulator run is the proof a person can look at; it is what "never ship UI without
/// simulator proof" actually means. But a proof that is not wired into the build runs when
/// somebody remembers, which is the habit this step exists to replace. This gate holds the
/// wiring: it fails if the page's states stop being mounted, if the proof stops taking a
/// picture, or if `ci-gates.sh` stops asking for it.
final class RecorderPageRenderedFeatureTests: XCTestCase {

    private final class World: @unchecked Sendable {
        var states: [String] = []
        /// type name → its declaration body, comments stripped, strings intact.
        var bodies: [(type: String, file: String, body: String)] = []
    }

    func testTheRecorderPageIsRenderedAndHeldToItsWords() async throws {
        let world = World()

        let result = try await BrineFeatureRunner.run(
            "the-recorder-page-is-rendered-and-held-to-its-words",
            registry: StepRegistry([

                // MARK: - the pictures

                defineStep("the states the recorder page can be in") { ctx, _, _ in
                    world.states = try RecorderPageSurface.proofStates()
                    return ctx
                },

                defineStep("the build takes a picture of every one of them") { ctx, _, _ in
                    guard RecorderPageSurface.exists(RecorderPageSurface.proofTestFile) else {
                        throw BrineStepError(
                            "\(RecorderPageSurface.proofTestFile) does not exist, so no state "
                                + "of the recorder page is photographed by any build")
                    }
                    let proof = try RecorderPageSurface.text(of: RecorderPageSurface.proofTestFile)
                    // THE PICTURE ITSELF. Deleting the render call is the stated mutation for
                    // this criterion, and this is the assertion it must break.
                    guard proof.contains("XCTAttachment(screenshot:") else {
                        throw BrineStepError(
                            "\(RecorderPageSurface.proofTestFile) attaches no screenshot — the "
                                + "proof runs and leaves nothing a person can look at")
                    }
                    // EVERY state, by name, IN BOTH DIRECTIONS. A proof that visits two of
                    // three states is a proof of two states and the third ships unseen; and a
                    // page whose states are only the ones somebody remembered to photograph is
                    // a gate that shrinks with its subject. Measured: with only the first
                    // direction, deleting `errandRunning` from the enum left this green.
                    let opened = try RecorderPageSurface.statesTheProofOpens()
                    let missing = world.states.filter { !opened.contains($0) }
                    guard missing.isEmpty else {
                        throw BrineStepError(
                            "the recorder page can be in \(world.states.count) state(s) and the "
                                + "proof never visits: " + missing.joined(separator: ", "))
                    }
                    let unknown = opened.filter { !world.states.contains($0) }
                    guard unknown.isEmpty else {
                        throw BrineStepError(
                            "the proof photographs state(s) the recorder page cannot be in: "
                                + unknown.joined(separator: ", "))
                    }
                    // And every state must be MOUNTABLE — a name the proof passes to an app
                    // that does not mount it renders whatever the app falls back to.
                    let mount = try RecorderPageSurface.text(of: RecorderPageSurface.proofFile)
                    let unmounted = world.states.filter { !mount.contains($0) }
                    guard unmounted.isEmpty else {
                        throw BrineStepError(
                            "no mount for: " + unmounted.joined(separator: ", "))
                    }
                    return ctx
                },

                defineStep("the build is told to take those pictures on every run") { ctx, _, _ in
                    let gates = try RecorderPageSurface.text(of: RecorderPageSurface.gatesScript)
                    // The phase that runs the app on a simulator, and nothing else. A
                    // mention anywhere in the file would pass on a comment.
                    guard let phase = RecorderPageSurface.shellFunctionBody("phase_uiproof",
                                                                           in: gates) else {
                        throw BrineStepError("scripts/ci-gates.sh has no phase_uiproof")
                    }
                    guard phase.contains("RecorderPageProofUITests") else {
                        throw BrineStepError(
                            "phase_uiproof never runs RecorderPageProofUITests — the pictures "
                                + "of the recorder page are taken only when somebody remembers")
                    }
                    return ctx
                },

                defineStep("there is at least one state to take a picture of") { ctx, _, _ in
                    guard !world.states.isEmpty else {
                        throw BrineStepError(
                            "the recorder page declares no states, so \"a picture of every "
                                + "state\" is satisfied by taking none")
                    }
                    return ctx
                },

                // MARK: - the words and the colours

                defineStep("the recorder page as it is written") { ctx, _, _ in
                    world.bodies = []
                    for (type, file) in RecorderPageSurface.renderedTypes {
                        guard RecorderPageSurface.exists(file) else {
                            throw BrineStepError("\(file) does not exist")
                        }
                        guard let body = RecorderPageSurface.declarationBody(
                            of: type, in: try RecorderPageSurface.text(of: file))
                        else {
                            throw BrineStepError(
                                "\(file) declares no \(type) — this gate would rule over "
                                    + "nothing and pass")
                        }
                        world.bodies.append((type, file, body))
                    }
                    guard !world.bodies.isEmpty else {
                        throw BrineStepError("no recorder-page source was read")
                    }
                    return ctx
                },

                defineStep("not one sentence a person reads is written into the page itself") { ctx, _, _ in
                    var offences: [String] = []
                    for entry in world.bodies {
                        for literal in RecorderPageSurface.stringLiterals(in: entry.body)
                        where RecorderPageSurface.isUserFacing(literal) {
                            offences.append("\(entry.file) \(entry.type): \"\(literal.value)\"")
                        }
                    }
                    guard offences.isEmpty else {
                        throw BrineStepError(
                            "\(offences.count) sentence(s) a person reads are written into the "
                                + "recorder page's own body, where no test can reach them:\n"
                                + offences.joined(separator: "\n"))
                    }
                    return ctx
                },

                defineStep("the page still says things that were written where they can be checked") { ctx, _, _ in
                    var total = 0
                    for entry in world.bodies {
                        total += RecorderPageSurface.presentationReferences(in: entry.body).count
                    }
                    guard total > 0 else {
                        throw BrineStepError(
                            "the recorder page renders no kit-owned sentence at all, so \"no "
                                + "sentence is written into the page\" passes on a page that "
                                + "says nothing")
                    }
                    return ctx
                },

                defineStep("not one colour is mixed on the page itself") { ctx, _, _ in
                    var offences: [String] = []
                    for entry in world.bodies {
                        for hit in RecorderPageSurface.mixedColours(in: entry.body) {
                            offences.append("\(entry.file) \(entry.type): …\(hit)…")
                        }
                    }
                    guard offences.isEmpty else {
                        throw BrineStepError(
                            "\(offences.count) colour(s) are named on the recorder page itself "
                                + "rather than taken from the design system:\n"
                                + offences.joined(separator: "\n"))
                    }
                    return ctx
                },

                defineStep("the page still paints colours that come from the design system") { ctx, _, _ in
                    var total = 0
                    for entry in world.bodies {
                        total += RecorderPageSurface.grainTokens(in: entry.body).count
                    }
                    guard total > 0 else {
                        throw BrineStepError(
                            "the recorder page paints no Grain token at all, so \"no colour is "
                                + "mixed on the page\" passes on a page that paints nothing")
                    }
                    return ctx
                },
            ]))

        // PIN THE POPULATION. The runner only asserts that nothing FAILED, so deleting a
        // scenario would otherwise leave this suite green and this whole step undone.
        XCTAssertEqual(result.passed, 3,
                       "the-recorder-page-is-rendered-and-held-to-its-words must run all 3 "
                           + "scenarios")
    }

}
