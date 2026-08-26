import XCTest

/// Every door route the phone calls must be able to reach a Mac it is not on the same
/// network as — which means a RELAY leg, not just a direct `baseURL` request.
///
/// ## Why this test exists
///
/// MEASURED 2026-08-26. `conversationPage` shipped with only the direct leg. The door's own
/// event log recorded `capture/status`, `capture/content`, `models` and `chat` arriving over
/// hours while the phone was demonstrably connected — and `/foundryx/conversations` NEVER
/// appeared once. The door logs even unauthorized requests, so an absent line means the
/// request never arrived at all.
///
/// The portal was therefore unreachable from any phone not on the Mac's network, and the
/// failure was SILENT: a request addressed to a base URL that is not the door produces no
/// door-side evidence, no error the user can act on, and an empty list that reads exactly
/// like "your computer holds nothing".
///
/// ⚠ THIS IS A SOURCE SCAN, AND THAT IS DELIBERATE. The alternative — a runtime test — needs
/// a relay, a door and a second network to be meaningful, so it would be skipped in CI and
/// prove nothing. What can be checked cheaply and always is the structural fact: a function
/// that builds a `/foundryx/` path and never mentions `target.relay` has one leg.
final class DoorRouteRelayLegTests: XCTestCase {

    /// Routes that legitimately have no relay leg, each with the reason it is exempt.
    ///
    /// ⚠ AN EXEMPTION IS A CLAIM, NOT A SHRUG. Anything listed here is asserting that the
    /// route is unreachable-by-design off-network. Adding a name to silence this test is how
    /// the guard stops being one.
    private static let exempt: Set<String> = [
        // Pairing runs BEFORE a relay exists — it is how the tunnel gets established.
        "pair",
        "pairingStatus",
    ]

    private static func doorClientSource() throws -> String {
        // Resolve up from this file to the package root, the same way the other frontier
        // tests do, so the scan reads the shipping source and not a copy.
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FoundryXBrineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let path = dir.appendingPathComponent("Sources/FoundryXKit/DoorClient.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let fallback = dir.appendingPathComponent("Sources/FoundryXKit/DoorClient.swift")
            return try String(contentsOf: fallback, encoding: .utf8)
        }
        return text
    }

    func testEveryDoorRouteHasARelayLeg() throws {
        let source = try Self.doorClientSource()
        let lines = source.components(separatedBy: .newlines)

        var offenders: [String] = []
        var scanned = 0
        var current: String?
        var body: [String] = []

        func judge() {
            guard let name = current else { return }
            let text = body.joined(separator: "\n")
            // Only functions that address the door AND CARRY THEIR OWN TRANSPORT are in
            // scope.
            //
            // ⚠ THE FIRST VERSION FLAGGED SIX FALSE POSITIVES and I nearly exempted them,
            // which would have been the defect this test exists to catch. Verified one by
            // one instead:
            //   `args`            a nested JSON helper — not a route at all
            //   `rawChatHTTP`     builds the bytes `collectViaRelay` sends OVER the relay
            //   kiln* (x4)        delegate to `kilnRequest`, which IS relay-aware
            // None of those perform a request themselves. A function that delegates cannot
            // be missing a leg; only one that opens its own `URLRequest`/`session.data` can.
            guard text.contains("/foundryx/") else { return }
            guard text.contains("session.data") || text.contains("URLRequest(") else { return }
            scanned += 1
            if Self.exempt.contains(name) { return }
            if !text.contains("target.relay") {
                offenders.append(name)
            }
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("public func ") || t.hasPrefix("private func ") || t.hasPrefix("func ") {
                judge()
                let afterFunc = t.drop(while: { $0 != "f" }).dropFirst(5)
                current = String(afterFunc.prefix(while: { $0 != "(" }))
                    .trimmingCharacters(in: .whitespaces)
                body = [line]
            } else if current != nil {
                body.append(line)
            }
        }
        judge()

        // ⚠ A SCAN THAT MATCHED NOTHING IS NOT A PASS. If the file moves or its shape
        // changes, this test must refuse rather than report clean.
        XCTAssertGreaterThan(
            scanned, 3,
            "REFUSED: only \(scanned) door route(s) found in DoorClient.swift. A scan that "
            + "reaches almost nothing cannot report that every route is reachable.")

        XCTAssertTrue(
            offenders.isEmpty,
            "These door routes build a /foundryx/ path with NO relay leg, so they cannot "
            + "reach a Mac the phone is not on the network with — and the failure is silent, "
            + "because the request never arrives and the door logs nothing: \(offenders.sorted())")
    }
}
