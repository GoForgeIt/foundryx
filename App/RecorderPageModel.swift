// RecorderPageModel — the recorder page's state and every decision it used to make inside a
// SwiftUI body.
//
// WHY THIS TYPE EXISTS AT ALL, and it is not tidiness.
//
// `swift test` compiles the SPM package only. It cannot compile `App/`. So a decision written
// in a `View` — a `@State` var, a computed property over it, an `onChange` comparison — is
// unreachable by every executable test in this repository, and the ONLY instrument left is a
// gate that reads `App/DeviceScreen.swift` as TEXT and asserts a substring is present. That
// instrument was measured on 2026-08-17 and it does not work:
//
//   * `.onChange(of: check.isChecking) { guard !checking else { return } … }` → `guard checking`
//     — the re-read now fires on the RISING edge, so a finished check's numbers reach the page
//     never — and `swift test --filter FoundryXBrineTests` returned 1536 executed / 0 failures,
//     byte-identical to the clean baseline. So did the app-hosted lane: 7 tests, 0 failures.
//   * `refreshedInput = refreshed` → `_ = await …` — the disk read runs and its result reaches
//     no surface — same, green.
//
// Both survive because the seven `contains()` assertions holding this behaviour
// (`DeviceCompositionRootGateTests.testACompletedCheckIsReReadIntoThePageItWasRunFrom`) ask
// whether a STRING is in the file. `RecordingDevicePageFacts` was still named. `onChange(of:
// check.isChecking)` was still there. Every string was present and every one of them was
// satisfied by code that did the opposite thing.
//
// WHAT CHANGES HERE. This is a `@MainActor ObservableObject` in the app module, and
// `Tests/FoundryXAppScenarioTests` does `@testable import FoundryX` and runs inside the
// shipping app's process on the iOS runtime. It can construct this object, hand it the real
// `PocketRecorderCheckModel`, drive a real check over a scripted radio, and read
// `page(pushed:)` — the exact presentation value the body renders 1:1. There is no string for
// a mutation to satisfy: the numbers are either in the presentation or they are not.
//
// THE VIEW KEEPS NOTHING. `RecordingDevicePageView` had `@State private var refreshedInput`,
// a `live` that read it, a `checkState`, a `page`, and an `onChange` that decided when to
// re-read. All five are here. What is left in the body is `model.page(pushed: input)`.

// NO `import FoundryXKit`: the app target INLINES `Sources/FoundryXKit` (see project.yml), so
// those types are already in this module. The SPM library product exists for the test targets.
import Foundation
import Combine

@MainActor
final class RecorderPageModel: ObservableObject {

    /// THE ERRAND MODEL THIS PAGE DRIVES, owned here rather than beside this one in the view.
    ///
    /// Two `@StateObject`s cannot be wired to each other — the second's initialiser cannot see
    /// the first — and the wiring is the whole point: this model has to be told when an errand
    /// ends. So the page holds ONE `@StateObject` and reaches the check through it.
    let check: PocketRecorderCheckModel

    /// The recorder this page is about. Fixed for the life of the page: a `NavigationLink`
    /// pushes one device, and a re-read that could be pointed at a different identity than the
    /// one being rendered is a page that can show another recorder's battery.
    private let identity: RecordingDeviceIdentity

    /// Whether this build has a transport that can attach this device as a LIVE one.
    private let isSavedOmi: Bool

    /// WHAT THE LAST FINISHED ERRAND FOUND IN THE ACCOUNT'S STORE, and `nil` before any errand
    /// has finished. Published because the page renders from it.
    ///
    /// IT IS THE OUTCOME, NOT AN INPUT VALUE. The shipped code kept
    /// `@State private var refreshedInput: RecordingDeviceListInput?` — the whole device, with
    /// the fresh readings folded in — and rendered `refreshedInput ?? input`. That form cannot
    /// represent "the read failed", because a failed read produced the pushed value back and
    /// was therefore indistinguishable from a successful one. See `RecordingDevicePageReReading`.
    @Published private(set) var reReading: RecordingDevicePageReReading?

    /// THE LAST FACTS A RE-READ ACTUALLY FOUND, kept apart from the latest OUTCOME on purpose.
    ///
    /// A failed re-read must not take the numbers away. They are the last thing the recorder
    /// itself stated and the most useful thing on the page; what fails is the phone's attempt
    /// to confirm them against this account's file, and the honest response to that is to stop
    /// claiming they were just confirmed — `factsNote` — not to blank them.
    @Published private(set) var lastRead: [String: RecordingDeviceReading]?

    /// HOW MANY TIMES THE ACCOUNT'S FACTS HAVE BEEN RE-READ INTO THIS PAGE. The view watches it
    /// to tell the list behind the page to recompose, and the scenarios read it to know a
    /// re-read has landed without polling a value that may legitimately be unchanged.
    @Published private(set) var factsGeneration = 0

    private var checkRedraws: AnyCancellable?

