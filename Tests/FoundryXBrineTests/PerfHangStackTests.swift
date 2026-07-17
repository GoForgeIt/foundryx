import XCTest
import Foundation
import FoundryXKit

/// Full MXHangDiagnostic call-tree capture (track 20260717T0448). The parser + line
/// formatters are pure (no MetricKit) so the wire format — what reaches the diag
/// endpoint and gets `atos`-symbolicated off-line — is pinned by tests on macOS.
final class PerfHangStackTests: XCTestCase {

    private let ctx = PerfContext(build: "166", installId: "a1b2c3d4")

    /// A documented-shape callStackTree JSON: a NON-attributed thread first on the wire,
    /// an ATTRIBUTED (hung) thread with a nested subFrame + a symbol-less frame.
    private func fixtureTreeJSON() -> Data {
        let json = """
        {
          "callStacks": [
            {
              "threadAttributed": false,
              "callStackRootFrames": [
                { "binaryName": "libsystem_kernel.dylib",
                  "binaryUUID": "11111111-2222-3333-4444-555555555555",
                  "offsetIntoBinaryTextSegment": 16 }
              ]
            },
            {
              "threadAttributed": true,
              "callStackRootFrames": [
                { "binaryName": "FoundryX",
                  "binaryUUID": "AABBCCDD-1122-3344-5566-77889900AABB",
                  "offsetIntoBinaryTextSegment": 479,
                  "symbolName": "CaptureManager.rebuild",
                  "subFrames": [
                    { "binaryName": "FoundryX",
                      "binaryUUID": "AABBCCDD-1122-3344-5566-77889900AABB",
                      "offsetIntoBinaryTextSegment": 500 }
                  ] }
              ]
            }
          ]
        }
        """
        return Data(json.utf8)
    }

    // AC1 — the attributed (hung) thread's frames parse FIRST, carry UUID + offset, and
    // a missing symbol is nil (not fabricated).
    func testParseAttributedThreadFirstWithOffsets() {
        let parse = PerfHangStack.parse(fromTreeJSON: fixtureTreeJSON())
        XCTAssertEqual(parse.frames.count, 3)
        XCTAssertFalse(parse.truncated)
        // Attributed thread first: the FoundryX root, then its subframe, then libsystem.
        XCTAssertEqual(parse.frames[0].binaryName, "FoundryX")
        XCTAssertEqual(parse.frames[0].offset, 479)
        XCTAssertEqual(parse.frames[0].symbol, "CaptureManager.rebuild")
        XCTAssertEqual(parse.frames[1].offset, 500)
        XCTAssertNil(parse.frames[1].symbol, "a frame without symbolName carries no symbol")
        XCTAssertEqual(parse.frames[2].binaryName, "libsystem_kernel.dylib")
        XCTAssertEqual(parse.frames[2].offset, 16)
    }

    // AC1 — the emitted lines carry build + install id, ms, frames in binary@uuid8+0xoff
    // form, and a full-UUID image table; the frame offset is hex.
    func testHangStackLineFormat() {
        let parse = PerfHangStack.parse(fromTreeJSON: fixtureTreeJSON())
        let lines = PerfDiag.hangStackLines(ms: 650, frames: parse.frames,
                                            truncated: parse.truncated, ctx: ctx)
        let stack = lines.first { $0.contains(" hangstack ") }
        let img = lines.first { $0.contains(" hangimg ") }
        let stackLine = try! XCTUnwrap(stack)
        let imgLine = try! XCTUnwrap(img)

        XCTAssertTrue(stackLine.hasPrefix("perf build=166 dev=a1b2c3d4 hangstack ms=650 t=1/1 fr="))
        // 479 → 0x1df, with the symbol; 500 → 0x1f4, symbol-less.
        XCTAssertTrue(stackLine.contains("FoundryX@aabbccdd+0x1df:CaptureManager.rebuild"))
        XCTAssertTrue(stackLine.contains("FoundryX@aabbccdd+0x1f4"))
        XCTAssertTrue(stackLine.contains("libsystem_kernel.dylib@11111111+0x10"))
        XCTAssertFalse(stackLine.contains(";trunc"), "nothing dropped → no trunc marker")

        // The image table carries the FULL UUID (lowercased) for the compact uuid8, deduped.
        XCTAssertTrue(imgLine.hasPrefix("perf build=166 dev=a1b2c3d4 hangimg ms=650 imgs="))
        XCTAssertTrue(imgLine.contains("aabbccdd=aabbccdd-1122-3344-5566-77889900aabb"))
        XCTAssertTrue(imgLine.contains("11111111=11111111-2222-3333-4444-555555555555"))
    }

    // AC1 — the image table dedups: two frames from the SAME binary → ONE image entry.
    func testImageTableDedup() {
        let parse = PerfHangStack.parse(fromTreeJSON: fixtureTreeJSON())
        let lines = PerfDiag.hangStackLines(ms: 1, frames: parse.frames, truncated: false, ctx: ctx)
        let imgLine = try! XCTUnwrap(lines.first { $0.contains(" hangimg ") })
        // FoundryX appears in two frames but must contribute a single image entry.
        let occurrences = imgLine.components(separatedBy: "aabbccdd=").count - 1
        XCTAssertEqual(occurrences, 1, "the FoundryX image is deduped to one table entry")
    }

