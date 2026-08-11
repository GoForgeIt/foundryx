import XCTest
import Foundation
@testable import FoundryXKit

/// THE LEDGER OF WHAT IS ACTUALLY DRAWN (track 20260725T2306, review round 11 finding H2).
///
/// `RecordingSurfacePresentation.swift` declares eleven public types and T5's record said the
/// App target rendered them "1:1". It did not: ten of the eleven had zero references anywhere
/// under `App/`, `Widget/` or `UITests/`, and scenario `Then`s were being discharged against
/// values no view had ever called. The gap was invisible because `swift test` cannot compile
/// `App/`, so nothing connected "this value is asserted" to "this value is on screen".
///
/// This file is that connection, and it is deliberately TWO-SIDED:
///
///   * every type classified as drawn must have at least one App-side reference — so a
///     rendering that is quietly deleted reds here rather than leaving a green claim behind;
///   * every type classified as NOT drawn must have none — so the moment T6 wires one, this
///     reds and forces the classification, the record and the feature's wording to move
///     together. A ledger that only checked one direction would let the split rot silently in
///     the direction it rotted last time.
///
/// And it is COMPLETE BY CONSTRUCTION: the classified set is compared against the public types
/// actually declared in the file, so a new type cannot be added without being classified. That
/// is the property an enumerated list cannot have on its own.
final class RecordingSurfaceRenderingLedgerTests: XCTestCase {

    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private static let presentationFile = "Sources/FoundryXKit/RecordingSurfacePresentation.swift"

    /// The App target draws these. Each must have at least one reference under `App/`.
    static let drawnByTheApp: Set<String> = [
        // The recorder's name beside its own recording — the conversation row's meta line
        // (`CaptureScreen.CaptureCard`) and the detail header capsule
        // (`ConversationFacesView.metadataHeader`, a11y id `conversation-device`).
        "CaptureAttribution",
        "CaptureAttributionPresentation",
        // Consulted by the composition root to decide whether a gap outcome belongs to the
        // account on screen. It reaches only the log today, and the feature says so.
        "GapRecoveryRendering",
        // THE MOVE THIS LEDGER WAS BUILT TO FORCE (track
        // 20260810T2158_unified_recording_device_list_wires_pocket_and_omi). Its "not drawn"
        // direction said: "That is good news and it is a CHANGE: move it to `drawnByTheApp`,
        // reword the scenario Thens that currently say 'offered' to say what is drawn, and
        // record the move." `App/DeviceScreen.swift` is now the ONE LIST, and its title, its
        // affordance, its scanning and empty lines and its capability strip all come from
        // here — the first consumers these strings have ever had under `App/`.
        "RecordingDeviceConnectPresentation",
    ]

    /// DEFINED, ASSERTED, AND NOT YET DRAWN.
    ///
    /// What is left is the row VALUE type and the list-control type — the one list is rendered
    /// through `UnifiedDeviceListPresentation`, which composes `<class> · <state>` and is what
    /// `App/DeviceScreen.swift` names — plus the recording-history reader and the gap sentence,
    /// which still have no view. `features/device-rendered-surface.feature` says "offered"
    /// rather than "rendered" for exactly these.
    static let notYetDrawn: Set<String> = [
        "RecordingDeviceCapabilityLine",
        "RecordingDeviceRowPresentation",
        "RecordingDeviceListControl",
        "RecordingHistoryRow",
        "RecordingHistory",
        "GapRecoveryCopy",
        "GapRecoveryRenderDecision",
    ]

    // MARK: - completeness: nothing may be left unclassified

