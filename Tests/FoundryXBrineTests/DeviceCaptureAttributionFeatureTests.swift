import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for `features/device-capture-attribution.feature` (track
/// 20260725T2306_device_agnostic_recording_source, task T4 — the archive sidecar half).
///
/// WHAT THIS OWNS. The plan's T4 body assigns T4 the IMPLEMENTATION of `capture-finalize`,
/// `capture-integrity` and `archive-attribution`; T5 (S01, S02, S05, S06, S07) and T8 (P01)
/// declare T4 as a dependency for them. S04's seam suite asserts the reconnect; this suite
/// asserts the identity those downstream tasks will render and reason about.
///
/// NOTHING IS ASKED TO DISCOVER ITSELF. `OmiRestorationSpool.init` is never asked to find an
/// account scope or a saved device — the composition root resolves a typed
/// `CaptureDeviceContext` and hands it in. That is why the factory is a Kit-level type
/// rather than a block of `App/`: `swift test` cannot compile `App/` at all, so a
/// composition that lived there would be unfalsifiable by construction.
final class DeviceCaptureAttributionFeatureTests: ProcessGlobalStateTestCase {

    func testDeviceCaptureAttributionFeature() async throws {
        let world = DeviceCaptureAttributionWorld()
        do {
            // Pin the POPULATION: the runner asserts only that nothing FAILED, so deleting
            // a scenario would otherwise leave this suite green.
            let result = try await BrineFeatureRunner.run(
                "device-capture-attribution",
                registry: StepRegistry(DeviceCaptureAttributionSteps.make(world: world)))
            XCTAssertEqual(result.passed, 9,
                           "device-capture-attribution must run all 9 scenarios")
        } catch {
            await world.teardown()
            throw error
        }
        await world.teardown()
    }

    /// The migration discriminator must read DURABLE data and never the filesystem — plan
    /// law, and for a concrete reason: every copy, restore-from-backup, or iCloud
    /// materialisation rewrites file dates, so an mtime-based answer would reclassify a
    /// user's whole archive on a device migration.
    ///
    /// This proves the classification is unmoved by touching the files, and that it uses
    /// BOTH durable sources in the right order.
    func testProvenanceIsDatedFromDurableDataAndNotTheFilesystem() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let epoch = CaptureDeviceSidecar.migrationEpoch

        // (a) durable conversation metadata wins, and it says PRE-upgrade.
        let old = "omi-20200101-000000-AAAA0001"
        try Self.makeCaptureDir(old, in: dir)
        ConversationMetaStore.recordStart(captureId: old, baseDir: dir, at: epoch - 10_000)
        XCTAssertEqual(CaptureDeviceSidecar.provenance(captureId: old, baseDir: dir),
                       .legacyPreMigration)

        // Touching every file to NOW must not move it. An mtime-based implementation
        // reclassifies here; this one cannot see the filesystem's opinion at all.
        try Self.touchEverything(in: dir.appendingPathComponent(old), to: Date())
        XCTAssertEqual(CaptureDeviceSidecar.provenance(captureId: old, baseDir: dir),
                       .legacyPreMigration,
                       "the classification moved when file dates moved — it is reading mtime")

        // (b) no metadata: the capture id's embedded stamp is the fallback, and it is
        // still durable (it is part of the identity, not a file attribute).
        let idOnly = "omi-20200101-000000-AAAA0002"
        try Self.makeCaptureDir(idOnly, in: dir)
        XCTAssertEqual(CaptureDeviceSidecar.provenance(captureId: idOnly, baseDir: dir),
                       .legacyPreMigration)

        // (c) post-upgrade with no sidecar is UNKNOWN, not legacy — the case T5 renders
        // with a diagnostic.
        let recent = "omi-20990101-000000-AAAA0003"
        try Self.makeCaptureDir(recent, in: dir)
        ConversationMetaStore.recordStart(captureId: recent, baseDir: dir, at: epoch + 10_000)
        guard case .unknownPostMigration = CaptureDeviceSidecar.provenance(captureId: recent,
                                                                          baseDir: dir) else {
            return XCTFail("a post-upgrade capture with no device record was not reported unknown")
        }

        // (d) undatable is its own answer — never guessed post-upgrade.
        let undatable = "restored-capture-with-no-stamp"
        try Self.makeCaptureDir(undatable, in: dir)
        guard case .undatable = CaptureDeviceSidecar.provenance(captureId: undatable,
                                                               baseDir: dir) else {
            return XCTFail("an undatable capture was classified rather than reported undatable")
        }

        // (e) a sidecar outranks all of it: the device is KNOWN.
        let identified = "omi-20990101-000000-AAAA0004"
        try Self.makeCaptureDir(identified, in: dir)
        let context = CaptureDeviceContext(
            identity: RecordingDeviceIdentity(shape: .bleStream, hardwareToken: "dev-1"),
            displayName: "Omi",
            accountScope: "acct-test")
        XCTAssertTrue(CaptureDeviceSidecar.write(context, captureId: identified, baseDir: dir))
        XCTAssertEqual(CaptureDeviceSidecar.provenance(captureId: identified, baseDir: dir),
                       .identified(context))
    }

    // MARK: helpers

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-capture-attribution-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeCaptureDir(_ id: String, in baseDir: URL) throws {
        try FileManager.default.createDirectory(
            at: baseDir.appendingPathComponent(id, isDirectory: true),
            withIntermediateDirectories: true)
    }

    static func touchEverything(in dir: URL, to date: Date) throws {
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try fm.setAttributes([.modificationDate: date],
                                 ofItemAtPath: dir.appendingPathComponent(name).path)
        }
    }
}

