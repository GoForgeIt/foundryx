// OmiRestorationSpool — the headless capture sink for a BLUETOOTH-RESTORATION
// relaunch. When iOS relaunches the app in the background because the Omi's
// pending connect completed (CB state restoration), no UI exists and the full
// CaptureManager pipeline (door target, sign-in, STT) isn't built. But the
// firmware STOPS writing to its onboard ring the moment a BLE connection exists —
// so once we reconnect+subscribe, the audio streams to US and someone must persist
// it or it's lost. This spool is that someone: a minimal, durable frame sink that
// writes the stream into the STANDARD capture-WAL layout (same dir, same segment
// files, same source marker + start stamps), so when the user later opens the app
// the EXISTING resume-same-id logic (81b32bc) adopts the capture seamlessly —
// same conversation inside the silence gap, a new one past it. Upload/finalize
// stay owned by CaptureManager; the spool only makes bytes durable on the phone.

import Foundation

public final class OmiRestorationSpool: @unchecked Sendable {
    private let io: DispatchQueue
    private let ioKey = DispatchSpecificKey<Bool>()
    private var accountBinding: CaptureAccountScope.AccountBinding? // io only
    private let baseDir: URL
    private let log: DoorLog?
    private let silenceGap: TimeInterval
    private let isPaused: () -> Bool
    /// WHICH device this spool is recording from, resolved by the composition root
    /// (`OmiRestorationComposition`). The spool never discovers it: during a background
    /// relaunch there may be no resolvable account scope and no remembered device, and a
    /// type that discovers its own identity cannot say "I could not" -- it can only guess.
    ///
    /// THREE STATES, AND THE DIFFERENCE MATTERS.
    ///   * `nil`      — this spool was not built by the restoration composition and was
    ///                  never offered a context. Behaves exactly as shipped: it records,
    ///                  and writes no device record. The plan scopes the refusal below to
    ///                  "during background restoration"; a directly-constructed spool is
    ///                  not that, and silently making it stop recording would be a
    ///                  behaviour change nobody asked for.
    ///   * `.resolved`— record, and write the device record.
    ///   * `.blocked` — somebody who DID look could not name the device or the owning
    ///                  account. That is the case the plan says to defer.
    private let deviceContext: CaptureDeviceContextResolution?
    private var wal: CaptureWAL?          // io queue only
    private var framesSpooled = 0         // io queue only
    private var accountExposureClosed = false // io queue only

    /// `paused` mirrors the user's durable capture intent — a user who paused
    /// capture must NOT be recorded by a background relaunch.
    public init(baseDir: URL = CaptureWAL.documentsCaptures(),
                log: DoorLog? = nil,
                silenceGap: TimeInterval = CaptureSettings.silenceGapSeconds,
                paused: @escaping () -> Bool = { true },
                binding: CaptureAccountScope.AccountBinding? = nil,
                executor: DispatchQueue? = nil,
                deviceContext: CaptureDeviceContextResolution? = nil) {
        let queue = DispatchQueue(
            label: "foundryx.omi-restoration-spool",
            target: executor)
        self.io = queue
        self.accountBinding = binding
        self.baseDir = baseDir
        self.log = log
        self.silenceGap = silenceGap
        self.isPaused = paused
        self.deviceContext = deviceContext
        queue.setSpecific(key: ioKey, value: true)
    }

    /// Explicit owner/root/executor initializer used by account-bound restoration.
    public convenience init(
        binding: CaptureAccountScope.AccountBinding,
        root: URL,
        executor: DispatchQueue,
        log: DoorLog? = nil,
        silenceGap: TimeInterval = CaptureSettings.silenceGapSeconds,
        paused: @escaping () -> Bool = { true },
        deviceContext: CaptureDeviceContextResolution? = nil
    ) {
        self.init(
            baseDir: root,
            log: log,
            silenceGap: silenceGap,
            paused: paused,
            binding: binding,
            executor: executor,
            deviceContext: deviceContext)
    }

    /// Wire this spool as the source's sink. The later CaptureManager takeover
    /// simply reassigns these closures; call `detach()` first to flush.
    public func attach(to source: AudioFrameSource) {
        source.onState = { [weak self] state in self?.handleState(state) }
        source.onFrame = { [weak self] frame in self?.append(frame) }
    }

    public func handleState(_ state: AudioSourceState) {
        switch state {
        case .streaming:
            io.async {
                guard !self.accountExposureClosed else { return }
                self.openSessionLocked()
            }
        case .stopped, .failed:
            io.async {
                guard !self.accountExposureClosed else { return }
                self.closeSessionLocked()
            }
        case .idle, .scanning: break
        }
    }

    public func append(_ frame: Data) {
        io.async {
            guard !self.accountExposureClosed,
                  !self.isPaused(),
                  let wal = self.wal else { return }
            self.framesSpooled += 1
            wal.appendFrame(frame)
        }
    }

    /// Handover to the real CaptureManager (the app UI is being built): flush any
    /// buffered frames to disk and stop. The WAL's segments stay on disk, where
    /// resume-same-id finds them (its newest segment is seconds old ⇒ same id).
    public func detach() {
        syncOnIO {
            guard !self.accountExposureClosed else { return }
            if let id = self.wal?.captureId {
                self.log?.info("omi-restore: spool handed off capture \(id) (\(self.framesSpooled) frames spooled)")
            }
            _ = self.closeAccountExposureLocked()
        }
    }

