import XCTest
import Foundation

/// T13 / A5 — the persisted identifier frontier is byte-unchanged, and the manifest's
/// size is asserted.
///
/// Brine driver for `features/persisted-identifier-frontier.feature`.
///
/// ## The frontier, and why it is read from source rather than from the types
///
/// The frontier is every identifier whose bytes are already on somebody's phone:
///
///   * the canonical keys of `AccountPreferenceCatalog` — what each setting is stored under;
///   * the `CodingKeys` of `AppPlacement` — the field names inside `app-placement.json`;
///   * the durable filename itself.
///
/// This file reads all three **out of the source text**, not out of the compiled types.
/// Asking `AccountPreferenceCatalog.brainChoice.canonicalKey` what the key is would let a
/// rename answer its own question — the comparison would be the renamed value against the
/// renamed value, and green. Reading the literal from the file and comparing it against a
/// literal written here is the only arrangement where a rename has two different sides.
///
/// Both directions fail. A manifest entry with no match in source is a spelling that
/// MOVED. A source identifier with no manifest entry is a spelling that APPEARED
/// undeclared — and, symmetrically, deleting a frontier literal from source leaves its
/// manifest entry unmatched, which is the second red leg A5 names.
///
/// The row count is asserted separately, because a manifest that only checks the rows it
/// still has can shrink to nothing and stay green. `testTheScanIsNotVacuous` is the
/// matching guard on the other input: a scan that reads zero files would satisfy "no
/// identifier is missing from the manifest" trivially.
final class PersistedIdentifierFrontierFeatureTests: XCTestCase {

    // MARK: The manifest — exact bytes, already on people's devices

    /// Canonical `UserDefaults` keys. Transcribed from `AccountPreferences.swift` as
    /// literals; NOT read from `AccountPreferenceCatalog`.
    private static let shippedPreferenceKeys: Set<String> = [
        "foundryx.account.signup-posted",
        "foundryx.ambient.agentName",
        "foundryx.ambient.enabled",
        "foundryx.ambient.grading",
        "foundryx.ambient.othersInline",
        "foundryx.brain.choice",
        "foundryx.capture.omi-desired-state",
        "foundryx.capture.silence-gap-seconds",
        "foundryx.capture.sources.enabled-overrides",
        "foundryx.models.cache.v1",
        "foundryx.onboarding.completed",
        "foundryx.onboarding.persona",
        "foundryx.vault.checkoutAttempt.id",
        "foundryx.vault.checkoutAttempt.plan",
        "foundryx.waitlist.joined",
        "foundryx.welcome.letStraightIn",
        "foundryx.welcome.seen",
    ]

    /// Field names inside the durable `app-placement.json`. `macLibraryOpen` is the
    /// pre-one-list name of `chatListOpen` — read, never written — and is on the frontier
    /// for exactly that reason: dropping it orphans the documents that still carry it.
    private static let shippedPlacementFields: Set<String> = [
        "tab", "openCaptureId", "openChatId", "chatListOpen",
        "generation", "doorTier", "macLibraryOpen",
    ]

    /// The durable document's own filename.
    private static let shippedPlacementFilename = "app-placement.json"

    /// Asserted, not counted at run time from the sets above — a size derived from the
    /// thing it is meant to bound asserts nothing.
    private static let declaredFrontierSize = 25

    // MARK: Reading what this build actually persists

