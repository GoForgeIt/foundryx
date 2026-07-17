// PerfHangStack — the PURE, testable core that turns an MXHangDiagnostic's
// call-stack tree into compact, size-capped `perf … hangstack/hangimg` lines
// (track 20260717T0448). MetricKit itself is NEVER linked here: the App-side
// subscriber (PerfMetricsSubscriber.swift) hands us `callStackTree.jsonRepresentation()`
// and we parse the documented JSON shape, so `swift test` covers the wire format on
// macOS.
//
// WHY the full tree, not just the top frame: our hang logger used to record only the
// FIRST own frame, which symbolicates to main/run-loop — useless for the recurring
// 650ms and the 48s hangs we can't attribute. Shipping every frame as
// `binaryName@<uuid8>+0x<offset>` (plus a full-UUID image table) lets us `atos` any
// frame off-line against the archived dSYM, for both hang classes, across the fleet.
//
// The lines are size-capped (≤4KB total per diagnostic, ≤~1500B per line) so the
// newline-delimited text/plain diag pipeline forwards them intact. Truncation is an
// EXPLICIT `;trunc` token on the last hangstack line — never a silently corrupted
// grammar. Every binary name / symbol goes through the shared `PerfDiag.sanitize`, so
// spaces / '@' / ';' / newlines can't split a token or break the line grammar.

import Foundation

/// One frame of a hang call stack. `binaryUUID` is the FULL image UUID (for the
/// image table + dSYM lookup); `offset` is the stable offset into the binary's text
/// segment (ASLR-independent, so symbolicable off-device); `symbol` is present only
/// when MetricKit already carried a symbol name.
public struct PerfStackFrame: Equatable, Sendable {
    public let binaryName: String
    public let binaryUUID: String
    public let offset: Int
    public let symbol: String?

    public init(binaryName: String, binaryUUID: String, offset: Int, symbol: String?) {
        self.binaryName = binaryName
        self.binaryUUID = binaryUUID
        self.offset = offset
        self.symbol = symbol
    }
}

/// The result of walking a call-stack tree: the (frame-capped) frames plus whether the
/// walk dropped any frames for the cap (so the formatter can mark `;trunc`).
public struct PerfHangStackParse: Equatable, Sendable {
    public let frames: [PerfStackFrame]
    public let truncated: Bool

    public init(frames: [PerfStackFrame], truncated: Bool) {
        self.frames = frames
        self.truncated = truncated
    }
}

/// Parses MetricKit's `callStackTree` JSON into a flat, depth-first frame list with the
/// hung (attributed) thread FIRST. Pure — no MetricKit import.
public enum PerfHangStack {