    func testEveryPublicPresentationTypeIsClassified() throws {
        let declared = try Self.publicTypeNames(in: Self.presentationFile)
        XCTAssertFalse(declared.isEmpty,
                       "no public types were found in \(Self.presentationFile) — the parser "
                           + "stopped matching, so this whole file has quietly become vacuous")
        let classified = Self.drawnByTheApp.union(Self.notYetDrawn)
        XCTAssertEqual(
            declared.subtracting(classified), [],
            "these public types are neither claimed as drawn nor recorded as not-yet-drawn. A "
                + "presentation value with no entry here is exactly how T5 shipped ten of them "
                + "asserted and none of them on screen — classify it, and say so in the record")
        XCTAssertEqual(
            classified.subtracting(declared), [],
            "these are classified but no longer declared in \(Self.presentationFile) — a stale "
                + "ledger entry makes the counts below meaningless")
        XCTAssertTrue(Self.drawnByTheApp.isDisjoint(with: Self.notYetDrawn),
                      "a type is on both sides of the ledger")

        // A NESTED public type is covered by the entry for the type it lives in — but only
        // if that outer type is itself classified, and only if we can name it at all.
        let nested = try Self.publicTypeDeclarations(in: Self.presentationFile)
            .filter { $0.nestedIn != nil }
        for declaration in nested.sorted(by: { $0.name < $1.name }) {
            guard let outer = declaration.nestedIn else { continue }
            XCTAssertTrue(
                classified.contains(outer),
                "`\(outer).\(declaration.name)` is a public type whose enclosing type is not "
                    + "classified, so nothing on either side of the ledger accounts for it")
        }
    }

    /// The completeness predicate itself, held against the shapes it used to miss.
    ///
    /// The claim §4.3 makes is *"a new type cannot be added without being classified"*. That
    /// is a claim about `publicTypeDeclarations`, and a regex that matched one cell of
    /// (keyword × attribute placement × nesting) made it false four ways (review round 12,
    /// M12-2). This is the matrix, as a fixture: every cell must be seen.
    func testTheCompletenessPredicateSeesEveryDeclarationShape() throws {
        let fixture = """
        public struct PlainStruct {}
        public final class FinalClass {}
        public enum PlainEnum {
            public struct NestedInsideAnEnum {}
        }
        public actor PlainActor {}
        public protocol AProtocol {}
        public typealias AnAlias = PlainStruct
        @available(iOS 17, *) public struct AttributedOnTheSameLine {}
        @frozen
        public struct AttributedOnItsOwnLine {}
        internal struct NotPublic {}
        // public struct InAComment {}
        /* public struct InABlockComment {} */
        public extension PlainStruct {
            struct PublicByVirtueOfItsExtension {}
        }
        """
        // THE LAST CASE IS A KNOWN MISS, NAMED HONESTLY (review round 13, L13-2). A member of
        // a `public extension` IS public in Swift, so `PublicByVirtueOfItsExtension` is a
        // public type this predicate does not see — it was once called `NotItselfPublic`, and
        // both that name and the doc's "public extension declares no type" read as if it were
        // a non-case. It is a case, and it is accepted: the extension opens the scope of an
        // already-classified type, so nothing here goes unaccounted for, and the presentation
        // file declares nothing this shape.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-predicate-fixture-\(UUID().uuidString).swift")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let declarations = try Self.publicTypeDeclarations(inFileAt: url)
        XCTAssertEqual(
            Set(declarations.filter { $0.nestedIn == nil }.map(\.name)),
            ["PlainStruct", "FinalClass", "PlainEnum", "PlainActor", "AProtocol", "AnAlias",
             "AttributedOnTheSameLine", "AttributedOnItsOwnLine"],
            "the completeness predicate misses a declaration shape — every one it misses is a "
                + "public type that can be added to the presentation file without the ledger "
                + "noticing, which is exactly the claim this file makes about itself")
        XCTAssertEqual(
            Set(declarations.filter { $0.nestedIn != nil }),
            Set([Self.PublicTypeDeclaration(name: "NestedInsideAnEnum", nestedIn: "PlainEnum")]),
            "a nested public type must be seen AND attributed to the type it lives in")
    }

    // MARK: - the two directions

    func testEveryTypeClaimedDrawnIsActuallyReferencedByTheApp() throws {
        XCTAssertFalse(Self.drawnByTheApp.isEmpty,
                       "nothing is claimed to be drawn at all — this direction cannot fail")
        for type in Self.drawnByTheApp.sorted() {
            let hits = try Self.appReferences(to: type)
            XCTAssertFalse(hits.isEmpty,
                           "`\(type)` is recorded as drawn by the App target and no file under "
                               + "App/ mentions it. Either the rendering was removed — in which "
                               + "case every scenario Then that says this is on screen is now "
                               + "false — or it moved and this ledger must follow it")
        }
    }

