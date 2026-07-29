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
    ]

    /// DEFINED, ASSERTED, AND NOT YET DRAWN — T6's device page and gap surface.
    ///
    /// The shipped `App/DeviceScreen.swift` is still the Omi-specific prototype (a hand-rolled
    /// pairing list plus the Battery / Signal / Firmware strip); the one device list, its
    /// capability lines and its gap sentence have no view. `features/device-rendered-surface.feature`
    /// says "offered" rather than "rendered" for exactly these, and `implementation-t5-fixforward.md`
    /// records the split.
    static let notYetDrawn: Set<String> = [
        "RecordingDeviceCapabilityLine",
        "RecordingDeviceRowPresentation",
        "RecordingDeviceListControl",
        "RecordingDeviceConnectPresentation",
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
            struct NotItselfPublic {}
        }
        """
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

    // MARK: - helpers

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
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
    /// exclusions, stated: `public extension` declares no type (types declared INSIDE one are
    /// attributed to the extended type); and this is a line lexer, not a parser, so a public
    /// type declared inside a function body would be attributed to the enclosing type.
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