    /// HOW MANY RE-READS HAVE BEEN ASKED FOR, AND WHICH IS THE LATEST ONE TO HAVE LANDED.
    ///
    /// Two errands can finish close enough together that their disk reads overlap — a check
    /// whose tail runs the owner-armed sweep is exactly that shape, and the sweep's removal
    /// writes a FRESHER free-space figure than the check that preceded it. Without this, the
    /// check's older answer could land second and overwrite it, and the page would go
    /// backwards for no reason a person could ever see.
    private var reReadsRequested = 0
    private var latestReReadApplied = 0

    init(check: PocketRecorderCheckModel,
         identity: RecordingDeviceIdentity,
         isSavedOmi: Bool) {
        self.check = check
        self.identity = identity
        self.isSavedOmi = isSavedOmi
        // THE VIEW OBSERVES THIS MODEL, SO THIS MODEL HAS TO REPUBLISH THE CHECK'S CHANGES.
        // Without it the page stops redrawing when the errand model publishes — the shelf, the
        // busy state and the header would all freeze.
        checkRedraws = check.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        // EVERY ERRAND, NOT JUST A CHECK. `finishErrand` is the one stop all five entry points
        // pass through — the check, the bring-over, both removal paths and the fast sync — and
        // wiring here instead of to the falling edge of `isChecking` is what makes a REMOVAL
        // refresh the free-space figure the owner is watching while they reclaim room.
        check.onErrandFinished = { [weak self] in self?.errandFinished() }
    }

    // MARK: - What the page renders

    /// THE DEVICE AS IT IS NOW: the value the list pushed into this page, carrying whichever
    /// set of readings is the later one. `pushed` is passed in on every call rather than
    /// stored, and that is what makes the shipped latch structurally impossible — there is no
    /// remembered input for a stale re-read to override.
    func live(pushed: RecordingDeviceListInput) -> RecordingDeviceListInput {
        pushed.withReadings(
            RecordingDevicePageFacts.readings(pushed: pushed.readings, lastRead: lastRead))
    }

    /// DOES THIS BUILD HAVE A TRANSPORT THAT CAN ACTUALLY ATTACH THIS DEVICE? A remembered
    /// record-then-sync recorder has one: `RecordingDeviceAttachment.withAuthenticatedSession`,
    /// which `PocketRecorderCheck.run` opens and closes.
    ///
    /// THE PARAMETER IS NAMED `input` ON PURPOSE. `DeviceCompositionRootGateTests
    /// .testARememberedRecorderCanBeReachedFromItsOwnPage` pins the literal
    /// `input.deviceClass == .recordThenSync && input.isRemembered`, and that gate is about a
    /// real defect: `canConnect: isSavedOmi` compares against a `.bleStream` identity, so it is
    /// false for every stored-file recorder by construction — once a Pocket was adopted its
    /// page carried no connect action at all. Renaming the parameter here would have retired
    /// that gate silently, over a rename.
    func canReach(_ input: RecordingDeviceListInput) -> Bool {
        isSavedOmi || (input.deviceClass == .recordThenSync && input.isRemembered)
    }

    /// THE ONLY LIVE STATE A RECORD-THEN-SYNC RECORDER HAS. A check opens its own session and
    /// closes it again, so this page has no link to report and never had one.
    func checkState(pushed: RecordingDeviceListInput) -> RecordingDeviceCheckState {
        RecordingDeviceCheckState.resolve(isChecking: check.isChecking,
                                          answeredAt: check.shelfObservedAt,
                                          readings: live(pushed: pushed).readings)
    }

    /// THE WHOLE PAGE, AS ONE VALUE. The body renders this 1:1 and decides nothing, so a
    /// scenario asserting on it is asserting on what the owner sees.
    func page(pushed: RecordingDeviceListInput,
              now: Date = Date()) -> RecordingDevicePagePresentation {
        RecordingDevicePage.resolve(live(pushed: pushed),
                                    canConnect: canReach(pushed),
                                    check: checkState(pushed: pushed),
                                    factsNote: RecordingDevicePageFacts.note(for: reReading),
                                    now: now)
    }

    // MARK: - The re-read

    /// AN ERRAND CHANGED WHAT THIS ACCOUNT HOLDS FOR THIS RECORDER, so the page goes and reads
    /// it back.
    ///
    /// OFF THE MAIN ACTOR. `RecordingDeviceStore.current()` resolves the account binding — a
    /// process-wide lock plus an on-disk admission-registry read — and then decodes a JSON
    /// file; that is the disk read `LazyView` exists to keep out of a body pass.
    private func errandFinished() {
        reReadsRequested += 1
        let request = reReadsRequested
        let identity = self.identity
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                RecordingDevicePageFacts.reRead(identity)
            }.value
            guard let self, request > self.latestReReadApplied else { return }
            self.latestReReadApplied = request
            self.reReading = outcome
            if case .refreshed(let found) = outcome { self.lastRead = found }
            self.factsGeneration += 1
        }
    }
}