    private static var repoRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every canonical key this build declares, parsed from the declaration site.
    private func persistedPreferenceKeys() throws -> Set<String> {
        let text = try source("Sources/FoundryXKit/AccountPreferences.swift")
        let pattern = try NSRegularExpression(
            pattern: "AccountPreferenceKey<[^>]*>\\(\\s*\"([^\"]+)\"")
        let range = NSRange(text.startIndex..., in: text)
        var keys: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text) {
                keys.insert(String(text[r]))
            }
        }
        return keys
    }

    /// The name a `CodingKey` case actually PERSISTS.
    ///
    /// For a `String`-raw-valued enum that is the explicit raw value when one is given
    /// (`case doorTier = "hostTier"` writes `hostTier`), and the case name otherwise.
    /// Read, not assumed: an earlier version of this parser took the whole token as the
    /// name, so adding an explicit raw value produced the field `doorTier = "hostTier"` —
    /// which reddened, but named a field that does not exist and would have let the
    /// manifest be "repaired" to the wrong string. The bytes in the document are the raw
    /// value, so the raw value is what this returns.
    private static func persistedName(ofCase declaration: String) -> String {
        let trimmed = declaration.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return trimmed }
        let rhs = trimmed[trimmed.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
        guard rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 else {
            // A non-string raw value on a CodingKey is not something this app has; refuse
            // to guess rather than silently returning something that compares equal.
            return trimmed
        }
        return String(rhs.dropFirst().dropLast())
    }

    /// Every `AppPlacement` coding key this build declares, parsed from the enum body.
    private func persistedPlacementFields() throws -> Set<String> {
        let text = try source("Sources/FoundryXKit/AppPlacement.swift")
        guard let enumStart = text.range(of: "enum CodingKeys: String, CodingKey {") else {
            return []
        }
        let rest = text[enumStart.upperBound...]
        guard let enumEnd = rest.range(of: "\n    }") else { return [] }
        let body = rest[..<enumEnd.lowerBound]

        var fields: Set<String> = []
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("case ") else { continue }
            let names = line.dropFirst("case ".count).split(separator: ",")
            for name in names {
                fields.insert(Self.persistedName(ofCase: String(name)))
            }
        }
        return fields
    }

    // MARK: Scenarios

    // Scenario: every name on the frontier is still spelled the way it was shipped
    func testEveryFrontierNameIsStillSpelledAsShipped() throws {
        let keys = try persistedPreferenceKeys()
        for shipped in Self.shippedPreferenceKeys {
            XCTAssertTrue(
                keys.contains(shipped),
                "the preferences key '\(shipped)' is on people's devices but this build "
              + "declares no such key — every phone holding it reads back a default instead")
        }

        let fields = try persistedPlacementFields()
        for shipped in Self.shippedPlacementFields {
            XCTAssertTrue(
                fields.contains(shipped),
                "'\(shipped)' is a field name inside app-placement.json documents that already "
              + "exist on disk, and this build's AppPlacement.CodingKeys no longer spells it — "
              + "the value in every saved document becomes unreadable")
        }

        let placement = try source("Sources/FoundryXKit/AppPlacement.swift")
        XCTAssertTrue(
            placement.contains("\"\(Self.shippedPlacementFilename)\""),
            "the durable document's filename is no longer '\(Self.shippedPlacementFilename)' — "
          + "every saved placement on every device is orphaned")
    }

    // Scenario: nothing has appeared on the frontier without being written down
    func testNothingAppearedOnTheFrontierUndeclared() throws {
        let keys = try persistedPreferenceKeys()
        for key in keys {
            XCTAssertTrue(
                Self.shippedPreferenceKeys.contains(key),
                "this build persists under '\(key)', which is not on the manifest — either it "
              + "is a rename of a shipped key (and the old bytes are stranded) or a new "
              + "frontier entry nobody wrote down")
        }

        let fields = try persistedPlacementFields()
        for field in fields {
            XCTAssertTrue(
                Self.shippedPlacementFields.contains(field),
                "app-placement.json now carries the field '\(field)', which is not on the "
              + "manifest — a renamed coding key strands the value in every saved document")
        }
    }

    // Scenario: the manifest's size is asserted
    func testTheManifestSizeIsAsserted() {
        let size = Self.shippedPreferenceKeys.count
            + Self.shippedPlacementFields.count
            + 1  // the filename

        XCTAssertEqual(
            size, Self.declaredFrontierSize,
            "the frontier manifest changed size — a row removed here silently retires a "
          + "guarantee about bytes that are still on people's phones")
    }

    // Scenario: the frontier scan is not looking at an empty pile
    func testTheScanIsNotVacuous() throws {
        XCTAssertGreaterThan(
            try persistedPreferenceKeys().count, 0,
            "the preferences scan read zero keys — a comparison against nothing passes "
          + "every check and proves none of them")
        XCTAssertGreaterThan(
            try persistedPlacementFields().count, 0,
            "the placement scan read zero coding keys — the enum moved or the parse broke, "
          + "and every frontier assertion above became vacuous")
    }
}
