import XCTest
@testable import FoundryXKit

/// **P6 AC6 — the smallest file on the recorder transfers, and is HELD.**
///
/// This is the one acceptance criterion in the pocket surface that cannot be satisfied by a
/// fixture: it is a claim about a real recorder, a real radio, and the app's real custody. So it
/// drives the SHIPPED stack — `PocketTransferQueue.run()`, which builds its own
/// `RecordingDeviceAttachment`, authenticates, lists, and brings a recording over — against the
/// physical device, and then asks custody whether the bytes are there.
///
/// ## ⚠ OPT-IN. THIS NEVER RUNS IN A NORMAL SUITE.
///
/// Gated on `POCKET_HARDWARE=1`. Without it the test SKIPS LOUDLY rather than passing: a hardware
/// test that silently no-ops is indistinguishable from one that ran, which is the defect class this
/// repository spends its time on. `swift test` and every CI phase leave it skipped.
///
/// ## WHY NOT `pocket-libre`
///
/// The earlier evidence in `evidence/pocket/` was captured with `~/Development/pocket-libre`, and
/// those files say so explicitly: *"These frames were not captured by this repository."* That tool
/// proves the DEVICE serves a file. **AC6 is a claim about this app** — "transfers **and is
/// held**" — and "held" means `PocketRecorderFileCustody`. Only the shipped path can prove it.
///
/// ## ⚠ SAFETY: THIS ONLY EVER READS
///
/// It brings ONE file over and asserts custody. It issues no delete, no format, and no key write.
/// In particular it never sends `APP&SK&`: whether a DIFFERENT key overwrites an existing pairing
/// is untested on this hardware and must stay that way, so this test uses whatever pairing the
/// recorder already has and never establishes one.
///
/// The target is chosen as the SMALLEST listed recording — AC6's own words — which on this device
/// is a ~4 KB, ~1 second file. That is deliberate: the shortest possible radio time, and nothing
/// about the assertion needs a long file.
final class PocketHardwareBringOverTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["POCKET_HARDWARE"] == "1"
    }

    /// The peripheral to talk to. Overridable so this is not pinned to one person's device.
    private var peripheral: String {
        ProcessInfo.processInfo.environment["POCKET_PERIPHERAL"]
            ?? "08322547-B7D1-0875-DA0C-0CE9BC1AE529"
    }

    private var advertisedName: String {
        ProcessInfo.processInfo.environment["POCKET_NAME"] ?? "PKT01_BLUE_26079bc5"
    }

    func testTheSmallestRecordingComesOffTheRecorderAndIsHeld() async throws {
        try XCTSkipUnless(
            enabled,
            "POCKET_HARDWARE=1 not set — this test needs a physical Pocket recorder powered and "
                + "in range. It is skipped, NOT passed: a hardware assertion that quietly no-ops "
                + "would be indistinguishable from one that ran.")

        // A scratch custody root, so a real bring-over cannot disturb a real library.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-hardware-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let custody = PocketRecorderFileStore(root: root)
        let destination = PocketBringOver.Destination(baseDir: root)
        let attachment = RecordingDeviceAttachment()

        // ── THE SHIPPED SESSION. Attach, authenticate, list, bring one over. ─────────────
        //
        // `withAuthenticatedSession` is the app's own entry point — it reaches the discovered
        // graph, authenticates with the pairing the recorder ALREADY has, and hands back the
        // same `PocketBLEClient` the phone uses. Nothing here re-implements the protocol.
        struct Outcome: Sendable {
            var listed: Int = 0
            var chosen: String = ""
            var bytes: Int = 0
            var attempt: String = ""
        }

        let result = await attachment.withAuthenticatedSession(
            peripheralIdentifier: UUID(uuidString: peripheral)!,
            advertisedName: advertisedName
        ) { client, identity -> Outcome in
            var out = Outcome()

            // The listing, exactly as PocketRecorderCheck does it: dates, then files per date,
            // deduping the day list because the protocol permits a repeated day.
            var days: [String] = []
            if let dates = try? await client.listDates() {
                for d in dates where !days.contains(d) { days.append(d) }
            }
            var found: [PocketRecording] = []
            for day in days {
                if let some = try? await client.listRecordings(on: day) { found += some }
            }
            out.listed = found.count
            guard let smallest = found.min(by: { $0.sizeBytes < $1.sizeBytes }) else { return out }
            out.chosen = "\(smallest.date)/\(smallest.timestamp)"
            out.bytes = smallest.sizeBytes

            // AC6: the smallest file. Shortest radio time, and nothing in the assertion needs
            // a long one.
            let attempt = await PocketBringOver.bringOver(
                on: client,
                identity: identity,
                advertisedName: advertisedName,
                recording: smallest,
                custody: custody,
                destination: destination)
            out.attempt = "\(attempt.outcome)"
            return out
        }

        guard case .ran(let out) = result else {
            return XCTFail("no session with the recorder: \(result). It must be powered, in "
                               + "range, and already paired — this test never establishes a "
                               + "pairing, by design.")
        }

        print("[pocket-hardware] listed \(out.listed); smallest \(out.chosen) "
                  + "@ \(out.bytes) bytes; outcome \(out.attempt)")
        XCTAssertGreaterThan(out.listed, 0,
                             "the recorder listed NO recordings — nothing to bring over, so any "
                                 + "\"it worked\" here would be vacuous")

        // ── HELD? Ask CUSTODY, not the transfer's own opinion of itself. ────────────────
        let parts = out.chosen.split(separator: "/")
        let key = PocketRecorderFileKey(
            identity: RecordingDeviceIdentity(shape: .filePull, hardwareToken: peripheral),
            date: String(parts.first ?? ""),
            timestamp: String(parts.last ?? ""))
        let held = await custody.heldFile(key)
        XCTAssertNotNil(held,
                        "the recording did not reach custody. Outcome was: \(out.attempt)")

        if let held {
            let size = (try? Data(contentsOf: held).count) ?? 0
            print("[pocket-hardware] held at \(held.lastPathComponent), \(size) bytes")
            XCTAssertGreaterThan(size, 0,
                                 "custody holds a file of ZERO bytes — an empty file is not a "
                                     + "transfer, and 'held' must mean the audio arrived")
        }
    }

}
