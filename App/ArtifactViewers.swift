// ArtifactViewers — in-app rendering for chat/run file outputs (track
// 20260713T0906 AC3, fullflow v8). Markdown renders natively (simple block
// renderer over AttributedString inline markdown), HTML in a DISPLAY-ONLY
// WKWebView (no script message handlers, no JS bridges, link navigation
// blocked), images natively; anything else gets an honest "can't preview" row
// with a share/export button. Bytes arrive through the ArtifactSource seam —
// production is DoorArtifactSource, the same relay-aware door file-route
// pattern capture transcript/audio already ride.
//
// ENTRY POINT (integration): give `ArtifactPane(path:source:)` a door file path
// (e.g. a run output the door serves) and a source —
// `DoorArtifactSource(target:log:)` in the app, a stub in previews. A chat row
// that references a produced file can present this in a sheet.

import SwiftUI
import Grain
import WebKit
// (FoundryXKit types are same-module — the App target compiles Sources/FoundryXKit directly)

// MARK: - Loading pane (fetch → classify → render)

struct ArtifactPane: View {
    let path: String
    var filename: String? = nil
    var mime: String? = nil
    let source: any ArtifactSource

    @State private var state: ArtifactLoadState?

    var body: some View {
        Group {
            switch state {
            case nil:
                HStack(spacing: GrainSpacing.x2) {
                    GrainSpinner(size: 16)
                    Text("Fetching from your desktop…")
                        .grainTextStyle(.caption)
                        .foregroundStyle(GrainColor.textMuted)
                    Spacer(minLength: 0)
                }
                .padding(GrainSpacing.x4)
            case .unavailable:
                honestRow("This file isn't available from your desktop right now.")
            case .failed(let detail):
                honestRow("Couldn't fetch the file: \(detail)")
            case .loaded(let artifact):
                ArtifactView(artifact: artifact)
            }
        }
        .grainBackground()
        .task {
            state = await ArtifactLoader.load(
                path: path, filename: filename, mime: mime, from: source)
        }
    }

    private func honestRow(_ text: String) -> some View {
        HStack(spacing: GrainSpacing.x3) {
            Image(grain: .doc)
                .font(.system(size: 16))
                .foregroundStyle(GrainColor.textFaint)
            Text(text)
                .grainTextStyle(.caption)
                .foregroundStyle(GrainColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(GrainSpacing.x4)
        .accessibilityIdentifier("artifact-unavailable")
    }
}

// MARK: - Renderer switch

struct ArtifactView: View {
    let artifact: LoadedArtifact

    var body: some View {
        switch artifact.kind {
        case .markdown:
            MarkdownArtifactView(text: String(decoding: artifact.data, as: UTF8.self))
        case .html:
            HTMLArtifactView(html: String(decoding: artifact.data, as: UTF8.self))
        case .image:
            ImageArtifactView(data: artifact.data, filename: artifact.filename)
        case .unsupported:
            CantPreviewRow(filename: artifact.filename, data: artifact.data)
        }
    }
}

// MARK: - Markdown (native, simple block renderer)

/// Blank-line-separated blocks: ATX headings styled by level, fenced code in a
/// monospaced sunken block, everything else through AttributedString's inline
/// markdown (bold/italic/links/code spans). Honest and dependency-free.
struct MarkdownArtifactView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GrainSpacing.x3) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(GrainSpacing.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("artifact-markdown")
    }

    private var blocks: [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder private func blockView(_ block: String) -> some View {
        if block.hasPrefix("#") {
            let level = block.prefix(while: { $0 == "#" }).count
            Text(String(block.drop(while: { $0 == "#" || $0 == " " })))
                .font(.system(size: level <= 1 ? 24 : level == 2 ? 20 : 17,
                              weight: .semibold))
                .foregroundStyle(GrainColor.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else if block.hasPrefix("```") {
            Text(stripFences(block))
                .grainTextStyle(.caption)
                .monospaced()
                .foregroundStyle(GrainColor.textMain)
                .fixedSize(horizontal: false, vertical: true)
                .padding(GrainSpacing.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GrainColor.backgroundSunken)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(inline(block))
                .grainTextStyle(.body)
                .foregroundStyle(GrainColor.textMain)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stripFences(_ block: String) -> String {
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - HTML (WKWebView, display only)

/// Display-only web view: default configuration with NO script message handlers
/// (no JS bridges into the app) and link navigation blocked — the document
/// renders, nothing navigates away or talks back.
struct HTMLArtifactView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow only the initial loadHTMLString render; block link-outs.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

// MARK: - Images (native)

struct ImageArtifactView: View {
    let data: Data
    let filename: String

    var body: some View {
        if let image = UIImage(data: data) {
            ScrollView {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(GrainSpacing.x4)
            }
            .accessibilityIdentifier("artifact-image")
        } else {
            // Bytes said image but don't decode — fall back to the honest row.
            CantPreviewRow(filename: filename, data: data)
        }
    }
}

// MARK: - Unsupported (honest row + export)

struct CantPreviewRow: View {
    let filename: String
    let data: Data

    @State private var exportURL: URL?

    var body: some View {
        HStack(spacing: GrainSpacing.x3) {
            Image(grain: .doc)
                .font(.system(size: 16))
                .foregroundStyle(GrainColor.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename.isEmpty ? "File" : filename)
                    .grainTextStyle(.body)
                    .foregroundStyle(GrainColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Can't preview this file type here.")
                    .grainTextStyle(.caption)
                    .foregroundStyle(GrainColor.textMuted)
            }
            Spacer(minLength: 0)
            if let exportURL {
                ShareLink(item: exportURL) {
                    Text("Export")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GrainColor.forgeBlue)
                        .padding(.horizontal, GrainSpacing.x3)
                        .padding(.vertical, GrainSpacing.x1)
                        .overlay(Capsule().strokeBorder(GrainColor.forgeBlueBorder, lineWidth: 1))
                }
                .accessibilityIdentifier("artifact-export")
            }
        }
        .padding(GrainSpacing.x3)
        .background(GrainColor.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("artifact-cant-preview")
        .onAppear { prepareExport() }
    }

    /// Stage the bytes as a real file so the share sheet exports with the name.
    private func prepareExport() {
        guard exportURL == nil else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename.isEmpty ? "artifact" : filename)
        do {
            try data.write(to: url)
            exportURL = url
        } catch {
            exportURL = nil
        }
    }
}