    func testEveryTypeRecordedAsNotDrawnStillHasNoView() throws {
        XCTAssertFalse(Self.notYetDrawn.isEmpty,
                       "nothing is recorded as not-yet-drawn — this direction cannot fail")
        for type in Self.notYetDrawn.sorted() {
            let hits = try Self.appReferences(to: type)
            XCTAssertTrue(hits.isEmpty,
                          "`\(type)` is now referenced by the App target (\(hits.joined(separator: ", "))). "
                              + "That is good news and it is a CHANGE: move it to `drawnByTheApp`, "
                              + "reword the scenario Thens that currently say \"offered\" to say "
                              + "what is drawn, and record the move. This gate exists so the "
                              + "wording and the ledger cannot drift apart again")
        }
    }

    // MARK: - the one claim the App must keep

    /// The attribution is the whole point of the track: before it, nothing in the shipped app
    /// ever showed a user which device recorded a conversation. This holds the two call sites
    /// by name, because `swift test` cannot compile `App/` and a deleted view compiles fine.
    func testTheAppNamesTheRecordingDeviceAgainstItsOwnRecordings() throws {
        // CODE, not prose. These are `contains` checks and the file's own comments name every
        // symbol below — a doc block would satisfy them all (review round 12, L12-1).
        let list = AppSourceTree.withoutComments(of: try Self.source("App/CaptureScreen.swift"))
        XCTAssertTrue(list.contains("CaptureAttributionPresentation.attribution(captureId:"),
                      "the conversation list no longer reads which device recorded each "
                          + "conversation — the row is back to saying nothing about its recorder")
        XCTAssertTrue(list.contains("CaptureAttributionPresentation.metaLine("),
                      "the row builds its own meta copy again instead of the tested composition, "
                          + "which is a second, untested implementation of it")
        // THE CALL SITE, not the parameter. `loadAttribution:` on its own is satisfied by the
        // declaration on `CaptureCard`, which a row that is never handed a loader still
        // carries — a mutation that renamed the argument at the call site survived this check
        // in exactly that way.
        XCTAssertTrue(list.contains("loadAttribution: { [weak manager] in"),
                      "the conversation row is never HANDED an attribution loader, so the "
                          + "`CaptureCard` parameter stays nil and the row shows nothing about "
                          + "its recorder — the parameter existing is not the same as it being "
                          + "passed")
        XCTAssertTrue(list.contains("attribution: attribution)"),
                      "the loaded attribution never reaches the composed meta line")

        let detail = AppSourceTree.withoutComments(of: try Self.source("App/ConversationFacesView.swift"))
        XCTAssertTrue(detail.contains("attribution.deviceName"),
                      "the conversation detail header no longer names the recorder")
        XCTAssertTrue(detail.contains("\"conversation-device\""),
                      "the recorder capsule lost its accessibility identifier, so no UI proof "
                          + "can name it")
        XCTAssertTrue(detail.contains("attribution.diagnostic"),
                      "an unnameable recorder renders as a bare \"Unknown device\" — this "
                          + "file's own rule is that a name which is not an answer must arrive "
                          + "with something the user can act on")
    }

    // MARK: - the rendered fact has a gate that can observe it

