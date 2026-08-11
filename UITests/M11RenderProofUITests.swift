// M11RenderProofUITests — the phone's own answer to "is the phone Solleva?"
//
// WHY THIS FILE EXISTS
// --------------------
// M11's `sees` is a sentence about a phone in your hand:
//
//   "You pick up your phone and the app is the same product as the desktop — same palette,
//    same chat law, the four tabs unchanged with Capture still first, one name on the
//    device, and the '-X' suffix gone."
//
// Every limb of that sentence is a claim about RENDERED PIXELS AND RENDERED TEXT. A source
// scan can tell you what a string literal says; it cannot tell you that the string reaches a
// screen, and it cannot tell you what colour the page actually is. Five gates in this
// programme were red on a clean checkout because they scanned a surface that could not hold
// the value they were asserting. This test scans the surface that CAN hold it: the running
// app's accessibility tree and its screenshot buffer.
//
// It ASSERTS NOTHING. It is a MEASUREMENT INSTRUMENT: it prints machine-readable lines that
// `scripts/check-m11.mjs` reads and rules on. Keeping the ruling out of here is deliberate —
// an XCTest that fails takes the whole measurement down with it, so a red palette would hide
// the tab census behind it. The gate wants every clause's number on every run.
//
// Output contract (one line each, parsed by check-m11.mjs):
//   M11-APP-LABEL: <the name iOS shows for the app>
//   M11-TABS: <label> | <label> | ...        (rendered tab bar, in render order)
//   M11-SELECTED: <label>                    (the tab the app launched onto)
//   M11-DOMINANT <tab> <#RRGGBB> <count>/<sampled>   (the page's most common pixel)
//   M11-STRING <tab> «<string>»              (every rendered string containing "Foundry")
//   M11-STRINGS-TOTAL <tab> <n>              (how many strings that tab rendered at all)
//   M11-END
//
// The STRINGS-TOTAL line exists because "zero Foundry strings" on a screen that rendered
// nothing is a trivial pass. The count of what WAS read is the guard on the count of what
// was not found.

import XCTest

final class M11RenderProofUITests: XCTestCase {

    /// The tab bar labels this test will try to visit. Deliberately a SUPERSET of both the
    /// ruled set and the shipped set: `Chat` and `Chats` are both here so the census reports
    /// what is actually rendered rather than what it hoped to find.
    private static let candidateTabs = ["Capture", "Activity", "Chat", "Chats", "Settings",
                                        "Home", "Today", "Knowledge", "Measures", "Playbooks"]

    func testM11RenderedSurface() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-MainPreview"]
        app.launch()

        // The tab bar is the first thing that has to exist; without it there is no surface to
        // measure and the run must say so loudly rather than print an empty census.
        let anyTab = app.tabBars.firstMatch
        XCTAssertTrue(anyTab.waitForExistence(timeout: 120),
                      "M11-FATAL: no tab bar rendered within 120s — nothing to measure")

        print("M11-APP-LABEL: \(app.label)")

        let rendered = renderedTabLabels(app)
        print("M11-TABS: \(rendered.joined(separator: " | "))")
        print("M11-SELECTED: \(selectedTab(app, among: rendered) ?? "(none)")")

        for label in rendered {
            tap(app, tab: label)
            // Give the tab's first paint a beat; a screenshot taken mid-transition samples
            // the OUTGOING tab's pixels, which would silently mis-attribute the palette.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
            Thread.sleep(forTimeInterval: 1.2)

            measurePalette(app, tab: label)
            measureStrings(app, tab: label)

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "M11-\(label)"
            shot.lifetime = .keepAlways
            add(shot)
        }

        print("M11-END")
    }

    // MARK: - the tab census

    private func renderedTabLabels(_ app: XCUIApplication) -> [String] {
        // Read the bar's OWN children in their own order rather than probing a name list, so
        // a tab this test never heard of still shows up in the census.
        let bar = app.tabBars.firstMatch
        let buttons = bar.buttons.allElementsBoundByIndex
        var out: [String] = []
        for b in buttons where b.exists {
            let l = b.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !l.isEmpty { out.append(l) }
        }
        if out.isEmpty {
            // Fall back to the probe list ONLY to avoid reporting "0 tabs" when the bar
            // exists — and say so, because a silent fallback here would be a lie about
            // where the number came from.
            print("M11-NOTE: tab bar exposed no ordered children; probing candidate labels")
            for l in Self.candidateTabs where app.tabBars.buttons[l].firstMatch.exists {
                out.append(l)
            }
        }
        return out
    }

    private func selectedTab(_ app: XCUIApplication, among labels: [String]) -> String? {
        for l in labels {
            let b = app.tabBars.buttons[l].firstMatch
            if b.exists, b.isSelected { return l }
        }
        return nil
    }

    private func tap(_ app: XCUIApplication, tab: String) {
        let b = app.tabBars.buttons[tab].firstMatch
        if b.exists, b.isHittable { b.tap() }
    }

    // MARK: - the palette, measured off the screen

    /// The most common pixel in the screenshot, which on every screen in this app is the page
    /// itself. Reported with its share of the sample so a screen whose dominant colour is a
    /// photo or a full-bleed accent is visible as such rather than mistaken for the ground.
    private func measurePalette(_ app: XCUIApplication, tab: String) {
        guard let cg = app.screenshot().image.cgImage else {
            print("M11-DOMINANT \(tab) (no-cgimage) 0/0")
            return
        }
        let w = cg.width, h = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * w
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("M11-DOMINANT \(tab) (no-context) 0/0")
            return
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Sample the CONTENT band only: skip the top 12% (status bar + nav chrome) and the
        // bottom 14% (tab bar + home indicator), which are system-tinted and would drown out
        // the page. Every 4th pixel on every 4th row keeps this well under a second.
        let y0 = Int(Double(h) * 0.12), y1 = Int(Double(h) * 0.86)
        var counts: [UInt32: Int] = [:]
        var sampled = 0
        var y = y0
        while y < y1 {
            var x = 0
            while x < w {
                let o = y * bytesPerRow + x * bytesPerPixel
                let key = (UInt32(buf[o]) << 16) | (UInt32(buf[o + 1]) << 8) | UInt32(buf[o + 2])
                counts[key, default: 0] += 1
                sampled += 1
                x += 4
            }
            y += 4
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(3)
        for (i, e) in top.enumerated() {
            let hex = String(format: "#%06X", e.key)
            print("M11-DOMINANT\(i == 0 ? "" : "-\(i + 1)") \(tab) \(hex) \(e.value)/\(sampled)")
        }
    }

    // MARK: - the rendered strings

    private func measureStrings(_ app: XCUIApplication, tab: String) {
        var seen = Set<String>()
        var total = 0
        for kind in [app.staticTexts, app.buttons, app.otherElements, app.cells,
                     app.navigationBars, app.switches, app.textFields, app.textViews,
                     app.images, app.links] {
            for e in kind.allElementsBoundByIndex {
                guard e.exists else { continue }
                for s in [e.label, e.title, (e.value as? String) ?? ""] {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    total += 1
                    if t.contains("Foundry") && !seen.contains(t) {
                        seen.insert(t)
                        print("M11-STRING \(tab) «\(t)»")
                    }
                }
            }
        }
        print("M11-STRINGS-TOTAL \(tab) \(total)")
    }
}
