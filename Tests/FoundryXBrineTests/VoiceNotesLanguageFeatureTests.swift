import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/voice-notes-language.feature. It reads the real App sources,
/// drives the real user-facing presentation constants, and proves the language-only change
/// leaves real CaptureLibrary directories and transcript bytes untouched.
final class VoiceNotesLanguageFeatureTests: XCTestCase {
    func testVoiceNotesLanguageFeature() async throws {
        try await BrineFeatureRunner.run(
            "voice-notes-language",
            registry: StepRegistry(VoiceNotesLanguageSteps.make(
                world: VoiceNotesLanguageWorld())))
    }
}

private final class VoiceNotesLanguageWorld: @unchecked Sendable {
    let repositoryRoot: URL
    let baseDir: URL
    var appSources: [(name: String, text: String)] = []
    var originalNoteIDs: Set<String> = []
    var originalTranscripts: [String: Data] = [:]

    init() {
        repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "foundryx-voice-notes-language-\(UUID().uuidString)",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: baseDir)
    }

    func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    func loadAppSources() throws {
        let appDirectory = repositoryRoot.appendingPathComponent(
            "App",
            isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > 5 else {
            throw BrineStepError(
                "source guard saw only \(files.count) App Swift files")
        }
        appSources = try files.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
        }
    }

    func offenses(matching term: String) -> [String] {
        appSources.flatMap { source -> [String] in
            // Prompt engines are skipped only while they render nothing — the guard
            // re-covers them the moment one grows a view.
            if VoiceNotesLanguage.isPromptEngine(fileName: source.name, source: source.text) {
                return []
            }
            return VoiceNotesLanguage.offendingStringLiterals(in: source.text)
                .filter {
                    $0.range(
                        of: #"\b\#(term)\w*\b"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
                }
                .map { "App/\(source.name): \"\($0)\"" }
        }
    }

    func seedEarlierNotes() throws {
        try? FileManager.default.removeItem(at: baseDir)
        try FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true)

        let notes = [
            ("omi-20260701T080000-legacy", "The older Omi transcript."),
            ("mic-20260702T090000-legacy", "The older phone transcript."),
        ]
        for (id, transcript) in notes {
            let directory = baseDir.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            let data = Data(transcript.utf8)
            try data.write(
                to: directory.appendingPathComponent("transcript.txt"),
                options: [.atomic])
            originalNoteIDs.insert(id)
            originalTranscripts[id] = data
        }

        guard CaptureLibrary.noteCount(baseDir: baseDir) == notes.count else {
            throw BrineStepError("real CaptureLibrary did not see the seeded notes")
        }
    }

    func currentNoteIDs() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: baseDir.path)
            .filter(CaptureLibrary.isNoteDirectory))
    }

    func currentTranscript(for id: String) throws -> Data {
        try Data(contentsOf: baseDir
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("transcript.txt"))
    }
}

private enum VoiceNotesLanguageSteps {
    static func make(world w: VoiceNotesLanguageWorld) -> [StepDefinition] {
        [
            defineStep("I open the app") { ctx, _, _ in
                try w.loadAppSources()
                return ctx
            },
            defineCheck("the library speaks about voice notes") { _, _, _ in
                let copy = try w.source(
                    "Sources/FoundryXKit/CaptureCardPresentation.swift")
                guard copy.contains("voice note") else {
                    throw BrineStepError(
                        "CaptureHomeCopy does not call library items voice notes")
                }
            },
            defineCheck("the library does not speak about recording conversations") {
                _, _, _ in
                let sources = [
                    try w.source("App/CaptureScreen.swift"),
                    try w.source(
                        "Sources/FoundryXKit/CaptureCardPresentation.swift"),
                ]
                let offenses = sources.flatMap {
                    VoiceNotesLanguage.offendingStringLiterals(in: $0)
                }
                guard offenses.isEmpty else {
                    throw BrineStepError(
                        "library copy still uses retired language: \(offenses)")
                }
            },

            defineStep("my library is empty") { ctx, _, _ in
                try? FileManager.default.removeItem(at: w.baseDir)
                try FileManager.default.createDirectory(
                    at: w.baseDir,
                    withIntermediateDirectories: true)
                guard CaptureLibrary.isEmpty(baseDir: w.baseDir) else {
                    throw BrineStepError("real CaptureLibrary was not empty")
                }
                return ctx
            },
            defineCheck("I am invited to make my first voice note") { _, _, _ in
                let source = try w.source("App/CaptureScreen.swift")
                guard source.localizedCaseInsensitiveContains(
                    "first voice note") else {
                    throw BrineStepError(
                        "empty library has no first-voice-note invitation")
                }
            },

            defineStep("I am in my library") { ctx, _, _ in
                try w.loadAppSources()
                return ctx
            },
            defineCheck("the control that starts capture speaks about a voice note") {
                _, _, _ in
                guard CaptureHomeCopy.recordTitle == "Make a voice note" else {
                    throw BrineStepError(
                        "capture control says \"\(CaptureHomeCopy.recordTitle)\"")
                }
            },

            defineStep("a voice note is being captured") { ctx, _, _ in
                return ctx
            },
            defineCheck("the app describes it as a voice note in progress") {
                _, _, _ in
                let word = RecordingPillPresentation.make(
                    from: .recordingActive).word
                guard word == "Taking a note" else {
                    throw BrineStepError(
                        "active capture is described as \"\(word)\"")
                }
            },

            defineStep("the app's user-facing copy") { ctx, _, _ in
                try w.loadAppSources()
                return ctx
            },
            defineCheck("no user-facing text calls a voice note a recording") {
                _, _, _ in
                let offenses = w.offenses(matching: "record")
                guard offenses.isEmpty else {
                    throw BrineStepError(
                        "retired recording language:\n"
                            + offenses.joined(separator: "\n"))
                }
            },
            defineCheck("no user-facing text calls my library a list of conversations") {
                _, _, _ in
                let offenses = w.offenses(matching: "conversation")
                guard offenses.isEmpty else {
                    throw BrineStepError(
                        "retired conversations language:\n"
                            + offenses.joined(separator: "\n"))
                }
            },

            defineStep("I made voice notes before the language changed") {
                ctx, _, _ in
                try w.seedEarlierNotes()
                return ctx
            },
            defineCheck("all of my earlier notes are still in my library") {
                _, _, _ in
                let currentIDs = try w.currentNoteIDs()
                guard CaptureLibrary.noteCount(baseDir: w.baseDir)
                        == w.originalNoteIDs.count,
                      currentIDs == w.originalNoteIDs else {
                    throw BrineStepError(
                        "note directories or ids changed: expected "
                            + "\(w.originalNoteIDs.sorted()), found "
                            + "\(currentIDs.sorted())")
                }
            },
            defineCheck("their transcripts are unchanged") { _, _, _ in
                for (id, original) in w.originalTranscripts {
                    let current = try w.currentTranscript(for: id)
                    guard current == original else {
                        throw BrineStepError(
                            "transcript bytes changed for \(id)")
                    }
                }
            },
        ]
    }
}