    // AC3 — the EXISTING single-frame hang line is emitted UNCHANGED (byte-for-byte).
    func testExistingHangLineUnchanged() {
        let line = PerfDiag.hang(ms: 650, blamedFrame: "CaptureManager.rebuild", ctx: ctx)
        XCTAssertEqual(line, "perf build=166 dev=a1b2c3d4 hang ms=650 at=CaptureManager.rebuild")
    }

    // AC2 — an oversized tree (500 frames) is capped ≤4KB total, marks ;trunc on the last
    // hangstack line, and every emitted line still matches the `perf …` grammar.
    func testSizeCapAndTruncationMarker() {
        // Long symbols so the BYTE budget (not the frame count) is the limiter.
        let frames = (0..<500).map { i in
            PerfStackFrame(binaryName: "FoundryX",
                           binaryUUID: "AABBCCDD-1122-3344-5566-77889900AABB",
                           offset: i,
                           symbol: "SomeVeryLongDescriptiveSymbolName.method.deeplyNested\(i)")
        }
        let lines = PerfDiag.hangStackLines(ms: 48000, frames: frames, truncated: false, ctx: ctx)

        let total = lines.reduce(0) { $0 + $1.utf8.count + 1 }   // +1 newline each
        XCTAssertLessThanOrEqual(total, 4096, "total across all lines stays within 4KB")
        for line in lines {
            XCTAssertTrue(line.hasPrefix("perf "), "every line keeps the grep-anchored grammar")
            XCTAssertLessThanOrEqual(line.utf8.count, 1500, "no line exceeds the per-line cap")
        }
        let stackLines = lines.filter { $0.contains(" hangstack ") }
        XCTAssertTrue(stackLines.last?.hasSuffix(";trunc") ?? false,
                      "frames dropped for the cap → explicit ;trunc on the last hangstack line")
        // Chunk indices are 1-based and consistent (t=i/k).
        XCTAssertTrue(stackLines.first?.contains("t=1/\(stackLines.count) ") ?? false)
    }

    // AC2 — a parser-level frame-count cap sets truncated → ;trunc even when the bytes fit.
    func testFrameCapTruncation() {
        // A 10-deep chain, parsed with maxFrames=3.
        var frame = "{ \"binaryName\": \"FoundryX\", \"binaryUUID\": \"AABBCCDD-1122-3344-5566-77889900AABB\", \"offsetIntoBinaryTextSegment\": 0 }"
        for i in 1..<10 {
            frame = "{ \"binaryName\": \"FoundryX\", \"binaryUUID\": \"AABBCCDD-1122-3344-5566-77889900AABB\", \"offsetIntoBinaryTextSegment\": \(i), \"subFrames\": [\(frame)] }"
        }
        let json = "{ \"callStacks\": [ { \"threadAttributed\": true, \"callStackRootFrames\": [\(frame)] } ] }"
        let parse = PerfHangStack.parse(fromTreeJSON: Data(json.utf8), maxFrames: 3)
        XCTAssertEqual(parse.frames.count, 3)
        XCTAssertTrue(parse.truncated, "more frames than the cap → truncated")
        let lines = PerfDiag.hangStackLines(ms: 100, frames: parse.frames, truncated: parse.truncated, ctx: ctx)
        XCTAssertTrue(lines.filter { $0.contains(" hangstack ") }.last?.hasSuffix(";trunc") ?? false)
    }

    // AC2 — hostile binary names (spaces / '@' / ';' / newlines) can NOT corrupt the
    // `;`-separated frame grammar: they are sanitized to single tokens.
    func testHostileNamesCannotCorruptGrammar() {
        let frames = [
            PerfStackFrame(binaryName: "evil name;with@delims\nand newline",
                           binaryUUID: "AABBCCDD-1122-3344-5566-77889900AABB",
                           offset: 1, symbol: "sym;with@semis and spaces"),
            PerfStackFrame(binaryName: "Second",
                           binaryUUID: "11111111-2222-3333-4444-555555555555",
                           offset: 2, symbol: nil),
        ]
        let lines = PerfDiag.hangStackLines(ms: 1, frames: frames, truncated: false, ctx: ctx)
        let stackLine = try! XCTUnwrap(lines.first { $0.contains(" hangstack ") })
        // The fr= payload must split into EXACTLY 2 frame tokens on ';' — hostile chars
        // were neutralized, so no extra phantom tokens appeared.
        let frPart = stackLine.range(of: "fr=").map { String(stackLine[$0.upperBound...]) } ?? ""
        let tokens = frPart.split(separator: ";")
        XCTAssertEqual(tokens.count, 2, "two frames → exactly two ';'-separated tokens")
        for token in tokens {
            XCTAssertFalse(token.contains(" "), "no spaces inside a token")
            XCTAssertFalse(token.contains("\n"), "no newlines inside a token")
        }
        XCTAssertFalse(stackLine.contains("evil name"), "the space in the binary name was sanitized")
    }
}