// MARK: - World

final class DeviceCaptureAttributionWorld: @unchecked Sendable {
    var baseDir: URL!
    var stack: FakeBLEStack!
    var device: DeviceManager!
    var capture: CaptureManager!
    var spool: OmiRestorationSpool!
    let pairing = DeviceGlobalPairing()

    var deviceId = UUID()
    var appConversation: String?
    var spoolConversation: String?
    var seededConversation: String?
    var resolution: CaptureDeviceContextResolution?
    var continuation: String?
    var provenance: CaptureDeviceProvenance?
    /// The conversation the HANDSET opened, and the record it left.
    var handsetConversation: String?
    var handsetConversationNoDevice: String?
    /// Device B's world: its own manager, its own spool, and what each opened.
    var deviceBIdentity: RecordingDeviceIdentity?
    var deviceBManagerConversation: String?
    var deviceBSpoolConversation: String?
    var deviceAReopened: String?
    /// The restoration spool's OWN capture root — see `openThroughSpool`.
    var spoolRoot: URL?
    var deviceASpoolResumed: String?
    /// The capture whose device record was deliberately corrupted.
    var corruptedConversation: String?

    private var directories: [URL] = []
    /// Extra managers built by the two-device scenario; held so nothing deallocates mid-run.
    var managers: [CaptureManager] = []