    /// A UI PROOF THAT NOBODY RUNS IS NOT A GATE.
    ///
    /// The two facts this track delivers — the recorder named on the conversation row, and
    /// named again in the detail header — are held by `RecordingDeviceProofUITests`, because
    /// nothing that `swift test` can compile is able to see them (review round 12, H12-2:
    /// deleting the row's loader `.task` and passing `attribution: nil` at the detail push
    /// site each left the whole suite green). That proof only counts while the pipeline
    /// executes it: `phase_uiproof` runs an explicit `-only-testing:` list, so a case that is
    /// not on that list never runs at all.
    ///
    /// This also pins the seed the proof reads. `DemoSeed` must write a device record, and
    /// the detail capsule must keep the identifier the proof looks it up by.
    ///
    /// WHY THE WIRING HALF READS THE EXECUTED COMMAND (review round 13, M13-1). It used to be
    /// a `contains` over the WHOLE script, which asks whether the string is somewhere in the
    /// file — not whether it is on the command the file runs. Moving the `-only-testing:` line
    /// into a shell comment two lines above the invocation left this test GREEN with the proof
    /// never executed (MUT-R13-P2), while DELETING the same line reds it: the gate was
    /// falsifiable against deletion and not against disabling, which is the likelier death.
    /// It now parses the `-only-testing:` arguments of `phase_uiproof`'s own body, with the
    /// comments removed the way the shell removes them (`ShellSource`).
    func testTheRenderedAttributionProofExistsAndIsActuallyRun() throws {
        let proof = try Self.source("UITests/RecordingDeviceProofUITests.swift")
        XCTAssertTrue(
            proof.contains("func testTheRecorderIsNamedOnTheConversationRowAndInItsDetail"),
            "the UI proof for the rendered recorder attribution is gone — the row and the "
                + "detail header are back to being held by source-text searches that a "
                + "deleted rendering satisfies")

        let uiproof = try Self.uiproofPhaseBody()
        // Non-vacuity: the phase must still RUN something, or an empty body would satisfy
        // every set assertion below by having nothing to disagree with.
        XCTAssertTrue(uiproof.contains("xcodebuild test"),
                      "`phase_uiproof` no longer runs `xcodebuild test` — this gate is reading "
                          + "a function that executes no proof at all")
        let executed = ShellSource.onlyTestingArguments(in: uiproof)
        XCTAssertFalse(executed.isEmpty,
                       "`phase_uiproof` names no `-only-testing:` case, so it either runs the "
                           + "whole UITest bundle or nothing — either way this gate can no "
                           + "longer tell whether the attribution proof is among them")
        XCTAssertTrue(
            executed.contains(
                "FoundryXUITests/RecordingDeviceProofUITests/"
                    + "testTheRecorderIsNamedOnTheConversationRowAndInItsDetail"),
            "`phase_uiproof` does not RUN RecordingDeviceProofUITests — it executes "
                + "\(executed.sorted().joined(separator: ", ")). It runs an explicit "
                + "`-only-testing:` list, so a proof that is not on the executed command never "
                + "runs — whether it was deleted or commented out — and an unrun proof is "
                + "documentation, not a gate")

        let seed = AppSourceTree.withoutComments(of: try Self.source("App/DemoSeed.swift"))
        XCTAssertTrue(
            seed.contains("CaptureDeviceSidecar.write("),
            "`DemoSeed` no longer writes a `.capture-device.json`, so the UI proof's library "
                + "has no device record to name and the proof cannot observe anything")

        let detail = AppSourceTree.withoutComments(
            of: try Self.source("App/ConversationFacesView.swift"))
        XCTAssertTrue(
            detail.contains("\"conversation-device\""),
            "the detail capsule lost the accessibility identifier the UI proof looks it up "
                + "by — the proof would red, but for the wrong reason")
    }

    /// THE PROOF MUST READ WHAT THIS RUN SEEDED (review round 13, H13-1).
    ///
    /// `DemoSeed`'s demo path is additive and the simulator's app container survives between
    /// runs — this lane runs on persistent native macOS workers whose simulators are never
    /// erased. So deleting `CaptureDeviceSidecar.write(…)` from the seed left the proof
    /// PASSING on the previous run's leftovers (MUT-R13-P6, SURVIVED on a warm container,
    /// RED on a clean one). Its ability to fail had become a property of the machine.
    ///
    /// Two things now hold it, and this is the one `swift test` can see: the phase uninstalls
    /// the app before it runs, and it does so BEFORE the invocation rather than anywhere in
    /// the function. (The other is `DemoSeed` removing every demo capture's device record
    /// before it seeds its own, so a direct `xcodebuild test` is honest too.)
    func testTheUiProofStartsFromAContainerThisRunCreated() throws {
        let uiproof = try Self.uiproofPhaseBody()
        guard let uninstall = uiproof.range(of: "simctl uninstall") else {
            return XCTFail(
                "`phase_uiproof` never uninstalls the app. Its proofs assert on a library "
                    + "`DemoSeed` writes into the app container on launch, and that container "
                    + "survives between runs on this lane's persistent workers — so a seed that "
                    + "is broken or deleted keeps passing on the last green run's leftovers. "
                    + "The proof has to read a container this run created")
        }
        guard let invocation = uiproof.range(of: "xcodebuild test") else {
            return XCTFail("`phase_uiproof` no longer runs `xcodebuild test` — this gate is "
                               + "reading a function that executes no proof at all")
        }
        XCTAssertTrue(uninstall.lowerBound < invocation.lowerBound,
                      "`phase_uiproof` uninstalls the app AFTER running the proof, so the run "
                          + "still reads whatever the previous one left behind")
    }

