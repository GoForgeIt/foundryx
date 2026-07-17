// OmiOfflineSyncEngine — the gap-audio (ring) sync state machine, CoreBluetooth-free
// so it's unit-testable with a mocked link. DeviceManager owns the real BLE plumbing
// and drives this engine with events (status read result, storage notifications,
// link drop, watchdog fires); the engine answers with COMMANDS (characteristic
// writes / reads) and recovered Opus FRAMES, in recorded order.
//
// Safety rules:
//  • We never send CMD_RING_CLEAR. The read pointer only ADVANCEs over what the
//    firmware told us it streamed (DONE.nextSeq) or, on an aborted transfer, over
//    the records we FULLY consumed — a sync bug can never destroy unread audio.
//  • Every terminal path calls `finished` exactly once, so the owner can release
//    the held live-audio frames deterministically.
//  • An unparseable status read (old-firmware storage protocol) SKIPS sync — live
//    streaming is never held hostage to a protocol we don't speak.

import Foundation

public final class OmiOfflineSyncEngine {
    /// What the engine wants the BLE owner to do next.
    public enum Command: Equatable, Sendable {
        case readStatus                  // read the storage CONTROL characteristic
        case requestInfo                 // write CMD_RING_INFO to the storage data characteristic
        case read(startSeq: UInt64)      // write CMD_RING_READ
        case advance(seq: UInt64)        // write CMD_RING_ADVANCE
        case stopTransfer                // write CMD_STOP (abort path)
    }

    /// Why the sync ended (all paths release held live audio).
    public enum Outcome: Equatable, Sendable {
        case nothingToSync                       // ring empty / no unread packets
        case unsupportedProtocol(String)         // old firmware — status not ring-shaped
        case synced(records: Int, frames: Int)   // full transfer + advance issued
        case aborted(records: Int, frames: Int, reason: String)  // partial; advanced over consumed
        case failed(String)                      // nothing consumed; no advance
    }

    private enum Phase: Equatable {
        case idle
        case awaitingStatus
        case awaitingInfo
        case transferring
        case awaitingAdvanceAck
        case done
    }

    // Wiring (owner-supplied). `emitFrame` delivers recovered frames in recorded order.
    public var emit: ((Command) -> Void)?
    public var emitFrame: ((Data) -> Void)?
    public var finished: ((Outcome) -> Void)?

    private var phase: Phase = .idle
    private let reassembler = OmiRingRecordReassembler()
    private var transferStartSeq: UInt64 = 0
    private var recordsConsumed = 0
    private var framesEmitted = 0
    private var doneNextSeq: UInt64?
    /// Monotonic activity counter — the owner snapshots it, schedules a one-shot
    /// stall check, and calls `stalled()` only if it hasn't moved. Not a poll loop.
    public private(set) var activityGeneration: UInt64 = 0

    public init() {}

    public var isActive: Bool { phase != .idle && phase != .done }

    // MARK: events

    /// Storage service discovered + data characteristic subscribed → begin.
    public func begin() {
        guard phase == .idle else { return }
        phase = .awaitingStatus
        bump()
        emit?(.readStatus)
    }

    /// Result of the control-characteristic read (nil = read failed).
    public func statusResult(_ data: Data?) {
        guard phase == .awaitingStatus else { return }
        bump()
        guard let data else { return finish(.failed("storage status read failed")) }
        guard let status = OmiRingProtocol.parseStatus(data) else {
            return finish(.unsupportedProtocol("status read \(data.count)B — not ring-shaped (old firmware?)"))
        }
        guard status.unreadPackets > 0 else { return finish(.nothingToSync) }
        phase = .awaitingInfo
        emit?(.requestInfo)
    }

    /// Any notification from the storage DATA characteristic.
    public func notification(_ data: Data) {
        guard !data.isEmpty, isActive else { return }
        bump()
        switch data[data.startIndex] {
        case OmiRingProtocol.notifyInfo:
            guard phase == .awaitingInfo, let info = OmiRingProtocol.parseInfo(data) else { return }
            guard info.writeSeq > info.readSeq else { return finish(.nothingToSync) }
            phase = .transferring
            transferStartSeq = info.readSeq
            emit?(.read(startSeq: info.readSeq))
        case OmiRingProtocol.notifyReadBegin:
            guard phase == .transferring, let rb = OmiRingProtocol.parseReadBegin(data) else { return }
            transferStartSeq = rb.transferStartSeq   // firmware may clamp our start
        case OmiRingProtocol.notifyData:
            guard phase == .transferring else { return }
            reassembler.append(data.dropFirst())
            for record in reassembler.drainRecords() {
                recordsConsumed += 1
                for frame in OmiRingProtocol.recordFrames(record) {
                    framesEmitted += 1
                    emitFrame?(frame)
                }
            }
        case OmiRingProtocol.notifyDone:
            guard phase == .transferring, let done = OmiRingProtocol.parseDone(data) else { return }
            doneNextSeq = done.nextSeq
            // Advance to what the firmware says comes next — the canonical dedupe
            // point. (A non-zero status still advances over what it DID stream.)
            phase = .awaitingAdvanceAck
            emit?(.advance(seq: done.nextSeq))
        case OmiRingProtocol.notifyAck:
            guard phase == .awaitingAdvanceAck else { return }
            finish(.synced(records: recordsConsumed, frames: framesEmitted))
        default:
            break   // unknown opcode — tolerated (logged by the owner)
        }
    }

    /// One-shot stall watchdog fired with no intervening activity.
    public func stalled() {
        guard isActive else { return }
        abort(reason: "stalled (no storage activity)")
    }

    /// Overall time budget exhausted — stop holding live audio.
    public func budgetExhausted() {
        guard isActive else { return }
        abort(reason: "sync budget exhausted")
    }

    /// The BLE link dropped mid-sync. No commands can be sent; just settle.
    public func linkDropped() {
        guard isActive else { return }
        // Nothing advanced — the unread span stays on the device and the NEXT
        // reconnect re-pulls from the same readSeq (duplicates are possible only in
        // the already-emitted prefix; the alternative — advancing blind — could lose
        // audio, so we prefer the duplicate-tolerant side).
        finish(recordsConsumed > 0
               ? .aborted(records: recordsConsumed, frames: framesEmitted, reason: "link dropped")
               : .failed("link dropped"))
    }

    // MARK: internals

    private func abort(reason: String) {
        emit?(.stopTransfer)
        if recordsConsumed > 0 {
            // Advance over ONLY the records fully consumed, so the next reconnect
            // resumes exactly where we stopped (no loss, no duplicates).
            emit?(.advance(seq: transferStartSeq + UInt64(recordsConsumed)))
            finish(.aborted(records: recordsConsumed, frames: framesEmitted, reason: reason))
        } else {
            finish(.failed(reason))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard phase != .done else { return }
        phase = .done
        finished?(outcome)
    }

    private func bump() { activityGeneration &+= 1 }
}