    var identity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .bleStream, hardwareToken: deviceId.uuidString)
    }

    /// A different SHAPE as well as a different token — the plan's rule is that matching is
    /// on `(shape, deviceId)`, so a probe that differed only in the token could pass against
    /// an implementation that compared the token alone.
    var otherIdentity: RecordingDeviceIdentity {
        RecordingDeviceIdentity(shape: .audioRoute, hardwareToken: UUID().uuidString)
    }

    var scope: String {
        CaptureAccountScope.currentAccountBinding()?.scope ?? "acct-unknown"
    }

    var binding: CaptureAccountScope.AccountBinding? {
        CaptureAccountScope.currentAccountBinding()
    }

    @MainActor
    func freshHandset() throws {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundryx-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        directories.append(baseDir)
        appConversation = nil
        spoolConversation = nil
        seededConversation = nil
        resolution = nil
        continuation = nil
        provenance = nil
        handsetConversation = nil
        handsetConversationNoDevice = nil
        deviceBIdentity = nil
        deviceBManagerConversation = nil
        deviceBSpoolConversation = nil
        deviceAReopened = nil
        spoolRoot = nil
        deviceASpoolResumed = nil
        corruptedConversation = nil
        deviceId = UUID()
        pairing.stage(id: deviceId, name: "Omi")
        // `selectCaptureSource` PERSISTS to process-global `CaptureSettings`. Brine runs every
        // scenario of a feature in one process, so the handset scenario would otherwise leave
        // `.phoneMic` behind and the next scenario's cold-resume arm — which is gated on
        // `captureSource == .omi` — would silently never run. Reset it with the rest of the
        // handset state. (This suite inherits `ProcessGlobalStateTestCase`, which owns the
        // restore at tearDown; the lint gate requires exactly that.)
        CaptureSettings.captureSource = .omi
    }

    @MainActor
    func teardown() {
        managers = []
        capture = nil
        device = nil
        stack = nil
        spool = nil
        pairing.restore()
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
        directories = []
    }

    func conversationsOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// Seed a capture directory the way a real conversation leaves one: a durable start, a
    /// source marker, and one segment so the resume scan's recency test can see it.
    func seedConversation(id: String,
                          startedAt: UInt64,
                          in root: URL? = nil,
                          sourceTag: String? = CaptureSourceKind.omi.rawValue,
                          device context: CaptureDeviceContext? = nil) throws {
        let root = root ?? baseDir!
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ConversationMetaStore.recordStart(captureId: id, baseDir: root, at: startedAt)
        if let sourceTag {
            try Data(sourceTag.utf8).write(
                to: CaptureManager.sourceMarkerURL(id, baseDir: root), options: [.atomic])
        }
        if let context {
            XCTAssertTrue(CaptureDeviceSidecar.write(context, captureId: id, baseDir: root))
        }
        try Data([1, 2, 3, 4]).write(to: dir.appendingPathComponent("seg-000000000000.opus"))
        seededConversation = id
    }

    /// Record a conversation from the HANDSET'S OWN MICROPHONE, through the real
    /// `CaptureManager`, with the production context resolver `RootView` installs.
    ///
    /// `rememberADevice` is the whole point of the first arm: an Omi IS remembered and IS the
    /// remembered pairing, and the recording still must not be attributed to it.
    @MainActor
    func recordOnHandset(rememberADevice: Bool) async throws -> String {
        try freshHandset()
        if !rememberADevice { pairing.clear() }
        // BORN on the phone mic rather than switched to it. `selectCaptureSource(.phoneMic)`
        // calls `source.stop()`, whose `.stopped` reaches `onSourceState` on a LATER main-actor
        // turn — by which time `startMicRecording()` has set `isRecordingMic`, so the Omi's
        // stop is read as the MIC stopping and clears it again. That race is real in
        // production too (it is not T4's to fix), but driving it here would test the race
        // rather than the attribution. A user who already has the phone mic selected is the
        // state this scenario is about, and it has no switch in it.
        CaptureSettings.captureSource = .phoneMic
        let mic = SeamTestSource()
        stack = FakeBLEStack(deviceId: deviceId, deviceName: "Omi")
        device = DeviceManager(makeCentral: stack.factory)
        capture = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: baseDir,
            source: device,
            micSource: mic,
            finalize: { _, _ in })
        // EXACTLY what App/RootView.swift installs — no test-only shortcut. The manager hands
        // in what is recording; this closure defaults nothing.
        capture.captureDeviceContext = { [device] recording in
            OmiRestorationComposition.resolveDeviceContext(
                binding: CaptureAccountScope.currentAccountBinding(),
                savedDevice: device?.saved,
                recording: recording)
        }
        #if os(iOS)
        capture.micPermissionOverrideForTests = true   // the sim cannot drive the real prompt
        #endif
        capture.startMicRecording()
        mic.onState?(.streaming)
        try await Self.waitUntil { self.capture.active != nil }
        return try XCTUnwrapOrThrow(capture.active?.captureId, "the handset opened no conversation")
    }

    /// Drive `CaptureManager.onSourceState(.streaming)`'s COLD arm as `identity`, and report
    /// which conversation it ended up in. This is the production call site the narrowing has
    /// to be applied at — not the static function.
    @MainActor
    func openThroughManager(as identity: RecordingDeviceIdentity, named: String) async throws -> String {
        let source = SeamTestSource()
        let manager = CaptureManager(
            target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
            baseDir: baseDir,
            source: source,
            finalize: { _, _ in })
        let context = CaptureDeviceContext(identity: identity, displayName: named,
                                           accountScope: scope)
        manager.captureDeviceContext = { _ in .resolved(context) }
        managers.append(manager)
        source.onState?(.streaming)
        // The cold arm either resumes an existing capture or arms for speech; feed real voiced
        // frames so the "opened a new one" branch actually produces a conversation to compare.
        RealOmiFrames.openSession(source.onFrame)
        try await Self.waitUntil { manager.active != nil }
        return try XCTUnwrapOrThrow(manager.active?.captureId, "nothing was opened")
    }

    /// The SECOND production call site: the background-restoration spool's own resume.
    ///
    /// IT RUNS IN ITS OWN ROOT, and that is load-bearing rather than tidy (review round 9, M1).
    /// The first version of this scenario drove the spool AFTER device B's capture manager had
    /// already opened a conversation of B's own in the same directory. With the narrowing
    /// removed, the un-narrowed scan then returned whichever of the two candidates sorted
    /// first — and both were stamped in the same second, so the tie was broken by the random
    /// hex suffix of `newCaptureId()`. The mutation that proves this call site narrows
    /// therefore only reds ~80% of the time, and in the other 20% the spool had in fact
    /// continued device B's OWN conversation, which the `!=` check could not see. Here the ONLY
    /// conversation on disk when the spool runs is device A's, so "it did not continue A's" and
    /// "it opened a new one" are the same sentence, and the mutation is deterministic.
    @MainActor
    func openThroughSpool(as identity: RecordingDeviceIdentity, named: String) async throws -> String {
        let binding = try XCTUnwrapOrThrow(self.binding, "no account binding")
        let spool = OmiRestorationComposition.makeRestorationSpool(
            binding: binding, root: spoolRoot ?? baseDir,
            executor: DispatchQueue(label: "foundryx-attribution-spool-\(UUID().uuidString)"),
            log: nil, silenceGap: 120, paused: { false },
            deviceContext: .resolved(CaptureDeviceContext(identity: identity, displayName: named,
                                                          accountScope: binding.scope)))
        self.spool = spool
        spool.handleState(.streaming)
        spool.append(Data([5, 5, 5]))
        try await Self.settle { spool.activeCaptureId != nil }
        return try XCTUnwrapOrThrow(spool.activeCaptureId, "the spool opened nothing")
    }

    @MainActor
    static func waitUntil(timeout: TimeInterval = 60,
                          _ condition: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                throw BrineStepError("timed out after \(Int(timeout))s waiting for a precondition")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    static func settle(timeout: TimeInterval = 30,
                       until condition: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Steps

enum DeviceCaptureAttributionSteps {

    static func make(world w: DeviceCaptureAttributionWorld) -> [StepDefinition] {
        [
            // MARK: Given

            defineStep("a remembered recording device is active for this account") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                return ctx
            },

            defineStep("a conversation inside the silence gap was recorded by one device") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                try w.seedConversation(
                    id: CaptureManager.newCaptureId(),
                    startedAt: UInt64(Date().timeIntervalSince1970),
                    device: CaptureDeviceContext(identity: w.identity,
                                                 displayName: "Omi",
                                                 accountScope: w.scope))
                return ctx
            },

            defineStep("a conversation inside the silence gap exists with no device record and a durable start before the upgrade") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                // Durable start BEFORE the sidecar shipped, but the segment is recent — a
                // real pre-upgrade conversation the user is still in.
                try w.seedConversation(id: CaptureManager.newCaptureId(),
                                       startedAt: CaptureDeviceSidecar.migrationEpoch - 86_400)
                return ctx
            },

            defineStep("a conversation exists with no device record and nothing durable to date it by") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                // No metadata, and an id carrying no `yyyyMMdd-HHmmss` stamp.
                let id = "restored-capture-no-stamp"
                let dir = w.baseDir.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                w.seededConversation = id
                return ctx
            },

            defineStep("the account scope cannot be resolved for a background restoration") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                w.resolution = OmiRestorationComposition.resolveDeviceContext(
                    binding: nil,
                    savedDevice: SavedOmi(id: w.deviceId, name: "Omi", lastConnected: nil),
                    recording: .externalStream)
                return ctx
            },

            // MARK: When

            defineStep("the app opens a conversation") { ctx, _, _ in
                let context = CaptureDeviceContext(identity: w.identity, displayName: "Omi",
                                                   accountScope: w.scope)
                try await MainActor.run {
                    w.stack = FakeBLEStack(deviceId: w.deviceId, deviceName: "Omi")
                    w.device = DeviceManager(makeCentral: w.stack.factory)
                    w.capture = CaptureManager(
                        target: DoorTarget(baseURL: URL(string: "http://127.0.0.1:1")!, bearer: "x"),
                        baseDir: w.baseDir,
                        source: w.device,
                        finalize: { _, _ in })
                    // The composition root is what knows the device. Nothing inside
                    // CaptureManager discovers it.
                    w.capture.captureDeviceContext = { _ in .resolved(context) }
                    w.device.start()
                }
                try await DeviceCaptureAttributionWorld.waitUntil {
                    w.capture.sourceState == .streaming
                }
                w.stack.deliverAudioFrames(RealOmiFrames.cachedVoiced, count: 15)
                try await DeviceCaptureAttributionWorld.waitUntil { w.capture.active != nil }
                w.appConversation = await MainActor.run { w.capture.active?.captureId }
                return ctx
            },

            defineStep("a background restoration opens a conversation through the composition factory") { ctx, _, _ in
                // A SECOND, independent capture root, so the spool cannot be credited with
                // the conversation the app already opened.
                let root = w.baseDir.appendingPathComponent("restoration", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let binding = try XCTUnwrapOrThrow(w.binding, "no account binding for the restoration")
                let resolution = OmiRestorationComposition.resolveDeviceContext(
                    binding: binding,
                    savedDevice: SavedOmi(id: w.deviceId, name: "Omi", lastConnected: nil),
                    recording: .externalStream)
                w.resolution = resolution
                let spool = OmiRestorationComposition.makeRestorationSpool(
                    binding: binding,
                    root: root,
                    executor: DispatchQueue(label: "foundryx.attribution-spool-\(UUID().uuidString)"),
                    log: nil,
                    silenceGap: 120,
                    paused: { false },
                    deviceContext: resolution)
                w.spool = spool
                spool.handleState(.streaming)
                spool.append(Data([9, 9, 9]))
                try await DeviceCaptureAttributionWorld.settle {
                    spool.activeCaptureId != nil
                }
                w.spoolConversation = spool.activeCaptureId
                return ctx
            },

            defineStep("a differently shaped device looks for a conversation to continue") { ctx, _, _ in
                w.continuation = CaptureManager.resumableCaptureId(
                    baseDir: w.baseDir, silenceGap: 120, resumingDevice: w.otherIdentity)
                return ctx
            },

            defineStep("the device that recorded it looks for a conversation to continue") { ctx, _, _ in
                w.continuation = CaptureManager.resumableCaptureId(
                    baseDir: w.baseDir, silenceGap: 120, resumingDevice: w.identity)
                return ctx
            },

            defineStep("any device looks for a conversation to continue") { ctx, _, _ in
                w.continuation = CaptureManager.resumableCaptureId(
                    baseDir: w.baseDir, silenceGap: 120, resumingDevice: w.otherIdentity)
                return ctx
            },

            // MARK: When — H1, the handset

            defineStep("the handset's own microphone records a conversation") { ctx, _, _ in
                w.handsetConversation = try await w.recordOnHandset(rememberADevice: true)
                return ctx
            },

            defineStep("the handset records a conversation with no external device remembered at all") { ctx, _, _ in
                w.handsetConversationNoDevice = try await w.recordOnHandset(rememberADevice: false)
                return ctx
            },

            // MARK: When — M4, two devices

            defineStep("device A recorded a conversation that is still inside the silence gap") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                try w.seedConversation(
                    id: CaptureManager.newCaptureId(),
                    startedAt: UInt64(Date().timeIntervalSince1970),
                    device: CaptureDeviceContext(identity: w.identity,
                                                 displayName: "Omi A",
                                                 accountScope: w.scope))
                w.deviceBIdentity = RecordingDeviceIdentity(shape: .bleStream,
                                                            hardwareToken: UUID().uuidString)
                return ctx
            },

            defineStep("device A recorded a conversation the background restoration would find") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                // The spool's own root, holding device A's conversation and NOTHING ELSE.
                let root = w.baseDir.appendingPathComponent("restoration", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                w.spoolRoot = root
                try w.seedConversation(
                    id: CaptureManager.newCaptureId(),
                    startedAt: UInt64(Date().timeIntervalSince1970),
                    in: root,
                    device: CaptureDeviceContext(identity: w.identity,
                                                 displayName: "Omi A",
                                                 accountScope: w.scope))
                // NON-VACUITY, at the Given rather than buried in a Then: without the device
                // narrowing this conversation IS what the spool's scan returns. If it were not,
                // "device B opened a new one" would be true for free.
                guard CaptureManager.resumableCaptureId(baseDir: root, silenceGap: 120)
                        == w.seededConversation else {
                    throw BrineStepError(
                        "the un-narrowed scan does not return device A's conversation, so "
                            + "nothing is at stake in this scenario")
                }
                w.deviceBIdentity = RecordingDeviceIdentity(shape: .bleStream,
                                                            hardwareToken: UUID().uuidString)
                return ctx
            },

            defineStep("a conversation inside the silence gap has a device record that cannot be read") { ctx, _, _ in
                try await MainActor.run { try w.freshHandset() }
                let id = CaptureManager.newCaptureId()
                try w.seedConversation(
                    id: id,
                    startedAt: UInt64(Date().timeIntervalSince1970),
                    device: CaptureDeviceContext(identity: w.identity,
                                                 displayName: "Omi",
                                                 accountScope: w.scope))
                // A record that IS there and cannot be decoded — a truncated write, a bad
                // sector, a half-restored backup. The bytes are deliberately not JSON.
                try Data("{\"identity\":".utf8).write(
                    to: CaptureDeviceSidecar.url(id, baseDir: w.baseDir), options: [.atomic])
                w.corruptedConversation = id
                return ctx
            },

            defineStep("device B's capture manager sees its stream start") { ctx, _, _ in
                let b = try XCTUnwrapOrThrow(w.deviceBIdentity, "device B was never named")
                w.deviceBManagerConversation = try await w.openThroughManager(as: b, named: "Omi B")
                return ctx
            },

            defineStep("device B's background restoration spool sees its stream start") { ctx, _, _ in
                let b = try XCTUnwrapOrThrow(w.deviceBIdentity, "device B was never named")
                w.deviceBSpoolConversation = try await w.openThroughSpool(as: b, named: "Omi B")
                return ctx
            },

            defineStep("device A's capture manager sees its stream start") { ctx, _, _ in
                w.deviceAReopened = try await w.openThroughManager(as: w.identity, named: "Omi A")
                return ctx
            },

            defineStep("device A's background restoration spool sees its stream start") { ctx, _, _ in
                w.deviceASpoolResumed = try await w.openThroughSpool(as: w.identity, named: "Omi A")
                return ctx
            },

            // MARK: Then

            defineCheck("the conversation records the handset as its recorder") { _, _, _ in
                // Whichever of the two handset scenarios just ran.
                let id = try XCTUnwrapOrThrow(w.handsetConversationNoDevice ?? w.handsetConversation,
                                              "the handset opened no conversation")
                let recorded = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: id, baseDir: w.baseDir),
                    "the handset's conversation has no device record")
                guard recorded.identity.shape == .builtInMic else {
                    throw BrineStepError(
                        "a handset recording records shape \(recorded.identity.shape) — the "
                            + "handset's own microphone is .builtInMic")
                }
                // Classify it here so the shared "not a device record that went missing"
                // check has a subject: a handset recording is IDENTIFIED, never unknown,
                // whether or not an external device happens to be remembered.
                w.provenance = CaptureDeviceSidecar.provenance(captureId: id, baseDir: w.baseDir)
            },

            defineCheck("it is not attributed to the remembered external device") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.handsetConversation, "the handset opened no conversation")
                let recorded = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: id, baseDir: w.baseDir),
                    "the handset's conversation has no device record")
                guard recorded.identity != w.identity else {
                    throw BrineStepError(
                        "a HANDSET conversation records the remembered BLE device as its "
                            + "recorder: \(recorded.identity) / \(recorded.displayName)")
                }
                // Non-vacuous: the device WAS remembered while this recording happened, so a
                // resolver that reads the pairing had something to wrongly report.
                guard DeviceManager.loadSaved()?.id.uuidString == w.identity.hardwareToken else {
                    throw BrineStepError("no device was remembered — the check is vacuous")
                }
            },

            defineCheck("its device record agrees with its source marker") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.handsetConversation, "the handset opened no conversation")
                let recorded = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: id, baseDir: w.baseDir),
                    "the handset's conversation has no device record")
                let marker = CaptureManager.capturedSourceOnDisk(id, baseDir: w.baseDir)
                // PD-ARCHIVE-IDENTITY: .bleStream -> "omi"; .audioRoute/.builtInMic -> "phoneMic".
                guard CaptureDeviceSidecar.sourceMarker(for: recorded.identity.shape) == marker else {
                    throw BrineStepError(
                        "the capture directory contradicts itself: .capture-source says "
                            + "\(marker ?? "nil") while the device record says \(recorded.identity.shape)")
                }
            },

            defineCheck("device B opens a new conversation rather than continuing device A's") { _, _, _ in
                let opened = try XCTUnwrapOrThrow(w.deviceBManagerConversation,
                                                  "device B's manager opened no conversation")
                guard opened != w.seededConversation else {
                    throw BrineStepError(
                        "device B CONTINUED device A's conversation (\(opened)) — B's audio "
                            + "would be appended to A's recording")
                }
            },

            defineCheck("the spool opens a new conversation rather than continuing device A's") { _, _, _ in
                let opened = try XCTUnwrapOrThrow(w.deviceBSpoolConversation,
                                                  "device B's spool opened no conversation")
                guard opened != w.seededConversation else {
                    throw BrineStepError(
                        "device B's restoration spool CONTINUED device A's conversation (\(opened))")
                }
                // The sentence the scenario actually makes, asserted as itself. Device A's
                // conversation was the ONLY one in this root when the spool ran (the Given
                // proves the un-narrowed scan returns it), so a spool that did not continue it
                // must have MINTED one — and the new conversation carries device B's record,
                // not A's, or "it opened its own" would be a claim about a name rather than
                // about attribution.
                let root = try XCTUnwrapOrThrow(w.spoolRoot, "the spool had no root of its own")
                let b = try XCTUnwrapOrThrow(w.deviceBIdentity, "device B was never named")
                let recorded = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: opened, baseDir: root),
                    "the conversation the spool opened carries no device record")
                guard recorded.identity == b else {
                    throw BrineStepError(
                        "the spool opened \(opened) but it records \(recorded.identity), not "
                            + "device B (\(b))")
                }
            },

            defineCheck("device A's spool continues its own conversation") { _, _, _ in
                // The control that makes the refusal above non-vacuous: the SAME spool path,
                // in the SAME root, driven by the device that actually recorded it, resumes
                // rather than mints. Without this, a spool that refused everything would pass.
                guard w.deviceASpoolResumed == w.seededConversation else {
                    throw BrineStepError(
                        "device A's restoration spool did not continue its own conversation: "
                            + "got \(w.deviceASpoolResumed ?? "nil"), expected "
                            + "\(w.seededConversation ?? "nil")")
                }
            },

            defineCheck("it is reported as having an unreadable device record") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.corruptedConversation, "nothing was corrupted")
                let p = CaptureDeviceSidecar.provenance(captureId: id, baseDir: w.baseDir)
                w.provenance = p
                guard case .unreadableRecord(let diagnostic) = p else {
                    throw BrineStepError(
                        "a device record that could not be decoded is reported as \(p) — "
                            + "'I could not answer' was collapsed into one of the answers")
                }
                guard !diagnostic.isEmpty else {
                    throw BrineStepError("the unreadable record carries no diagnostic")
                }
                // Non-vacuous: the SAME capture with its record intact is `identified`, so this
                // answer is produced by the corruption and not by the seed.
                let intact = CaptureManager.newCaptureId()
                try w.seedConversation(
                    id: intact,
                    startedAt: UInt64(Date().timeIntervalSince1970),
                    device: CaptureDeviceContext(identity: w.identity, displayName: "Omi",
                                                 accountScope: w.scope))
                w.seededConversation = id      // seedConversation moved it; put it back
                guard case .identified = CaptureDeviceSidecar.provenance(captureId: intact,
                                                                         baseDir: w.baseDir) else {
                    throw BrineStepError("nothing is ever identified here — the check is vacuous")
                }
            },

            defineCheck("it is not reported as recorded before the upgrade") { _, _, _ in
                let p = try XCTUnwrapOrThrow(w.provenance, "nothing was classified")
                guard p != .legacyPreMigration else {
                    throw BrineStepError(
                        "a conversation whose device record is CORRUPT was reported as having "
                            + "been recorded before device records shipped — it was written "
                            + "after, and by a device we simply cannot name")
                }
            },

            defineCheck("no device may continue it") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.corruptedConversation, "nothing was corrupted")
                // The device that DID record it cannot be recognised any more, so it may not
                // continue it either — that is the honest consequence of not being able to read
                // the record, and the alternative (anyone may) is the exact bug the record
                // exists to prevent, arrived at through a decode failure instead of an absence.
                for (label, probe) in [("the recording device", w.identity),
                                       ("a different device", w.otherIdentity)] {
                    guard CaptureManager.resumableCaptureId(
                            baseDir: w.baseDir, silenceGap: 120, resumingDevice: probe) != id else {
                        throw BrineStepError(
                            "\(label) continued a conversation whose device record could not be "
                                + "read — an unreadable record was treated as no record")
                    }
                }
                // Non-vacuous: with the record readable, that same scan DOES return it.
                let readable = CaptureManager.newCaptureId()
                try w.seedConversation(
                    id: readable,
                    startedAt: UInt64(Date().timeIntervalSince1970),
                    device: CaptureDeviceContext(identity: w.identity, displayName: "Omi",
                                                 accountScope: w.scope))
                guard CaptureManager.resumableCaptureId(
                        baseDir: w.baseDir, silenceGap: 120,
                        resumingDevice: w.identity) == readable else {
                    throw BrineStepError("nothing is resumable at all — the refusal is free")
                }
            },

            defineCheck("device A continues its own conversation") { _, _, _ in
                // The control that makes both refusals above non-vacuous: the SAME code path,
                // driven by the device that actually recorded it, must resume rather than mint.
                guard w.deviceAReopened == w.seededConversation else {
                    throw BrineStepError(
                        "device A did not continue its own conversation: got "
                            + "\(w.deviceAReopened ?? "nil"), expected \(w.seededConversation ?? "nil")")
                }
            },

            defineCheck("the conversation records the device that made it") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.appConversation, "the app opened no conversation")
                let recorded = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: id, baseDir: w.baseDir),
                    "the app's conversation has no device record")
                guard recorded.identity == w.identity else {
                    throw BrineStepError("the conversation records \(recorded.identity) not \(w.identity)")
                }
                guard recorded.accountScope == w.scope else {
                    throw BrineStepError("the device record carries scope \(recorded.accountScope)")
                }
            },

            defineCheck("that conversation records the device that made it too") { _, _, _ in
                let root = w.baseDir.appendingPathComponent("restoration", isDirectory: true)
                let id = try XCTUnwrapOrThrow(w.spoolConversation, "the spool opened no conversation")
                let recorded = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: id, baseDir: root),
                    "the restoration spool's conversation has no device record")
                guard recorded.identity == w.identity else {
                    throw BrineStepError("the spool recorded \(recorded.identity) not \(w.identity)")
                }
                // The two sites must agree, or "both sites write it" is two behaviours.
                let appId = try XCTUnwrapOrThrow(w.appConversation, "no app conversation to compare")
                let fromApp = try XCTUnwrapOrThrow(
                    CaptureDeviceSidecar.load(captureId: appId, baseDir: w.baseDir),
                    "the app's conversation has no device record")
                guard fromApp == recorded else {
                    throw BrineStepError("the two creation sites recorded different devices: \(fromApp) vs \(recorded)")
                }
            },

            defineCheck("it finds nothing to continue") { _, _, _ in
                guard w.continuation == nil else {
                    throw BrineStepError(
                        "a different device inherited \(w.continuation ?? "?") — audio recorded by "
                            + "one device would continue into another's conversation")
                }
                // BOTH HALVES OF THE IDENTITY. The plan's rule is `(shape, deviceId)`, and a
                // probe that differs in both cannot tell a correct implementation from one
                // comparing the token alone. This device presents the SAME token under a
                // DIFFERENT shape — a Bluetooth audio route advertising the identifier of a
                // BLE stream — and must still be refused.
                let sameTokenOtherShape = RecordingDeviceIdentity(
                    shape: .audioRoute, hardwareToken: w.identity.hardwareToken)
                guard CaptureManager.resumableCaptureId(
                        baseDir: w.baseDir, silenceGap: 120,
                        resumingDevice: sameTokenOtherShape) == nil else {
                    throw BrineStepError(
                        "a device sharing the token under a different SHAPE inherited the "
                            + "conversation — the match is on the token alone")
                }
                // Non-vacuous: the scan must be able to return something at all here.
                guard CaptureManager.resumableCaptureId(baseDir: w.baseDir, silenceGap: 120,
                                                        resumingDevice: w.identity) != nil else {
                    throw BrineStepError("nothing is resumable by ANY device — the refusal is free")
                }
            },

            defineCheck("it continues its own conversation") { _, _, _ in
                guard w.continuation == w.seededConversation else {
                    throw BrineStepError(
                        "the recording device got \(w.continuation ?? "nil"), expected "
                            + "\(w.seededConversation ?? "nil")")
                }
            },

            defineCheck("it continues that conversation") { _, _, _ in
                guard w.continuation == w.seededConversation else {
                    throw BrineStepError(
                        "a pre-upgrade conversation was not continued: got \(w.continuation ?? "nil")")
                }
            },

            defineCheck("it is reported as recorded before the upgrade") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.seededConversation, "nothing was seeded")
                let p = CaptureDeviceSidecar.provenance(captureId: id, baseDir: w.baseDir)
                w.provenance = p
                guard p == .legacyPreMigration else {
                    throw BrineStepError("a pre-upgrade conversation is reported as \(p)")
                }
            },

            defineCheck("it is still attributed to the shipped recording source") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.seededConversation, "nothing was seeded")
                // BYTE-IDENTICAL legacy arm: the shipped `.capture-source` marker is what
                // attribution reads for a pre-upgrade capture, and it must still say Omi.
                guard CaptureManager.capturedSourceOnDisk(id, baseDir: w.baseDir)
                        == CaptureSourceKind.omi.rawValue else {
                    throw BrineStepError("a legacy Omi recording lost its source attribution")
                }
            },

            defineCheck("it is reported as undatable") { _, _, _ in
                let id = try XCTUnwrapOrThrow(w.seededConversation, "nothing was seeded")
                let p = CaptureDeviceSidecar.provenance(captureId: id, baseDir: w.baseDir)
                w.provenance = p
                guard case .undatable = p else {
                    throw BrineStepError("an undatable conversation is reported as \(p)")
                }
            },

            defineCheck("it is not reported as a device record that went missing") { _, _, _ in
                let p = try XCTUnwrapOrThrow(w.provenance, "nothing was classified")
                if case .unknownPostMigration = p {
                    throw BrineStepError(
                        "an undatable conversation was GUESSED to be post-upgrade — the plan "
                            + "forbids exactly this")
                }
                // Non-vacuous: the classifier must be able to say `unknownPostMigration`.
                let recent = "omi-20990101-000000-BBBB0001"
                try? FileManager.default.createDirectory(
                    at: w.baseDir.appendingPathComponent(recent, isDirectory: true),
                    withIntermediateDirectories: true)
                ConversationMetaStore.recordStart(
                    captureId: recent, baseDir: w.baseDir,
                    at: CaptureDeviceSidecar.migrationEpoch + 10_000)
                guard case .unknownPostMigration = CaptureDeviceSidecar.provenance(
                        captureId: recent, baseDir: w.baseDir) else {
                    throw BrineStepError("the classifier never reports unknown — the check is vacuous")
                }
            },

            defineCheck("the composition refuses to resolve a device context") { _, _, _ in
                let resolution = try XCTUnwrapOrThrow(w.resolution, "nothing was resolved")
                guard case .blocked(let reason) = resolution else {
                    throw BrineStepError("a blocked scope still resolved: \(resolution)")
                }
                guard !reason.isEmpty else {
                    throw BrineStepError("the refusal carries no reason — it cannot be acted on")
                }
                // BOTH REFUSALS, SEPARATELY. There are two ways the composition can fail to
                // name what it is about to record — no owning account, and no device — and a
                // probe that only ever exercises the first cannot tell a correct
                // implementation from one that invents a device when none is remembered.
                // (Executing the mutation is how I found that: my first version of this
                // check passed against exactly that implementation.)
                guard let binding = w.binding else {
                    throw BrineStepError("no binding available to exercise the second refusal")
                }
                let noDevice = OmiRestorationComposition.resolveDeviceContext(
                    binding: binding, savedDevice: nil, recording: .externalStream)
                guard case .blocked(let deviceReason) = noDevice else {
                    throw BrineStepError(
                        "a restoration with NO remembered device still resolved a context — "
                            + "it invented a device identity: \(noDevice)")
                }
                guard deviceReason != reason else {
                    throw BrineStepError(
                        "both refusals give the same reason, so neither can be acted on")
                }
                // Non-vacuous: the same call WITH both must resolve.
                let ok = OmiRestorationComposition.resolveDeviceContext(
                    binding: binding,
                    savedDevice: SavedOmi(id: w.deviceId, name: "Omi", lastConnected: nil),
                    recording: .externalStream)
                guard case .resolved = ok else {
                    throw BrineStepError("nothing ever resolves — the refusal is free")
                }
            },

            defineCheck("the spool opens no conversation while the device is streaming") { _, _, _ in
                let root = w.baseDir.appendingPathComponent("blocked", isDirectory: true)
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let resolution = try XCTUnwrapOrThrow(w.resolution, "nothing was resolved")
                let spool = OmiRestorationComposition.makeRestorationSpool(
                    binding: nil, root: root,
                    executor: DispatchQueue(label: "foundryx.attribution-blocked-\(UUID().uuidString)"),
                    log: nil, silenceGap: 120, paused: { false },
                    deviceContext: resolution)
                w.spool = spool
                spool.handleState(.streaming)
                spool.append(Data([7, 7, 7]))
                try await DeviceCaptureAttributionWorld.settle(timeout: 2) {
                    spool.activeCaptureId != nil
                }
                guard spool.activeCaptureId == nil else {
                    throw BrineStepError(
                        "the spool recorded \(spool.activeCaptureId ?? "?") with no resolvable "
                            + "device identity")
                }
                guard ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty else {
                    throw BrineStepError("the blocked spool left files behind")
                }
            },

            defineCheck("no device record is written anywhere") { _, _, _ in
                let fm = FileManager.default
                var found: [String] = []
                let enumerator = fm.enumerator(atPath: w.baseDir.path)
                while let entry = enumerator?.nextObject() as? String {
                    if entry.hasSuffix(CaptureDeviceSidecar.fileName) { found.append(entry) }
                }
                guard found.isEmpty else {
                    throw BrineStepError("a placeholder device record was written: \(found)")
                }
                // Non-vacuous: the sweep must be able to SEE one.
                let probe = "probe-capture"
                try? fm.createDirectory(at: w.baseDir.appendingPathComponent(probe, isDirectory: true),
                                        withIntermediateDirectories: true)
                _ = CaptureDeviceSidecar.write(
                    CaptureDeviceContext(identity: w.identity, displayName: "Omi",
                                         accountScope: w.scope),
                    captureId: probe, baseDir: w.baseDir)
                var seen = false
                let again = fm.enumerator(atPath: w.baseDir.path)
                while let entry = again?.nextObject() as? String {
                    if entry.hasSuffix(CaptureDeviceSidecar.fileName) { seen = true }
                }
                guard seen else {
                    throw BrineStepError("the sweep cannot see a device record — the check is vacuous")
                }
            },
        ]
    }
}

/// `XCTUnwrap` throws an XCTest-internal error that Brine reports as an opaque failure.
/// This keeps the message the step author wrote.
func XCTUnwrapOrThrow<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw BrineStepError(message) }
    return value
}