    // MARK: - the script lexer this file's wiring gate depends on

    /// The gate above is only as good as the comment stripping under it, so the stripping is
    /// held against the shapes it has to survive: the disabling form that beat the old gate
    /// (MUT-R13-P2), and the `#`s that are NOT comments and must not be eaten.
    func testTheShellLexerSeesWhatTheShellWouldExecute() throws {
        let fixture = """
        phase_example() {
          # -only-testing:Suite/Commented/WholeLine
          echo "a # inside double quotes is not a comment"
          echo 'b # inside single quotes is not a comment'
          echo "there are ${#items[@]} of them"
          if xcodebuild test \\
               -only-testing:Suite/Executed/Case \\
               -only-testing:Suite/Also/Executed >"$out" 2>&1; then   # -only-testing:Suite/Trailing/Comment
            echo ok
          fi
        }
        phase_other() {
          -only-testing:Suite/In/AnotherFunction
        }
        """
        let stripped = ShellSource.withoutComments(of: fixture)
        XCTAssertFalse(stripped.contains("Suite/Commented/WholeLine"),
                       "a whole-line `#` comment survived stripping — the exact way an "
                           + "`-only-testing:` case is disabled rather than deleted")
        XCTAssertFalse(stripped.contains("Suite/Trailing/Comment"),
                       "a trailing `#` comment survived stripping")
        XCTAssertTrue(stripped.contains("a # inside double quotes is not a comment"),
                      "a `#` inside a double-quoted string was treated as a comment opener")
        XCTAssertTrue(stripped.contains("b # inside single quotes is not a comment"),
                      "a `#` inside a single-quoted string was treated as a comment opener")
        XCTAssertTrue(stripped.contains("${#items[@]}"),
                      "`${#…}` was treated as a comment — `#` opens one only at the start of a "
                          + "line or after whitespace")

        guard let body = ShellSource.functionBody("phase_example", in: stripped) else {
            return XCTFail("the function-body scanner cannot find a `name() { … }` it is "
                               + "looking straight at")
        }
        XCTAssertEqual(
            ShellSource.onlyTestingArguments(in: body),
            ["Suite/Executed/Case", "Suite/Also/Executed"],
            "the executed set must be exactly the cases on this function's own invocation — "
                + "not the commented ones, and not another function's")
        XCTAssertNil(ShellSource.functionBody("phase_missing", in: stripped),
                     "a missing function must be `nil` — a scanner that guesses turns a rename "
                         + "into a vacuous pass")
    }