    /// Bind a previously-unbound locked/background spool during foreground
    /// handoff. The owner identity is copied, but the root deliberately remains
    /// the spool's existing legacy capture directory; no container is resolved.
    @discardableResult
    public func installAccountExposureBinding(
        from binding: CaptureAccountScope.AccountBinding
    ) -> CaptureAccountScope.AccountBinding? {
        syncOnIO {
            guard !accountExposureClosed else { return nil }
            let rooted = CaptureAccountScope.AccountBinding(
                root: baseDir,
                scope: binding.scope,
                generation: binding.generation,
                admissionEpoch: binding.admissionEpoch,
                admissionCell: binding.admissionCell)
            accountBinding = rooted
            return rooted
        }
    }

    public var availableAccountExposureBinding:
        CaptureAccountScope.AccountBinding?
    {
        syncOnIO { accountBinding }
    }

    /// Terminally flush and close the old owner's spool. Installed source
    /// callbacks are deliberately retained: they are gated by the closed flag,
    /// while a successor remains free to replace them without this close erasing it.
    public func closeAccountExposure(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult {
        return await withCheckedContinuation { continuation in
            executeOnIO {
                guard let accountBinding = self.accountBinding else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                guard expected == accountBinding else {
                    continuation.resume(returning: .ownerMismatch)
                    return
                }
                continuation.resume(returning: self.closeAccountExposureLocked())
            }
        }
    }

    func closeAccountExposureFromExecutorForTests(
        expected: CaptureAccountScope.AccountBinding
    ) async -> AccountExposureCloseResult {
        await withCheckedContinuation { continuation in
            io.async {
                guard let accountBinding = self.accountBinding else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                guard expected == accountBinding else {
                    continuation.resume(returning: .ownerMismatch)
                    return
                }
                // Already on `io`: executeOnIO must dispatch inline rather than
                // recursively synchronizing onto this same serial executor.
                self.executeOnIO {
                    continuation.resume(
                        returning: self.closeAccountExposureLocked())
                }
            }
        }
    }

    /// The capture id currently being spooled (tests + diagnostics).
    public var activeCaptureId: String? { syncOnIO { wal?.captureId } }
    public var spooledFrameCount: Int { syncOnIO { framesSpooled } }

    // MARK: io-queue internals

    private func openSessionLocked() {
        guard !accountExposureClosed else { return }
        guard wal == nil else { return }
        guard !isPaused() else {
            log?.info("omi-restore: capture is user-paused — holding the link, not recording")
            return
        }
        // DEFER RATHER THAN GUESS. The composition root LOOKED and could not say which
        // device — or whose account — this stream belongs to. Recording it anyway would
        // write bytes into an archive with no honest way to attribute them, and worse,
        // with no resolvable owner it could land in the wrong account's container. A
        // placeholder record is indistinguishable from a real one for the rest of the
        // capture's life. The link stays up; nothing is written.
        if case .blocked(let reason) = deviceContext {
            log?.error("omi-restore: NOT recording -- \(reason)")
            return
        }
        let context = deviceContext?.context
        // Resume the conversation the disconnect interrupted when we're inside the
        // silence gap (the SAME rule + code CaptureManager uses); else mint fresh. The
        // device identity narrows it: this spool may only continue ITS OWN device's
        // conversation.
        let resumed = CaptureManager.resumableCaptureId(baseDir: baseDir,
                                                        silenceGap: silenceGap,
                                                        resumingDevice: context?.identity)
        let id = resumed ?? CaptureManager.newCaptureId()
        // Spool-only WAL: placeholder target (it never uploads — CaptureManager's
        // drain owns sync after handover).
        let placeholder = DoorTarget(baseURL: URL(string: "http://127.0.0.1:0")!, bearer: "")
        let w = CaptureWAL(
            captureId: id,
            target: placeholder,
            baseDir: baseDir,
            binding: accountBinding,
            log: log)
        if resumed == nil {
            // Same durable birth stamps beginSession writes, so the capture is a
            // first-class conversation (card start, source gate for future resumes).
            let startSecs = nowUnixSecs()
            ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir, at: startSecs)
            _ = ConversationCardStore.recordStart(captureId: id, baseDir: baseDir, startedAt: startSecs)
            try? Data(CaptureSourceKind.omi.rawValue.utf8)
                .write(to: CaptureManager.sourceMarkerURL(id, baseDir: baseDir), options: [.atomic])
            // The SECOND capture-creation site. Both sites write the device record, or a
            // conversation's attribution would depend on which of them happened to open it.
            if let context,
               !CaptureDeviceSidecar.write(context, captureId: id, baseDir: baseDir) {
                log?.error("omi-restore: capture \(id) opened but its device record could not be written")
            }
            CaptureEventLog.append(.captureStarted, captureId: id,
                                   payload: ["source": CaptureSourceKind.omi.rawValue,
                                             "mode": "background-restoration"], baseDir: baseDir)
        }
        wal = w
        w.beginStreaming()
        log?.info("omi-restore: background spool \(resumed != nil ? "RESUMED" : "opened") capture \(id)")
    }

    private func closeSessionLocked() {
        guard let w = wal else { return }
        w.finish()   // flush the partial segment durably; NO finalize (disconnects never finalize)
        log?.info("omi-restore: link down — spool flushed capture \(w.captureId) (\(framesSpooled) frames)")
        wal = nil
    }

    private func closeAccountExposureLocked() -> AccountExposureCloseResult {
        guard !accountExposureClosed else { return .alreadyClosed }
        accountExposureClosed = true
        wal?.finish()
        wal = nil
        return .closed
    }

    private func executeOnIO(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: ioKey) == true {
            operation()
        } else {
            io.async(execute: operation)
        }
    }

    private func syncOnIO<Value>(_ operation: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: ioKey) == true {
            return operation()
        }
        return io.sync(execute: operation)
    }
}
