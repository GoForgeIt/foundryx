import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/one-recording-is-something-i-can-open.feature`.
///
/// TWO KINDS OF STEP, AND BOTH ARE NEEDED HERE.
///
///   * The DECISIONS run against the shipped `PocketRecordingDetailPresentation` — which of the
///     two actions one recording admits, and the sentence explaining the one it does not. Those
///     are values, so they are held over populations rather than over examples: the removal
///     rule is checked against all 27 ways one recording can be placed, and the withheld-reason
///     rule against every `BrainChoice`.
///   * The AFFORDANCE runs against the source of `App/DeviceScreen.swift`, because `swift test`
///     compiles the SPM package and cannot compile `App/`. "The row is something a person can
///     press" is a fact about a SwiftUI body, and the only way this suite can reach a SwiftUI
///     body is to read it. That is the same mechanism `RecorderPageRenderedFeatureTests` and
///     `DeviceCompositionRootGateTests` already use, and it exists for the same reason: the
///     row shipped with no control on it and 1545 green tests could not say so.
final class OneRecordingIsSomethingICanOpenFeatureTests: XCTestCase {

    // MARK: - The fixture, and it is the measured device

    /// `PKT01_BLUE_26079bc5`, firmware 1.6, read 2026-08-16 — including the two timestamp
    /// spellings that coexist on ONE unit, because the page's whole identity claim is that the
    /// recorder's own name for a file reaches the wire untouched.
    private static let recordings: [PocketRecording] = [
        PocketRecording(date: "2026-08-11", timestamp: "PH260811175026", sizeBytes: 2_764_000),
        PocketRecording(date: "2026-08-07", timestamp: "20260807142852", sizeBytes: 14_400_000),
        PocketRecording(date: "2026-08-07", timestamp: "20260807093015", sizeBytes: 480_000),
    ]

    private static let listedAt = Date(timeIntervalSince1970: 1_786_000_000)
    /// An hour after the listing, so "each place carries its own age" is a statement with a
    /// value rather than three copies of "just now".
    private static let now = listedAt.addingTimeInterval(3_600)

    /// On the recorder, and nowhere Solleva has proved. The state all nineteen of Nick's
    /// recordings are actually in.
    private static let onlyOnTheRecorder = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: listedAt),
        onThisPhone: PocketPlaceReading(answer: .no, observedAt: listedAt),
        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: listedAt))

    private static let provenElsewhere = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: listedAt),
        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: listedAt),
        safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: listedAt))

    /// Held here, not proved anywhere else. The state a bring-over lands a recording in.
    private static let onThisPhoneOnly = PocketRecordingPresence(
        onRecorder: PocketPlaceReading(answer: .yes, observedAt: listedAt),
        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: listedAt),
        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: listedAt))

    /// EVERY WAY ONE RECORDING CAN BE PLACED — derived from `PocketPresenceAnswer.allCases`
    /// rather than listed, so a fourth answer widens this population instead of leaving a hole
    /// in it. The same construction `RecorderPageRenderedFeatureTests` uses.
    private static var everyPlacement: [PocketRecordingPresence] {
        var out: [PocketRecordingPresence] = []
        for r in PocketPresenceAnswer.allCases {
            for p in PocketPresenceAnswer.allCases {
                for s in PocketPresenceAnswer.allCases {
                    out.append(PocketRecordingPresence(
                        onRecorder: PocketPlaceReading(answer: r, observedAt: listedAt),
                        onThisPhone: PocketPlaceReading(answer: p, observedAt: listedAt),
                        safeElsewhere: PocketPlaceReading(answer: s, observedAt: listedAt)))
                }
            }
        }
        return out
    }

    private final class World: @unchecked Sendable {
        var page: PocketRecordingDetailPage?
        var recording: PocketRecording?
        var presence: PocketRecordingPresence?
        var bodies: [String] = []
    }

    func testOneRecordingIsSomethingICanOpenFeature() async throws {
        let world = World()
        let result = try await BrineFeatureRunner.run(
            "one-recording-is-something-i-can-open",
            registry: StepRegistry(Self.steps(world)))
        XCTAssertEqual(result.passed, 7)
    }

    /// THE FIX, MEASURED RATHER THAN ASSERTED — over the state Nick's page is actually in.
    ///
    /// WHAT THIS TEST USED TO SAY, AND WHY IT WAS RIGHT THEN. It asserted `offered.count == 0`
    /// over the nineteen, because the row's only control was `isOffered` and `isOffered` was
    /// `isDurableElsewhere`. That arithmetic was the DEFECT being measured: nineteen rows, not
    /// one of them touchable.
    ///
    /// NICK RULED ON 2026-08-18 — *"we cannot hard block them from deleting"* — so the same
    /// arithmetic now measures the fix. It is not a weakened assertion: it is the same
    /// computation over the same fixture, with the number that makes the page usable rather than
    /// the number that made it a readout. Nineteen recordings, nineteen controls.
    func testEveryRecordingOnTheMeasuredDeviceNowHasAControl() {
        let nineteen = Array(repeating: Self.onlyOnTheRecorder, count: 19)
        let offered = nineteen.filter { PocketRemoveFromRecorderPresentation.isOffered(for: $0) }
        XCTAssertEqual(offered.count, 19,
                       "a recorder that is full and cannot be emptied is a recorder that cannot "
                           + "record — every recording the recorder is holding is the owner's to "
                           + "take off it")
        // AND THE PREDICATE IS NOT `true`. Without this, "all nineteen" is satisfied by a
        // function that returns yes to everything and the affordance could not fail.
        XCTAssertFalse(PocketRemoveFromRecorderPresentation.isOffered(
            for: PocketRecordingPresence(
                onRecorder: PocketPlaceReading(answer: .no, observedAt: Self.listedAt),
                onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt),
                safeElsewhere: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt))),
                       "a recording the recorder answered NO about was still offered removal")
        // AND THE UNATTENDED PATH DID NOT MOVE WITH IT. This is the pair: the ruling relaxed one
        // of the two paths, and the single most likely wrong fix relaxes both.
        XCTAssertEqual(
            nineteen.filter(PocketRemoveFromRecorderPresentation.autoClearMayTake).count, 0,
            "the armed clear would take a recording nobody proved is anywhere else")
        XCTAssertTrue(
            PocketRemoveFromRecorderPresentation.autoClearMayTake(Self.provenElsewhere))
    }

    // MARK: - Steps

    private static func steps(_ world: World) -> [StepDefinition] {
        [
            // MARK: the row is a control

            defineStep("the list of recordings as the recorder page draws it") { ctx, _, _ in
                guard RecorderPageSurface.exists(RecorderPageSurface.pageFile) else {
                    throw BrineStepError("\(RecorderPageSurface.pageFile) does not exist")
                }
                guard let row = try RecorderPageSurface.shelfRowBody(), !row.isEmpty else {
                    throw BrineStepError(
                        "the page draws no row per listed recording — this gate would rule "
                            + "over nothing and pass")
                }
                world.bodies = [row]
                return ctx
            },

            defineStep("the row itself is the control, not something buried inside it") { ctx, _, _ in
                guard let first = try RecorderPageSurface.firstElementOfTheShelfRow() else {
                    throw BrineStepError("the shelf row's content could not be read")
                }
                guard first == "Button" else {
                    throw BrineStepError(
                        "the shelf row opens with `\(first)`, not `Button`. On the measured "
                            + "device the row's only interactive element was gated on a "
                            + "predicate false for all nineteen recordings, so the row itself "
                            + "has to be what the finger presses")
                }
                return ctx
            },

            defineStep("pressing it opens the page about that one recording") { ctx, _, _ in
                let row = world.bodies.first ?? ""
                // THE ROW CARRIES THE RECORDER'S OWN ID INTO THE STATE THE SHEET READS. A
                // `Button` that set nothing, or that set a row INDEX, would satisfy "the row is
                // a control" and would open the wrong recording the moment the shelf reorders.
                guard row.contains("inspecting = row.id") else {
                    throw BrineStepError(
                        "the row's button does not carry `row.id` into the opened page. The "
                            + "recorder spells its timestamps two ways on one device and the "
                            + "shelf reorders as files land, so anything but the recorder's own "
                            + "name for the file opens a different recording than the one under "
                            + "the finger")
                }
                let page = try RecorderPageSurface.text(of: RecorderPageSurface.pageFile)
                guard let body = RecorderPageSurface.declarationBody(
                    of: "RecordingDevicePageView", in: page) else {
                    throw BrineStepError("the page declares no RecordingDevicePageView")
                }
                let code = AppSourceTree.code(of: body)
                guard code.contains("PocketRecordingDetailSheet(") else {
                    throw BrineStepError(
                        "nothing on the recorder page presents `PocketRecordingDetailSheet`, so "
                            + "the row is a button that opens nothing")
                }
                guard code.contains("check.detailPage(for:") else {
                    throw BrineStepError(
                        "the opened page is not resolved from the check model's shelf reading, "
                            + "so it is not a statement about the recording the row was drawn "
                            + "from")
                }
                return ctx
            },

            defineStep("there is a row to press, and a page for it to open") { ctx, _, _ in
                guard RecorderPageSurface.declarationBody(
                    of: "PocketRecordingDetailSheet",
                    in: try RecorderPageSurface.text(of: RecorderPageSurface.pageFile)) != nil
                else {
                    throw BrineStepError(
                        "`PocketRecordingDetailSheet` is not declared, so every claim above is "
                            + "about a screen that does not exist")
                }
                // AND THE ACTIONS IT CAN OFFER ARE A POPULATION, not one remembered case.
                guard PocketRecordingDetailAction.allCases.count >= 2 else {
                    throw BrineStepError(
                        "the page about one recording offers fewer than two kinds of action, "
                            + "so \"it offers what the recording admits\" is nearly vacuous")
                }
                return ctx
            },

            // MARK: what the page states

            defineStep("a recording the recorder listed an hour ago, which Solleva has not brought over") { ctx, _, _ in
                let recording = Self.recordings[0]
                world.recording = recording
                world.presence = Self.onlyOnTheRecorder
                world.page = PocketRecordingDetailPresentation.page(
                    for: recording, presence: Self.onlyOnTheRecorder,
                    brain: .myComputer, now: Self.now)
                return ctx
            },

            defineStep("the page about it names all three places, each with its own age") { ctx, _, _ in
                guard let page = world.page else { throw BrineStepError("no page was built") }
                let expected = [PocketPresencePresentation.onRecorderPlace,
                                PocketPresencePresentation.onThisPhonePlace,
                                PocketPresencePresentation.safeElsewherePlace]
                guard page.places.map(\.place) == expected else {
                    throw BrineStepError(
                        "the page names \(page.places.map(\.place)) rather than the three "
                            + "places — the three are the evidence that removing a recording is "
                            + "safe, so none of them may be dropped")
                }
                for line in page.places {
                    guard !line.age.trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw BrineStepError(
                            "\(line.place) states no age. An answer with no age is a fact with "
                                + "no expiry, which is how a stale reading gets acted on")
                    }
                }
                // THE AGE IS THE READING'S, NOT THE DRAW'S. Listed an hour ago, rendered now.
                guard page.places.allSatisfy({ $0.age == PocketPresencePresentation.age(
                    Self.listedAt, now: Self.now) }) else {
                    throw BrineStepError(
                        "the ages read \(page.places.map(\.age)) — they are not the age of the "
                            + "reading the page was built from")
                }
                // AND A PLACE NOBODY ASKED SAYS SO, so "every place has an age" is not
                // satisfied by inventing one for a question nobody put.
                let unasked = PocketRecordingDetailPresentation.page(
                    for: Self.recordings[0], presence: .nothingAsked,
                    brain: .myComputer, now: Self.now)
                guard unasked.places.allSatisfy({
                    $0.age == PocketPresencePresentation.neverCheckedAge
                }) else {
                    throw BrineStepError(
                        "a recording nobody has asked about carries ages "
                            + "\(unasked.places.map(\.age)) rather than saying nobody checked")
                }
                return ctx
            },

            defineStep("it states the size and the date the recorder itself reported") { ctx, _, _ in
                guard let page = world.page, let recording = world.recording else {
                    throw BrineStepError("no page was built")
                }
                let size = page.facts.first {
                    $0.label == PocketRecordingDetailPresentation.sizeLabel
                }
                guard let size else {
                    throw BrineStepError("the page states no size")
                }
                guard size.value == StoredFileDevicePresentation
                    .extent(sizeBytes: recording.sizeBytes) else {
                    throw BrineStepError(
                        "the size reads \"\(size.value)\", which is not the recorder's own "
                            + "figure. The row that divided these bytes by an unmeasured 4,000 "
                            + "bytes/second printed \"44 min\" on all nineteen")
                }
                guard !PocketMeasuredFigures.shelfRowMayStateDuration else {
                    throw BrineStepError(
                        "the fabricated duration has been re-admitted; this page would state it")
                }
                // THE DATE IS THE HEADING, NOT A LABELLED FACT — see the next step. A recording
                // on a recorder has no name but its instant, and the first simulator run of
                // this page rendered that instant as the title AND as a `Recorded` row four
                // lines under it.
                guard page.title == PocketRecordingLabel.title(
                    date: recording.date, timestamp: recording.timestamp) else {
                    throw BrineStepError(
                        "the page is headed \"\(page.title)\", which is not the instant the "
                            + "recorder reported re-spaced — it has been re-interpreted")
                }
                return ctx
            },

            defineStep("it never states one fact twice, one band apart") { ctx, _, _ in
                guard let page = world.page else { throw BrineStepError("no page was built") }
                guard page.factsNeverRepeatTheHeading else {
                    throw BrineStepError(
                        "the page repeats itself: heading \"\(page.title)\", facts "
                            + "\(page.facts.map { "\($0.label)=\($0.value)" }). This is the "
                            + "defect the band above already has a gate for — one number, "
                            + "twice, within one screen height")
                }
                // NON-VACUITY, IN BOTH DIRECTIONS. The rule must be able to say no, and the
                // page must have facts for it to rule over.
                guard !page.facts.isEmpty else {
                    throw BrineStepError("the page states no facts, so nothing can repeat")
                }
                let repeated = PocketRecordingDetailPage(
                    fileToken: page.fileToken, title: page.title,
                    facts: page.facts + [PocketRecordingDetailFact(
                        label: PocketRecordingDetailPresentation.sizeLabel, value: page.title)],
                    places: page.places, actions: page.actions, notes: page.notes)
                guard !repeated.factsNeverRepeatTheHeading else {
                    throw BrineStepError(
                        "a page whose fact restates its own heading passes this rule, so the "
                            + "rule cannot fail")
                }
                return ctx
            },

            defineStep("it names the recording the way the recorder names it") { ctx, _, _ in
                guard let page = world.page, let recording = world.recording else {
                    throw BrineStepError("no page was built")
                }
                guard page.fileToken == recording.date + "/" + recording.timestamp else {
                    throw BrineStepError(
                        "the page carries \"\(page.fileToken)\" rather than the recorder's own "
                            + "name for the file. Both a bring-over and a removal put this on "
                            + "the wire")
                }
                // AND A PERSON CAN READ IT. THIS HALF WAS MISSING AND A MUTATION WALKED PAST
                // THE GATE: deleting the `The recorder calls it` fact entirely left this suite
                // green, because `fileToken` is the machine's handle and nothing here asked
                // whether the page SHOWS it. It is the string somebody reads back down a phone
                // when a transfer goes wrong, and one device spells it two ways.
                guard page.facts.contains(where: {
                    $0.label == PocketRecordingDetailPresentation.recorderNameLabel
                        && $0.value == page.fileToken
                }) else {
                    throw BrineStepError(
                        "the page does not SHOW the recorder's own name for the file — its "
                            + "facts are \(page.facts.map(\.label))")
                }
                // BOTH SPELLINGS THIS ONE DEVICE USES, carried through untouched. The prefixed
                // form is nine of the nineteen on the measured unit.
                let prefixed = Self.recordings[0]
                let bare = Self.recordings[1]
                guard prefixed.timestamp.hasPrefix("PH"), !bare.timestamp.hasPrefix("PH") else {
                    throw BrineStepError("the fixture no longer covers both spellings")
                }
                for recording in [prefixed, bare] {
                    let built = PocketRecordingDetailPresentation.page(
                        for: recording, presence: Self.onlyOnTheRecorder,
                        brain: .myComputer, now: Self.now)
                    guard built.fileToken.hasSuffix(recording.timestamp) else {
                        throw BrineStepError(
                            "\(recording.timestamp) was normalised on its way onto the page")
                    }
                }
                return ctx
            },

            defineStep("it never states where the recording is twice") { ctx, _, _ in
                guard let page = world.page else { throw BrineStepError("no page was built") }
                // THE DEFECT THIS FORBIDS, on the page one band up: the row drew
                // `presenceLabel` — a summary DERIVED from the three places — directly above
                // the three places it is derived from. Four lines, three facts, nineteen times.
                let summaries = [PocketPresencePresentation.inSollevaLabel,
                                 PocketPresencePresentation.onlyOnRecorderLabel,
                                 PocketPresencePresentation.phoneNotCheckedLabel,
                                 PocketPresencePresentation.onThisPhoneOnlyLabel,
                                 PocketPresencePresentation.safeElsewhereLabel]
                var rendered = page.notes + page.facts.map(\.value) + page.facts.map(\.label)
                rendered.append(page.title)
                rendered += page.places.map(PocketPresencePresentation.oneLine)
                for summary in summaries where rendered.contains(where: { $0.contains(summary) }) {
                    throw BrineStepError(
                        "the page states \"\(summary)\" as well as the three places it is "
                            + "derived from — the same fact twice, which is exactly what the "
                            + "shelf row's own gate exists to catch")
                }
                // AND IT DOES STATE THEM, so the prohibition is not satisfied by silence.
                guard page.places.count == 3 else {
                    throw BrineStepError("the page states \(page.places.count) places")
                }
                return ctx
            },

            // MARK: the removal gate

            defineStep("the page about it offers to take it off the recorder") { ctx, _, _ in
                guard let page = world.page else { throw BrineStepError("no page was built") }
                guard page.offers(.removeFromRecorder) else {
                    throw BrineStepError(
                        "a recording Solleva has not proved it holds anywhere else is refused "
                            + "removal. Nick's ruling, 2026-08-18: \"we cannot hard block them "
                            + "from deleting\" — on the phone-only tier that predicate is false "
                            + "forever, so this page had nineteen rows and no control")
                }
                return ctx
            },

            defineStep("it says what that would cost, instead of showing nothing") { ctx, _, _ in
                guard let page = world.page else { throw BrineStepError("no page was built") }
                // `onlyOnTheRecorder` — the recorder has it, this phone does not, nothing else
                // does. The one consequence where the recording simply ends.
                guard page.notes.contains(PocketDeleteConsequence.nothingElseHoldsIt.sentence)
                else {
                    throw BrineStepError(
                        "the page offers a deletion and says nothing about what it costs. The "
                            + "old rule withheld the control and explained the refusal; the new "
                            + "one offers the control, so the explanation is what it destroys — "
                            + "notes read \(page.notes)")
                }
                return ctx
            },

            defineStep("a recording Solleva has proved it holds elsewhere IS offered that action") { ctx, _, _ in
                let page = PocketRecordingDetailPresentation.page(
                    for: Self.recordings[0], presence: Self.provenElsewhere,
                    brain: .myComputer, now: Self.now)
                guard page.offers(.removeFromRecorder) else {
                    throw BrineStepError(
                        "no recording is ever offered removal, so the gate above is satisfied "
                            + "by a page that can never do anything")
                }
                return ctx
            },

            defineStep("over every way one recording can be placed, the page and the shelf row agree") { ctx, _, _ in
                var disagreements: [String] = []
                for presence in Self.everyPlacement {
                    let page = PocketRecordingDetailPresentation.page(
                        for: Self.recordings[0], presence: presence,
                        brain: .myComputer, now: Self.now)
                    // THE ROW'S PREDICATE, PLUS THE ONE FACT A ROW CANNOT ACT WITHOUT: the
                    // recorder saying it has the file. `unknown` satisfies neither side.
                    let rowWould = PocketRemoveFromRecorderPresentation.isOffered(for: presence)
                        && presence.onRecorder.answer == .yes
                    if page.offers(.removeFromRecorder) != rowWould {
                        disagreements.append(
                            "recorder=\(presence.onRecorder.answer.rawValue) "
                                + "phone=\(presence.onThisPhone.answer.rawValue) "
                                + "elsewhere=\(presence.safeElsewhere.answer.rawValue): "
                                + "page=\(page.offers(.removeFromRecorder)) row=\(rowWould)")
                    }
                }
                guard disagreements.isEmpty else {
                    throw BrineStepError(
                        "\(disagreements.count) of \(Self.everyPlacement.count) placements are "
                            + "answered differently by the page and by the shelf row:\n"
                            + disagreements.joined(separator: "\n"))
                }
                // NON-VACUITY: the population must contain both answers, or "they agree" is a
                // claim about a predicate that is constant.
                let offering = Self.everyPlacement.filter {
                    PocketRecordingDetailPresentation.page(
                        for: Self.recordings[0], presence: $0,
                        brain: .myComputer, now: Self.now).offers(.removeFromRecorder)
                }
                guard !offering.isEmpty, offering.count < Self.everyPlacement.count else {
                    throw BrineStepError(
                        "the removal is offered for \(offering.count) of "
                            + "\(Self.everyPlacement.count) placements — a constant, so "
                            + "\"they agree\" holds nothing")
                }
                return ctx
            },

            // MARK: choosing the one

            defineStep("a recorder holding three recordings and none of them yet in Solleva") { ctx, _, _ in
                world.presence = Self.onlyOnTheRecorder
                return ctx
            },

            defineStep("the page about every one of them offers to bring that one over") { ctx, _, _ in
                for recording in Self.recordings {
                    let page = PocketRecordingDetailPresentation.page(
                        for: recording, presence: Self.onlyOnTheRecorder,
                        brain: .myComputer, now: Self.now)
                    guard page.offers(.bringItOver) else {
                        throw BrineStepError(
                            "\(page.fileToken) cannot be asked for. The whole gap is that the "
                                + "owner could ask only for the comparator's pick")
                    }
                    guard page.fileToken == recording.date + "/" + recording.timestamp else {
                        throw BrineStepError(
                            "the page offers to bring over \(page.fileToken), which is not the "
                                + "recording it is about")
                    }
                }
                return ctx
            },

            defineStep("the one Solleva would have chosen on its own is only one of the three") { ctx, _, _ in
                guard let chosen = PocketBringOver.offered(Self.recordings) else {
                    throw BrineStepError("the shipped comparator elects nothing at all")
                }
                let token = PocketRecordingDetailPresentation.fileToken(chosen)
                let others = Self.recordings
                    .map(PocketRecordingDetailPresentation.fileToken)
                    .filter { $0 != token }
                guard others.count == 2 else {
                    throw BrineStepError(
                        "the fixture holds \(others.count + 1) recordings, so \"the owner can "
                            + "ask for one the comparator did not pick\" has nothing to prove")
                }
                for other in others {
                    guard let recording = Self.recordings.first(where: {
                        PocketRecordingDetailPresentation.fileToken($0) == other
                    }) else { throw BrineStepError("lost a recording") }
                    let page = PocketRecordingDetailPresentation.page(
                        for: recording, presence: Self.onlyOnTheRecorder,
                        brain: .myComputer, now: Self.now)
                    guard page.offers(.bringItOver) else {
                        throw BrineStepError(
                            "\(other) — which the comparator did NOT pick — still cannot be "
                                + "asked for, so nothing has changed")
                    }
                }
                return ctx
            },

            defineStep("asking for a recording the shelf cannot answer for is refused rather than guessed") { ctx, _, _ in
                let readings = Self.recordings.map { _ in Self.onlyOnTheRecorder }
                // A TOKEN THE LISTING DOES NOT HOLD.
                guard PocketRecordingDetailPresentation.located(
                    "2026-01-01/00000000000000", among: Self.recordings,
                    presences: readings) == nil else {
                    throw BrineStepError(
                        "an id the recorder never listed resolves to a recording — that is a "
                            + "removal aimed at whatever shares its position")
                }
                // NO READINGS AT ALL. Reachable: the listing is restated on every check while
                // the readings are restated only on a check that reached the recorder.
                guard PocketRecordingDetailPresentation.located(
                    PocketRecordingDetailPresentation.fileToken(Self.recordings[0]),
                    among: Self.recordings, presences: nil) == nil else {
                    throw BrineStepError(
                        "a page is built for a recording whose safety nothing has read")
                }
                // FEWER READINGS THAN RECORDINGS — the same state, halfway.
                guard PocketRecordingDetailPresentation.located(
                    PocketRecordingDetailPresentation.fileToken(Self.recordings[2]),
                    among: Self.recordings, presences: [Self.onlyOnTheRecorder]) == nil else {
                    throw BrineStepError(
                        "a recording is paired with a reading taken about a different file")
                }
                // AND IT DOES RESOLVE WHEN IT CAN, so the refusal is not a constant no.
                guard let found = PocketRecordingDetailPresentation.located(
                    PocketRecordingDetailPresentation.fileToken(Self.recordings[2]),
                    among: Self.recordings, presences: readings) else {
                    throw BrineStepError("nothing ever resolves, so the refusals hold nothing")
                }
                guard found.recording == Self.recordings[2] else {
                    throw BrineStepError(
                        "the id resolved to \(found.recording.timestamp), not the recording it "
                            + "names")
                }
                return ctx
            },

            // MARK: already here, or too big

            defineStep("a recording this phone is already holding") { ctx, _, _ in
                world.recording = Self.recordings[2]
                world.page = PocketRecordingDetailPresentation.page(
                    for: Self.recordings[2], presence: Self.onThisPhoneOnly,
                    brain: .myComputer, now: Self.now)
                return ctx
            },

            defineStep("the page about it does not offer to bring it over, and says Solleva already has it") { ctx, _, _ in
                guard let page = world.page else { throw BrineStepError("no page was built") }
                guard !page.offers(.bringItOver) else {
                    throw BrineStepError(
                        "a recording this phone already holds is offered a second transfer — a "
                            + "Bluetooth session spent to be handed a file that is already here")
                }
                guard page.notes.contains(
                    PocketRecordingDetailPresentation.alreadyHereLine) else {
                    throw BrineStepError(
                        "the page withholds the transfer and does not say why")
                }
                return ctx
            },

            defineStep("a recording bigger than Solleva can carry says that instead of offering the tap") { ctx, _, _ in
                let huge = PocketRecording(date: "2026-08-11", timestamp: "20260811120000",
                                           sizeBytes: PocketBLEClient.maximumDownloadBytes + 1)
                let page = PocketRecordingDetailPresentation.page(
                    for: huge, presence: Self.onlyOnTheRecorder,
                    brain: .myComputer, now: Self.now)
                guard !page.offers(.bringItOver) else {
                    throw BrineStepError(
                        "a recording over the ceiling is offered a transfer that refuses before "
                            + "it opens the radio — a tap spent to be told no")
                }
                guard page.notes.contains(PocketRecordingDetailPresentation.tooBigLine) else {
                    throw BrineStepError("the ceiling is enforced in silence")
                }
                // AND ONE BYTE UNDER IS OFFERED, so this is a ceiling and not a refusal.
                let atTheCeiling = PocketRecording(
                    date: "2026-08-11", timestamp: "20260811120001",
                    sizeBytes: PocketBLEClient.maximumDownloadBytes)
                guard PocketRecordingDetailPresentation.page(
                    for: atTheCeiling, presence: Self.onlyOnTheRecorder,
                    brain: .myComputer, now: Self.now).offers(.bringItOver) else {
                    throw BrineStepError(
                        "a recording exactly at the ceiling is refused, so the boundary is off "
                            + "by one from the one the transfer enforces")
                }
                return ctx
            },

            defineStep("the ceiling it is measured against is the one the transfer itself refuses on") { ctx, _, _ in
                guard PocketBringOver.maximumBytes == PocketBLEClient.maximumDownloadBytes else {
                    throw BrineStepError(
                        "the page and the transfer are measuring against two different "
                            + "ceilings, so one of them will offer what the other refuses")
                }
                return ctx
            },

            // MARK: the reason, per brain

            // THE SENTENCE IS ABOUT THE RECORDING, NOT ABOUT THE TIER — and that inversion is
            // the point of these three. The superseded version picked between two REFUSALS by
            // brain; a brain is a fact about the account, and "what would I lose" is a fact
            // about this one recording. A tier-keyed answer is how a Vault owner came to be
            // told his notes were saved to a computer he does not have.
            defineStep("the page says nothing else holds it, whichever brain is on") { ctx, _, _ in
                // IDENTICAL, NOT MERELY PRESENT — and this is the assertion the first draft of
                // this step LOST. It collected every brain's notes into a set and then never
                // read the set: the superseded version it replaced had held `seen.count == 2`,
                // a load-bearing claim that the tier differentiated. Dropping the tier's role
                // means the replacement must claim the opposite, out loud, or a tier-shaped
                // sentence can come back with nothing to stop it. *(Review, 2026-08-19.)*
                var perBrain: [BrainChoice: [String]] = [:]
                for brain in BrainChoice.allCases {
                    let page = PocketRecordingDetailPresentation.page(
                        for: Self.recordings[0], presence: Self.onlyOnTheRecorder,
                        brain: brain, now: Self.now)
                    guard page.notes.contains(
                        PocketDeleteConsequence.nothingElseHoldsIt.sentence) else {
                        throw BrineStepError(
                            "\(brain.rawValue) is told \(page.notes) about a recording nothing "
                                + "outside the recorder is holding")
                    }
                    perBrain[brain] = page.notes
                }
                guard BrainChoice.allCases.count >= 3 else {
                    throw BrineStepError("the population of brains has shrunk below three")
                }
                guard Set(perBrain.values.map { $0.joined(separator: "\u{1F} ") }).count == 1 else {
                    throw BrineStepError(
                        "the three brains are told \(perBrain) — what a removal costs is a fact "
                            + "about THIS RECORDING, and a tier-keyed answer is how a Vault "
                            + "owner came to be told his notes were on a computer he does not "
                            + "have")
                }
                return ctx
            },

            defineStep("a Vault is suggested there, and the removal is still offered") { ctx, _, _ in
                let page = PocketRecordingDetailPresentation.page(
                    for: Self.recordings[0], presence: Self.onlyOnTheRecorder,
                    brain: .justMyPhone, now: Self.now)
                guard let suggestion =
                        PocketDeleteConsequence.nothingElseHoldsIt.vaultSuggestion,
                      page.notes.contains(suggestion) else {
                    throw BrineStepError(
                        "the one moment a Vault is a true and specific thing to say is the "
                            + "moment this would be the last copy, and the page does not say it "
                            + "— notes read \(page.notes)")
                }
                // AND IT DID NOT GET IN THE WAY. Nick's ruling has two halves and this is the
                // second: without it, "a Vault is suggested" passes on a build that suggests a
                // Vault INSTEAD of deleting, which is the defect he ruled against.
                guard page.offers(.removeFromRecorder) else {
                    throw BrineStepError("the Vault was suggested and the deletion withheld")
                }
                return ctx
            },

            defineStep("every one of them reaches the page it is about") { ctx, _, _ in
                // THE POPULATION, ON THE SURFACE. Without this, only the two alarming sentences
                // are ever asserted on a page, and `if consequence != .aCopyIsAlreadySomewhereElse`
                // deletes the reassuring one with nothing noticing — measured as a surviving
                // mutation on 2026-08-19.
                let readings: [PocketDeleteConsequence: PocketRecordingPresence] = [
                    .aCopyIsAlreadySomewhereElse: Self.provenElsewhere,
                    .thisPhoneWillHoldTheOnlyCopy: PocketRecordingPresence(
                        onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt),
                        onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt),
                        safeElsewhere: PocketPlaceReading(answer: .no, observedAt: Self.listedAt)),
                    .nothingElseHoldsIt: Self.onlyOnTheRecorder,
                    .nobodyHasCheckedWhereElseItIs: PocketRecordingPresence(
                        onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt),
                        onThisPhone: .neverAsked,
                        safeElsewhere: .neverAsked),
                ]
                guard Set(readings.keys) == Set(PocketDeleteConsequence.allCases) else {
                    throw BrineStepError("a consequence has no reading that produces it")
                }
                for (consequence, presence) in readings {
                    guard PocketDeleteConsequence.ofRemoving(presence) == consequence else {
                        throw BrineStepError(
                            "the reading chosen for \(consequence.rawValue) produces "
                                + "\(PocketDeleteConsequence.ofRemoving(presence).rawValue)")
                    }
                    let page = PocketRecordingDetailPresentation.page(
                        for: Self.recordings[0], presence: presence,
                        brain: .justMyPhone, now: Self.now)
                    guard page.offers(.removeFromRecorder) else {
                        throw BrineStepError("\(consequence.rawValue) withholds the removal")
                    }
                    guard page.notes.contains(consequence.sentence) else {
                        throw BrineStepError(
                            "the page for \(consequence.rawValue) says \(page.notes) — a removal "
                                + "is offered and what it costs is not on the page")
                    }
                }
                return ctx
            },

            defineStep("a recording this phone is holding is told it would leave one copy, on this phone") { ctx, _, _ in
                let heldHere = PocketRecordingPresence(
                    onRecorder: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt),
                    onThisPhone: PocketPlaceReading(answer: .yes, observedAt: Self.listedAt),
                    safeElsewhere: PocketPlaceReading(answer: .no, observedAt: Self.listedAt))
                let page = PocketRecordingDetailPresentation.page(
                    for: Self.recordings[0], presence: heldHere,
                    brain: .justMyPhone, now: Self.now)
                guard page.notes.contains(
                    PocketDeleteConsequence.thisPhoneWillHoldTheOnlyCopy.sentence) else {
                    throw BrineStepError(
                        "a recording this phone is holding is told \(page.notes) — the three "
                            + "consequences are not being told apart, so one sentence is "
                            + "standing in for all of them")
                }
                return ctx
            },

            // MARK: the words

            defineStep("every body the recorder page is written in") { ctx, _, _ in
                world.bodies = RecorderPageSurface.renderedTypes.map(\.type)
                guard world.bodies.count >= 3 else {
                    throw BrineStepError(
                        "fewer than three bodies are read as the recorder page, so a new screen "
                            + "has been added without being held to its words")
                }
                return ctx
            },

            defineStep("every one of them takes at least one sentence from the kit") { ctx, _, _ in
                // THE EXISTENCE HALF FIRST. "Every body that draws words cites the kit" is
                // satisfied for free by a surface where no body draws words.
                let drawing = try RecorderPageSurface.bodiesThatDrawWords()
                guard drawing.count >= 2 else {
                    throw BrineStepError(
                        "only \(drawing.count) of the recorder page's bodies draw any words at "
                            + "all, so this rule rules over nearly nothing")
                }
                guard drawing.contains("PocketRecordingDetailSheet") else {
                    throw BrineStepError(
                        "the page about one recording draws no words, so every claim about "
                            + "where its sentences come from is vacuous")
                }
                let silent = try RecorderPageSurface.bodiesRenderingNoKitSentence()
                guard silent.isEmpty else {
                    throw BrineStepError(
                        "\(silent.count) body/bodies on the recorder page render no kit-owned "
                            + "sentence at all: " + silent.joined(separator: ", ")
                            + ". A body that says nothing passes \"no sentence is written into "
                            + "the page\" for free")
                }
                return ctx
            },

            defineStep("the page about one recording is one of the bodies that is read") { ctx, _, _ in
                guard world.bodies.contains("PocketRecordingDetailSheet") else {
                    throw BrineStepError(
                        "`PocketRecordingDetailSheet` is not in the population the words and "
                            + "colours gates rule over, so a whole screen's worth of copy could "
                            + "be invented in a body while the surface reported clean")
                }
                return ctx
            },
        ]
    }
}