    /// Walk the tree JSON. Shape (MetricKit-documented):
    /// `{ callStacks: [ { threadAttributed: Bool, callStackRootFrames: [ {
    ///    binaryName, binaryUUID, offsetIntoBinaryTextSegment, symbolName?, subFrames:[…]
    /// } ] } ] }`.
    ///
    /// - Stacks with `threadAttributed == true` (the HUNG thread) are emitted first, in
    ///   original order; the rest follow.
    /// - Each stack is walked depth-first: a root frame, then its `subFrames` recursively.
    /// - `maxFrames` bounds the flat list; hitting it (or deeper frames skipped for it)
    ///   sets `truncated`.
    public static func parse(fromTreeJSON data: Data, maxFrames: Int = 40) -> PerfHangStackParse {
        guard maxFrames > 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = obj["callStacks"] as? [[String: Any]] else {
            return PerfHangStackParse(frames: [], truncated: false)
        }
        // Attributed (hung) thread first, preserving order within each group.
        let attributed = stacks.filter { ($0["threadAttributed"] as? Bool) ?? false }
        let rest = stacks.filter { !(($0["threadAttributed"] as? Bool) ?? false) }
        let ordered = attributed + rest

        var out: [PerfStackFrame] = []
        var truncated = false

        func walk(_ frame: [String: Any]) {
            if out.count >= maxFrames { truncated = true; return }
            let bin = frame["binaryName"] as? String ?? "?"
            let uuid = frame["binaryUUID"] as? String ?? ""
            // MetricKit encodes the offset as an integer; tolerate a string too.
            let off = (frame["offsetIntoBinaryTextSegment"] as? Int)
                ?? Int(frame["offsetIntoBinaryTextSegment"] as? String ?? "") ?? 0
            let sym = (frame["symbolName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(PerfStackFrame(binaryName: bin, binaryUUID: uuid, offset: off, symbol: sym))
            for sub in (frame["subFrames"] as? [[String: Any]]) ?? [] {
                if out.count >= maxFrames { truncated = true; return }
                walk(sub)
            }
        }

        for stack in ordered {
            for root in (stack["callStackRootFrames"] as? [[String: Any]]) ?? [] {
                if out.count >= maxFrames { truncated = true; break }
                walk(root)
            }
            if out.count >= maxFrames { truncated = true; break }
        }
        return PerfHangStackParse(frames: out, truncated: truncated)
    }
}

public extension PerfDiag {

    /// The first 8 hex of an image UUID, dashes stripped + lowercased (the compact form
    /// used in frame tokens; the full UUID lives once in the image table). Matches the
    /// existing single-frame `slidBlame` short form.
    static func uuid8(_ uuid: String) -> String {
        String(uuid.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    /// One frame token: `<binaryName>@<uuid8>+0x<offset>[:<symbol>]`. Name + symbol are
    /// sanitized so no space/'@'/';'/newline can corrupt the `;`-separated frame list.
    static func hangFrameToken(_ f: PerfStackFrame) -> String {
        var t = "\(sanitize(f.binaryName))@\(uuid8(f.binaryUUID))+0x\(String(f.offset, radix: 16))"
        if let s = f.symbol, !s.isEmpty { t += ":\(sanitize(s))" }
        return t
    }

    /// Serialize a hang's call tree into shippable lines:
    ///   `perf … <kind> ms=<ms> t=<i>/<k> fr=<frame>;<frame>;…`   (one or more,
    ///        `t=<i>/<k>` = chunk i of k in emit order, so the server can reassemble)
    ///   `perf … <kind-img> ms=<ms> imgs=<uuid8>=<FULL-UUID>;…`   (ONE line, deduped,
    ///        only images referenced by an emitted frame)
    ///
    /// `kind` selects the line's verb — `hangstack` (MetricKit hang, DEFAULT so existing
    /// callers stay byte-identical), `stallstack` (live sampled main-thread stall), or
    /// `cpustack` (MetricKit CPU exception). The image line's verb is derived from it
    /// (`hangimg`/`stallimg`/`cpuimg`) by swapping `stack`→`img`.
    ///
    /// Bounded: total across ALL lines ≤ `maxTotalBytes` (4096) and each line
    /// ≤ `maxLineBytes` (~1500). If frames are dropped for EITHER cap (the parser's
    /// frame cap OR the byte budget), the LAST stack line ends with a literal
    /// `;trunc` token. Empty input → no lines.
    static func hangStackLines(ms: Int,
                               frames: [PerfStackFrame],
                               truncated: Bool,
                               ctx: PerfContext,
                               kind: String = "hangstack",
                               maxLineBytes: Int = 1500,
                               maxTotalBytes: Int = 4096) -> [String] {
        guard !frames.isEmpty else { return [] }

        // The image line's verb: `hangstack`→`hangimg`, `stallstack`→`stallimg`, etc.
        let imgLabel = kind.replacingOccurrences(of: "stack", with: "img")

        // A fixed head estimate for accounting. Real `t=<i>/<k>` is rendered at the end;
        // "t=00/00" over-reserves 2 digits per side, and `truncMargin` covers any slack
        // (incl. the trailing ";trunc"), so the true bytes never exceed the caps.
        let stackHead = "\(head(ctx)) \(kind) ms=\(ms) t=00/00 fr="
        let headBytes = stackHead.utf8.count
        let imgHeadBytes = "\(head(ctx)) \(imgLabel) ms=\(ms) imgs=".utf8.count
        let truncMargin = ";trunc".utf8.count + 8

        // Bytes the image line would occupy for the currently-referenced images.
        func imageBytes(_ imgs: [(short: String, full: String)]) -> Int {
            guard !imgs.isEmpty else { return 0 }
            let body = imgs.map { "\($0.short)=\($0.full)" }.joined(separator: ";")
            return imgHeadBytes + body.utf8.count + 1   // +1 newline
        }

        var chunks: [[String]] = [[]]        // token groups → one hangstack line each
        var chunkBytes = headBytes           // bytes of the current (last) chunk line
        var images: [(short: String, full: String)] = []
        var seenShort = Set<String>()
        var dropped = truncated              // parser may already have dropped frames

        for f in frames {
            let token = hangFrameToken(f)
            let addBytes = token.utf8.count + 1   // +1 for ';' separator / newline

            // New chunk when the current hangstack line would exceed the per-line cap.
            let needNewChunk = !chunks[chunks.count - 1].isEmpty
                && chunkBytes + addBytes > maxLineBytes

            // Project this frame's (possibly new) image-table entry.
            let short = uuid8(f.binaryUUID)
            let newImage = (!short.isEmpty && !seenShort.contains(short))
                ? [(short: short, full: sanitize(f.binaryUUID.lowercased()))] : []
            let projectedImageBytes = imageBytes(images + newImage)

            // Total = every rendered stack line + the projected image line + margin.
            let stackLinesBytes = chunks.reduce(0) { acc, c in
                acc + (c.isEmpty ? 0 : headBytes + c.reduce(0) { $0 + $1.utf8.count + 1 })
            }
            let projectedTotal = stackLinesBytes
                + (needNewChunk ? headBytes + addBytes : addBytes)
                + projectedImageBytes + truncMargin

            if projectedTotal > maxTotalBytes {
                dropped = true
                break   // byte budget hit → stop; the ;trunc marker is added below
            }
            if needNewChunk {
                chunks.append([])
                chunkBytes = headBytes
            }
            chunks[chunks.count - 1].append(token)
            chunkBytes += addBytes
            if !newImage.isEmpty { images.append(newImage[0]); seenShort.insert(short) }
        }

        // Drop a trailing empty chunk (can happen if the first frame already overflowed).
        if chunks.count > 1, chunks[chunks.count - 1].isEmpty { chunks.removeLast() }
        guard !chunks.isEmpty, !chunks[0].isEmpty else { return [] }

        // Render the hangstack lines with the real chunk index / count.
        let k = chunks.count
        var lines: [String] = []
        for (i, tokens) in chunks.enumerated() {
            var body = tokens.joined(separator: ";")
            if dropped && i == k - 1 { body += ";trunc" }   // explicit truncation marker
            lines.append("\(head(ctx)) \(kind) ms=\(ms) t=\(i + 1)/\(k) fr=\(body)")
        }
        // The image table (full UUIDs for dSYM lookup), deduped, referenced images only.
        if !images.isEmpty {
            let body = images.map { "\($0.short)=\($0.full)" }.joined(separator: ";")
            lines.append("\(head(ctx)) \(imgLabel) ms=\(ms) imgs=\(body)")
        }
        return lines
    }
}