    // MARK: - helpers

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// `phase_uiproof`'s body, comments removed — i.e. what that function actually executes.
    private static func uiproofPhaseBody() throws -> String {
        let script = ShellSource.withoutComments(of: try source("scripts/ci-gates.sh"))
        guard let body = ShellSource.functionBody("phase_uiproof", in: script) else {
            throw NSError(
                domain: "RecordingSurfaceRenderingLedgerTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "scripts/ci-gates.sh has no `phase_uiproof() { … }` function — the phase "
                        + "that runs the rendered-attribution proof was renamed or removed, and "
                        + "the gates that read it must follow it rather than pass on absence"])
        }
        return body
    }

    /// A public type declaration: its name, and the top-level type it is nested inside (nil
    /// when it IS top-level).
    struct PublicTypeDeclaration: Hashable {
        let name: String
        let nestedIn: String?
    }

    /// EVERY public type declaration in a Swift file — the property the ledger's completeness
    /// claim rests on, so its predicate is what has to be complete.
    ///
    /// WHAT THE OLD PREDICATE EXCLUDED, AND WHY THAT MATTERED (review round 12, M12-2). It
    /// was `^public\s+(?:final\s+)?(?:struct|enum|class|actor)\s+…`, which silently skipped
    /// four whole cells of the (keyword × attribute placement × nesting) matrix:
    /// `protocol` and `typealias`; any declaration whose attribute sits on the same line
    /// (`@available(iOS 17, *) public struct X`); and anything indented — i.e. every nested
    /// public type, of which the file already had one. Appending a `public protocol` to the
    /// presentation file therefore added an unclassified public type and the completeness
    /// test SURVIVED (MUT-R12-H). "Complete by construction" was a claim about a regex that
    /// matched one cell.
    ///
    /// The predicate is widened rather than documented-around: all six declaration keywords,
    /// attributes in either position, and nesting tracked rather than dropped. Its remaining
    /// exclusions, stated: the `extension` line itself declares no type, and a member of a
    /// `public extension` — which IS public in Swift, without carrying the keyword (review
    /// round 13, L13-2) — is therefore MISSED; and this is a line lexer, not a parser, so a
    /// public type declared inside a function body would be attributed to the enclosing type.
    /// Neither shape exists in the file this gate reads, and both would be strange places to
    /// put a presentation value.
    static func publicTypeDeclarations(in path: String) throws -> Set<PublicTypeDeclaration> {
        try publicTypeDeclarations(inFileAt: repoRoot.appendingPathComponent(path))
    }

    static func publicTypeDeclarations(inFileAt url: URL) throws -> Set<PublicTypeDeclaration> {
        let code = AppSourceTree.code(of: try String(contentsOf: url, encoding: .utf8))
        // Optional attributes (`@available(iOS 17, *)`, `@frozen`, …) may precede `public` on
        // the same line; `final`/`indirect`/`open` may follow it.
        let pattern = #"^([ \t]*)(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\n]*?\))?[ \t]+)*"#
            + #"public[ \t]+(?:final[ \t]+|indirect[ \t]+|open[ \t]+)*"#
            + #"(?:struct|enum|class|actor|protocol|typealias)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        var declarations: Set<PublicTypeDeclaration> = []
        var currentTopLevel: String?
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            // A top-level `extension Foo` / `public extension Foo` opens Foo's scope too:
            // anything public declared inside it belongs to Foo, which is already classified.
            if text.hasPrefix("extension ") || text.hasPrefix("public extension ") {
                currentTopLevel = text.split(separator: " ")
                    .dropFirst(text.hasPrefix("public ") ? 2 : 1).first
                    .map { $0.split(separator: ":").first.map(String.init) ?? String($0) }
                continue
            }
            guard let match = regex.firstMatch(in: text, range: full) else { continue }
            let indent = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2))
            if indent.isEmpty {
                currentTopLevel = name
                declarations.insert(PublicTypeDeclaration(name: name, nestedIn: nil))
            } else {
                declarations.insert(PublicTypeDeclaration(name: name, nestedIn: currentTopLevel))
            }
        }
        return declarations
    }

    /// The top-level public type names — what the ledger classifies. A nested public type is
    /// covered by the entry for the type it lives in (asserted separately).
    static func publicTypeNames(in path: String) throws -> Set<String> {
        Set(try publicTypeDeclarations(in: path).filter { $0.nestedIn == nil }.map(\.name))
    }

    /// App-side files that mention a type by whole word, in CODE.
    ///
    /// RECURSIVE, AND OVER ALL THREE APP-SIDE TREES (review round 12, L12-1). This used to be
    /// a flat `contentsOfDirectory` on `App/` while the finding it answers had counted
    /// references under `App/`, `Widget/` AND `UITests/` — so a T6 wiring in `Widget/`, or in
    /// any `App/` subdirectory anyone ever adds, would have left the not-drawn side green.
    /// Comment stripping is now honest too (trailing and block comments included, and string
    /// literals blanked): see `AppSourceTree`.
    static func appReferences(to type: String) throws -> [String] {
        try AppSourceTree.filesReferencing(type)
    }
}
