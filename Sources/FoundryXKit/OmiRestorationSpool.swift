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
    private let io = DispatchQueue(label: "foundryx.omi-restoration-spool")
    private let baseDir: URL
    private let log: DoorLog?
    private let silenceGap: TimeInterval
    private let isPaused: () -> Bool
    private var wal: CaptureWAL?          // io queue only
    private var framesSpooled = 0         // io queue only

    /// `paused` mirrors the user's durable capture intent — a user who paused
    /// capture must NOT be recorded by a background relaunch.
    public init(baseDir: URL = CaptureWAL.documentsCaptures(),
                log: DoorLog? = nil,
                silenceGap: TimeInterval = CaptureSettings.silenceGapSeconds,
                paused: @escaping () -> Bool = { CaptureSettings.omiCaptureDesiredState == .paused }) {
        self.baseDir = baseDir
        self.log = log
        self.silenceGap = silenceGap
        self.isPaused = paused
    }

    /// Wire this spool as the source's sink. The later CaptureManager takeover
    /// simply reassigns these closures; call `detach()` first to flush.
    public func attach(to source: AudioFrameSource) {
        source.onState = { [weak self] state in self?.handleState(state) }
        source.onFrame = { [weak self] frame in self?.append(frame) }
    }

    public func handleState(_ state: AudioSourceState) {
        switch state {
        case .streaming: io.async { self.openSessionLocked() }
        case .stopped, .failed: io.async { self.closeSessionLocked() }
        case .idle, .scanning: break
        }
    }

    public func append(_ frame: Data) {
        io.async {
            guard !self.isPaused(), let wal = self.wal else { return }
            self.framesSpooled += 1
            wal.appendFrame(frame)
        }
    }

    /// Handover to the real CaptureManager (the app UI is being built): flush any
    /// buffered frames to disk and stop. The WAL's segments stay on disk, where
    /// resume-same-id finds them (its newest segment is seconds old ⇒ same id).
    public func detach() {
        io.sync {
            self.wal?.finish()
            if let id = self.wal?.captureId {
                self.log?.info("omi-restore: spool handed off capture \(id) (\(self.framesSpooled) frames spooled)")
            }
            self.wal = nil
        }
    }

    /// The capture id currently being spooled (tests + diagnostics).
    public var activeCaptureId: String? { io.sync { wal?.captureId } }
    public var spooledFrameCount: Int { io.sync { framesSpooled } }

    // MARK: io-queue internals

    private func openSessionLocked() {
        guard wal == nil else { return }
        guard !isPaused() else {
            log?.info("omi-restore: capture is user-paused — holding the link, not recording")
            return
        }
        // Resume the conversation the disconnect interrupted when we're inside the
        // silence gap (the SAME rule + code CaptureManager uses); else mint fresh.
        let resumed = CaptureManager.resumableCaptureId(baseDir: baseDir, silenceGap: silenceGap)
        let id = resumed ?? CaptureManager.newCaptureId()
        // Spool-only WAL: placeholder target (it never uploads — CaptureManager's
        // drain owns sync after handover).
        let placeholder = DoorTarget(baseURL: URL(string: "http://127.0.0.1:0")!, bearer: "")
        let w = CaptureWAL(captureId: id, target: placeholder, baseDir: baseDir, log: log)
        if resumed == nil {
            // Same durable birth stamps beginSession writes, so the capture is a
            // first-class conversation (card start, source gate for future resumes).
            let startSecs = nowUnixSecs()
            ConversationMetaStore.recordStart(captureId: id, baseDir: baseDir, at: startSecs)
            _ = ConversationCardStore.recordStart(captureId: id, baseDir: baseDir, startedAt: startSecs)
            try? Data(CaptureSourceKind.omi.rawValue.utf8)
                .write(to: CaptureManager.sourceMarkerURL(id, baseDir: baseDir), options: [.atomic])
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
}
