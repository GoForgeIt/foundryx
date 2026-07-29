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
        let list = try Self.source("App/CaptureScreen.swift")
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

        let detail = try Self.source("App/ConversationFacesView.swift")
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

    /// Public type declarations in a Swift file, by name.
    static func publicTypeNames(in path: String) throws -> Set<String> {
        let text = try source(path)
        let pattern = #"(?m)^public\s+(?:final\s+)?(?:struct|enum|class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var names: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        return names
    }

    /// Files under `App/` that mention a type by whole word.
    static func appReferences(to type: String) throws -> [String] {
        let appDir = repoRoot.appendingPathComponent("App", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: appDir,
                                                                includingPropertiesForKeys: nil)
        let regex = try NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: type))\\b")
        var hits: [String] = []
        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Comments name types constantly; a mention in prose is not a rendering.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                    return trimmed.hasPrefix("//") ? "" : line
                }
                .joined(separator: "\n")
            let ns = code as NSString
            if regex.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) != nil {
                hits.append(file.lastPathComponent)
            }
        }
        return hits.sorted()
    }
}
