import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

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
        /// EVERY WAY ONE RECORDING CAN BE PLACED — all 27 combinations, derived from
        /// `PocketPresenceAnswer.allCases` rather than listed, so a fourth answer would widen
        /// this population instead of leaving a hole in it.
        var presences: [PocketRecordingPresence] = []
        /// The strip a recorder that answered every reading at one instant produces.
        var answeredStrip: RecordingDeviceReadingPresentation.ReadingStrip?
        /// The strip a recorder nobody has ever asked produces.
        var unaskedStrip: RecordingDeviceReadingPresentation.ReadingStrip?
        /// A connected record-then-sync recorder's page — the one with two bands.
        var recorderPage: RecordingDevicePagePresentation?
        /// A live device's page — the CONTROL, because it has no readings band at all.
        var streamPage: RecordingDevicePagePresentation?
    }

    private static let batteryLabel =
        RecordingDeviceReadingPresentation.label(for: .batteryLevel)
    private static let firmwareLabel =
        RecordingDeviceReadingPresentation.label(for: .firmwareVersion)

    /// A CONNECTED device that declared its charge and its firmware AND has answered them —
    /// the state the composition puts every live session in, and the state the duplicate was
    /// photographed in.
    private static func page(deviceClass shape: RecordingDeviceShape)
        -> RecordingDevicePagePresentation {
        let value = RecordingDeviceReadingPresentation.label(for: .batteryLevel)
        let declared: [String: String?] = [
            RecordingDeviceCapabilityKey.batteryLevel.rawValue: value,
            RecordingDeviceCapabilityKey.firmwareVersion.rawValue: value,
            RecordingDeviceCapabilityKey.offlineStorage.rawValue: String?.none,
        ]
        let readings = [
            RecordingDeviceCapabilityKey.batteryLevel.rawValue:
                RecordingDeviceReading(value: value, observedAt: observedAt),
            RecordingDeviceCapabilityKey.firmwareVersion.rawValue:
                RecordingDeviceReading(value: value, observedAt: observedAt),
        ]
        return RecordingDevicePage.resolve(
            RecordingDeviceListInput(
                identity: RecordingDeviceIdentity(
                    shape: shape,
                    hardwareToken: "26079BC5-0000-4000-8000-000000000001"),
                displayName: value,
                declaredCapabilities: declared,
                link: .connected,
                isRemembered: true,
                readings: readings),
            now: now)
    }

    /// The instant every fixture in this file is dated from, and the instant they are rendered
    /// against. Fixed, because an age is the fact under test and a live clock would race it.
    private static let observedAt = Date(timeIntervalSince1970: 1_786_000_000)
    private static let now = observedAt.addingTimeInterval(20 * 60)

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

                // MARK: - the hierarchy

                defineStep("the bands the recorder page is laid out in") { ctx, _, _ in
                    guard RecorderPageLayout.bandsNotLaidOut.isEmpty else {
                        throw BrineStepError(
                            "the layout declares band(s) it never draws: "
                                + RecorderPageLayout.bandsNotLaidOut.map(\.rawValue)
                                    .joined(separator: ", ")
                                + " — a band that is named and not laid out is content that "
                                + "ships nowhere")
                    }
                    return ctx
                },

                defineStep("the list of recordings is the last band") { ctx, _, _ in
                    guard RecorderPageLayout.order.last == RecorderPageLayout.unboundedList else {
                        throw BrineStepError(
                            "the last band is "
                                + (RecorderPageLayout.order.last?.rawValue ?? "nothing")
                                + ", not the list of recordings. The list is the only band with "
                                + "no ceiling — it is a row per recording the recorder holds — "
                                + "so anything after it sits at a distance decided by somebody "
                                + "else's hardware")
                    }
                    return ctx
                },

                defineStep("every control is met before that list") { ctx, _, _ in
                    let below = RecorderPageLayout.controlsBelowTheList
                    guard below.isEmpty else {
                        throw BrineStepError(
                            "\(below.count) control band(s) are drawn below the list of "
                                + "recordings: " + below.map(\.rawValue).joined(separator: ", ")
                                + ". Nick's recorder was holding nineteen; a control under "
                                + "nineteen rows is a control he could not find")
                    }
                    return ctx
                },

                defineStep("there are controls to meet, and a list to meet them before") { ctx, _, _ in
                    guard !RecorderPageLayout.controls.isEmpty else {
                        throw BrineStepError(
                            "the layout names no controls, so \"every control is above the "
                                + "list\" is satisfied by a page with nothing to tap")
                    }
                    guard RecorderPageLayout.position(of: RecorderPageLayout.unboundedList) != nil
                    else {
                        throw BrineStepError(
                            "the layout does not draw the list at all, so \"every control is "
                                + "above the list\" is satisfied by a page with no list")
                    }
                    return ctx
                },

                defineStep("the page draws its bands in the order that was decided, and draws every one of them") { ctx, _, _ in
                    guard try RecorderPageSurface.viewWalksTheDecidedOrder() else {
                        throw BrineStepError(
                            "\(RecorderPageSurface.pageFile) does not walk "
                                + "`RecorderPageLayout.order` — the order above is a decision "
                                + "nothing obeys, and the page's real order is eleven "
                                + "statements in a VStack that no test in this repository can "
                                + "compile")
                    }
                    let drawn = try RecorderPageSurface.bandsTheViewDraws()
                    let missing = RecorderPageLayout.order.map(\.rawValue)
                        .filter { !drawn.contains($0) }
                    guard missing.isEmpty else {
                        throw BrineStepError(
                            "the page walks the decided order but draws nothing for: "
                                + missing.joined(separator: ", "))
                    }
                    return ctx
                },

                // MARK: - the repetition, in a row

                defineStep("every way one recording can be placed") { ctx, _, _ in
                    var all: [PocketRecordingPresence] = []
                    for r in PocketPresenceAnswer.allCases {
                        for p in PocketPresenceAnswer.allCases {
                            for s in PocketPresenceAnswer.allCases {
                                all.append(PocketRecordingPresence(
                                    onRecorder: PocketPlaceReading(answer: r,
                                                                   observedAt: Self.observedAt),
                                    onThisPhone: PocketPlaceReading(answer: p,
                                                                    observedAt: Self.observedAt),
                                    safeElsewhere: PocketPlaceReading(answer: s,
                                                                      observedAt: Self.observedAt)))
                            }
                        }
                    }
                    guard all.count == 27 else {
                        throw BrineStepError("the population is \(all.count), not 27 — this "
                                                + "scenario is not ruling over every placement")
                    }
                    world.presences = all
                    return ctx
                },

                defineStep("each row names each of the three places exactly once") { ctx, _, _ in
                    let expected = [PocketPresencePresentation.onRecorderShortPlace,
                                    PocketPresencePresentation.onThisPhoneShortPlace,
                                    PocketPresencePresentation.safeElsewhereShortPlace]
                    for presence in world.presences {
                        let places = PocketPresencePresentation
                            .block(presence, now: Self.now).chips.map(\.place)
                        guard places == expected else {
                            throw BrineStepError(
                                "a row names \(places) — it must name each of the three places "
                                    + "once and in order: \(expected). None of the three may be "
                                    + "dropped: they are the evidence that deleting a recording "
                                    + "is safe")
                        }
                    }
                    return ctx
                },

                defineStep("no row states the same fact twice") { ctx, _, _ in
                    for presence in world.presences {
                        let lines = PocketPresencePresentation.rowLines(presence, now: Self.now)
                        guard Set(lines).count == lines.count else {
                            throw BrineStepError("a row says \(lines) — something is in there "
                                                    + "twice")
                        }
                        // AND THE SUMMARY IS NOT ONE OF THEM. `label(_:)` is these same three
                        // readings said again in prose, and it sitting above them is exactly
                        // what Nick was shown: "Only on the recorder" followed by the three
                        // lines it was derived from.
                        let summary = PocketPresencePresentation.label(presence)
                        guard !lines.contains(summary) else {
                            throw BrineStepError(
                                "a row states the derived summary \"\(summary)\" beside the "
                                    + "three readings it is derived from")
                        }
                    }
                    return ctx
                },

                defineStep("the age they share is stated once, not once per place") { ctx, _, _ in
                    let shortPlaces = [PocketPresencePresentation.onRecorderShortPlace,
                                       PocketPresencePresentation.onThisPhoneShortPlace,
                                       PocketPresencePresentation.safeElsewhereShortPlace]
                    // ONE INSTANT FOR ALL THREE — the ordinary case, because one check reads
                    // all three places at once. The age must appear as ONE clause, which means
                    // it names no place at all.
                    let together = PocketRecordingPresence(
                        onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.observedAt),
                        onThisPhone: PocketPlaceReading(answer: .no, observedAt: Self.observedAt),
                        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: Self.observedAt))
                    guard let shared = PocketPresencePresentation
                        .block(together, now: Self.now).ageLine else {
                        throw BrineStepError("three places read at one instant state no age at "
                                                + "all — the age is a fact, not decoration")
                    }
                    for place in shortPlaces where shared.contains(place) {
                        throw BrineStepError(
                            "the shared age reads \"\(shared)\" — it names \(place), so it is "
                                + "being said once per place after all")
                    }
                    // AND THE OTHER DIRECTION, so "state one age" is not satisfied by throwing
                    // the differing ones away. A place read at a different instant is named.
                    let apart = PocketRecordingPresence(
                        onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.observedAt),
                        onThisPhone: PocketPlaceReading(
                            answer: .yes, observedAt: Self.observedAt.addingTimeInterval(-86_400)),
                        safeElsewhere: PocketPlaceReading(answer: .no,
                                                         observedAt: Self.observedAt))
                    guard let differing = PocketPresencePresentation
                        .block(apart, now: Self.now).ageLine else {
                        throw BrineStepError("places read at different instants state no age")
                    }
                    for place in shortPlaces where !differing.contains(place) {
                        throw BrineStepError(
                            "the ages read \"\(differing)\" and do not name \(place) — a place "
                                + "whose reading is a day older than the others has had its own "
                                + "age dropped")
                    }
                    // AND A ROW NOBODY ASKED ANYTHING STATES NO AGE, because every chip already
                    // reads Unknown and a fourth line saying so is the defect this closes.
                    guard PocketPresencePresentation
                        .block(.nothingAsked, now: Self.now).ageLine == nil else {
                        throw BrineStepError("a row nobody asked states an age")
                    }
                    return ctx
                },

                defineStep("the page renders that one statement about where a recording is, and no second one") { ctx, _, _ in
                    guard let body = RecorderPageSurface.declarationBody(
                        of: "RecordingDevicePageView",
                        in: try RecorderPageSurface.text(of: RecorderPageSurface.pageFile))
                    else {
                        throw BrineStepError("\(RecorderPageSurface.pageFile) declares no "
                                                + "RecordingDevicePageView")
                    }
                    let rendered = RecorderPageSurface.presenceFieldsRendered(in: body)
                    guard !rendered.isEmpty else {
                        throw BrineStepError(
                            "the shelf row states nothing about where the recording is, so "
                                + "\"nothing is said twice\" passes on a row that says nothing")
                    }
                    guard rendered.count == 1 else {
                        throw BrineStepError(
                            "one shelf row renders \(rendered.count) separate statements of "
                                + "where the recording is: " + rendered.joined(separator: " + ")
                                + ". Each is derived from the same three readings, so the row "
                                + "says the same thing two ways")
                    }
                    return ctx
                },

                // MARK: - the repetition, one band apart

                defineStep("a connected recorder that declared its charge and its firmware and answered them") { ctx, _, _ in
                    world.recorderPage = Self.page(deviceClass: .filePull)
                    world.streamPage = Self.page(deviceClass: .bleStream)
                    return ctx
                },

                defineStep("the readings state its charge and its firmware") { ctx, _, _ in
                    guard let page = world.recorderPage else {
                        throw BrineStepError("no recorder page was resolved")
                    }
                    // PAIRED EXISTENCE. "The strip does not repeat the readings" is trivially
                    // true of a page with no readings, which is the shape of this defect's
                    // opposite.
                    let read = page.readings.filter(\.wasRead).map(\.label)
                    for label in [Self.batteryLabel, Self.firmwareLabel] where !read.contains(label) {
                        throw BrineStepError(
                            "the readings state \(read) and not \(label), so \"the strip does "
                                + "not state it again\" is a claim about nothing")
                    }
                    return ctx
                },

                defineStep("the capability strip states neither of them again") { ctx, _, _ in
                    guard let page = world.recorderPage else {
                        throw BrineStepError("no recorder page was resolved")
                    }
                    let strip = page.capabilities.map(\.label)
                    for label in [Self.batteryLabel, Self.firmwareLabel] where strip.contains(label) {
                        throw BrineStepError(
                            "the capability strip states \(label) as well as the readings — one "
                                + "number, twice, within one screen height. The strip reads "
                                + "\(strip)")
                    }
                    return ctx
                },

                defineStep("the strip still states what only it knows") { ctx, _, _ in
                    guard let page = world.recorderPage else {
                        throw BrineStepError("no recorder page was resolved")
                    }
                    // THE OTHER DIRECTION: the subtraction must remove the REPEAT, never the
                    // strip. Offline storage is a class fact no reading carries.
                    guard !page.capabilities.isEmpty else {
                        throw BrineStepError(
                            "the capability strip is empty — the exclusion took the whole strip "
                                + "rather than the two keys another band already states")
                    }
                    return ctx
                },

                defineStep("a device with no readings band keeps its charge in the strip") { ctx, _, _ in
                    guard let page = world.streamPage else {
                        throw BrineStepError("no live-device page was resolved")
                    }
                    guard page.readings.isEmpty else {
                        throw BrineStepError(
                            "the live device has a readings band after all, so it is the wrong "
                                + "control for this claim")
                    }
                    guard page.capabilities.map(\.label).contains(Self.batteryLabel) else {
                        throw BrineStepError(
                            "a device whose only home for its charge is the capability strip "
                                + "lost it: the strip reads \(page.capabilities.map(\.label)). "
                                + "The subtraction is conditional on the other band existing, "
                                + "and this is the device it does not exist for")
                    }
                    return ctx
                },

                // MARK: - the repetition, one band higher

                defineStep("a recorder that answered every reading at one moment") { ctx, _, _ in
                    var answered: [String: RecordingDeviceReading] = [:]
                    for key in RecordingDeviceReadingPresentation.order {
                        answered[key.rawValue] = RecordingDeviceReading(value: key.rawValue,
                                                                        observedAt: Self.observedAt)
                    }
                    world.answeredStrip = RecordingDeviceReadingPresentation.strip(
                        RecordingDeviceReadingPresentation.lines(answered, now: Self.now))
                    world.unaskedStrip = RecordingDeviceReadingPresentation.strip(
                        RecordingDeviceReadingPresentation.lines([:], now: Self.now))
                    guard let answeredStrip = world.answeredStrip,
                          !answeredStrip.isEmpty,
                          answeredStrip.read.count > 1 else {
                        throw BrineStepError(
                            "the answered strip carries fewer than two readings, so \"one age "
                                + "instead of one per fact\" is a distinction with no subject")
                    }
                    return ctx
                },

                defineStep("the strip states that moment once") { ctx, _, _ in
                    guard let strip = world.answeredStrip else {
                        throw BrineStepError("no answered strip was built")
                    }
                    // PAIRED EXISTENCE: the lines really were read at one instant, so a shared
                    // age is the honest compression and not a fact being flattened away.
                    let ages = Set(strip.read.compactMap(\.observedAgo))
                    guard ages.count == 1 else {
                        throw BrineStepError("the fixture's readings carry \(ages.count) "
                                                + "different ages — it does not state one moment")
                    }
                    guard strip.sharedAge == ages.first else {
                        throw BrineStepError(
                            "\(strip.read.count) readings taken at one instant state "
                                + "\(strip.sharedAge.map { "\"\($0)\"" } ?? "no shared age") — "
                                + "so the page draws \(strip.read.count) copies of one moment")
                    }
                    return ctx
                },

                defineStep("a recorder nobody has asked is offered one way to ask, not one for every fact") { ctx, _, _ in
                    guard let strip = world.unaskedStrip else {
                        throw BrineStepError("no unasked strip was built")
                    }
                    guard strip.read.isEmpty, strip.unread.count > 1 else {
                        throw BrineStepError(
                            "the unasked strip carries \(strip.read.count) read and "
                                + "\(strip.unread.count) unasked lines — it is not the state "
                                + "this is about")
                    }
                    let actions = Set(strip.unread.compactMap(\.action))
                    guard actions.count == 1 else {
                        throw BrineStepError(
                            "the unasked facts offer \(actions.count) different actions, so "
                                + "there is no one way to ask to offer once")
                    }
                    guard strip.askAction == actions.first else {
                        throw BrineStepError(
                            "\(strip.unread.count) unasked facts each carry the same action and "
                                + "the strip offers "
                                + (strip.askAction.map { "\"\($0)\"" } ?? "none")
                                + " — the page draws that one errand \(strip.unread.count) times")
                    }
                    return ctx
                },

                defineStep("the strip still names every fact it has, asked or not") { ctx, _, _ in
                    let every = RecordingDeviceReadingPresentation.labels
                    for (what, strip) in [("answered", world.answeredStrip),
                                          ("unasked", world.unaskedStrip)] {
                        guard let strip else {
                            throw BrineStepError("no \(what) strip was built")
                        }
                        let named = strip.read.map(\.label) + strip.unread.map(\.label)
                        guard Set(named) == Set(every) else {
                            throw BrineStepError(
                                "the \(what) strip names \(named) and the recorder has \(every) "
                                    + "— compressing the strip must not drop a fact from it")
                        }
                    }
                    return ctx
                },

                defineStep("the page renders the strip that was compressed rather than a line for every reading") { ctx, _, _ in
                    guard try RecorderPageSurface.viewRendersTheCompressedStrip() else {
                        throw BrineStepError(
                            "\(RecorderPageSurface.pageFile) never calls "
                                + "`RecordingDeviceReadingPresentation.strip(` — the "
                                + "compression above is a decision the page does not render, "
                                + "and the page still draws one row, one age and one button per "
                                + "reading")
                    }
                    return ctx
                },
            ]))

        // PIN THE POPULATION. The runner only asserts that nothing FAILED, so deleting a
        // scenario would otherwise leave this suite green and this whole step undone.
        XCTAssertEqual(result.passed, 7,
                       "the-recorder-page-is-rendered-and-held-to-its-words must run all 7 "
                           + "scenarios")
    }

}
