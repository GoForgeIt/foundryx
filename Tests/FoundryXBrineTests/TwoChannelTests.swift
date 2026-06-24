import XCTest
import Foundation
@testable import FoundryXKit

/// Two-channel relay isolation: interactive traffic (chat + transcript fetch) dials
/// a SEPARATE relay tunnel (`<base>-chat`) from bulk capture sync (the base tunnel),
/// so a capture backlog can't starve chat. These lock the channel derivation; the
/// per-call routing (chat/captureContent → `.interactive()`, upload/finalize/status →
/// base) is enforced at the call sites in DoorClient/CaptureWAL.
final class TwoChannelTests: XCTestCase {

    private func base() -> RelayConfig {
        RelayConfig(
            relayURL: URL(string: "ws://34.57.104.157:8787")!,
            tunnelId: "h-532f1547e05a33df",
            staticPrivate: Data(repeating: 7, count: 32),
            expectedDoorStatic: Data(repeating: 9, count: 32)
        )
    }

    func testInteractiveAppendsChatSuffixToTunnelId() {
        XCTAssertEqual(base().interactive().tunnelId, "h-532f1547e05a33df-chat")
    }

    func testInteractiveDiffersOnlyInTunnelId() {
        let b = base(), i = b.interactive()
        // Same relay, same Noise identity, same door-key pin — only the tunnel differs,
        // so both channels splice to the SAME door (different pools), key-pinned.
        XCTAssertEqual(i.relayURL, b.relayURL)
        XCTAssertEqual(i.staticPrivate, b.staticPrivate)
        XCTAssertEqual(i.expectedDoorStatic, b.expectedDoorStatic)
        XCTAssertNotEqual(i.tunnelId, b.tunnelId)
    }

    func testInteractiveMatchesDoorSideDerivation() {
        // The door derives the same id via `interactive_tunnel_id(base) = base + "-chat"`
        // (foundryx_gateway.rs). Phone + door must agree or the splice never pairs.
        XCTAssertEqual(base().interactive().tunnelId, "\(base().tunnelId)-chat")
    }
}
