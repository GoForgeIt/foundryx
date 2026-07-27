import Foundation
import Darwin

/// One process-shared admission word per account scope.
///
/// The mapped word packs a blocked bit, an active-perform reader count, and a
/// monotonically advancing epoch. `perform(as:)` acquires a reader with one CAS;
/// deletion advances/blocks with one CAS and waits for admitted readers to drain
/// before its durable typed readback. No file operation or mutex is used by the
/// producer hot path.
final class SharedAccountAdmissionCell: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let cell: SharedAccountAdmissionCell
        private var released = false

        fileprivate init(cell: SharedAccountAdmissionCell) {
            self.cell = cell
        }

        func release() {
            guard !released else { return }
            released = true
            cell.releaseReader()
        }

        deinit { release() }
    }

    private static let blockedBit: UInt64 = 1
    private static let readerUnit: UInt64 = 2
    private static let readerMask: UInt64 = 0x1fffe
    private static let epochUnit: UInt64 = 0x20000
    private static let epochMask: UInt64 = ~UInt64(0x1ffff)
    private static let mappedSize = MemoryLayout<UInt64>.size

    private let descriptor: Int32
    private let pointer: UnsafeMutablePointer<UInt64>

    init(container: URL, ownerScope: String) throws {
        let directory = container.appendingPathComponent(
            AccountDeletionLifecycleStore.metadataDirectoryName,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "\(ownerScope).admission")
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw AccountDeletionLifecycleError.durability
        }
        guard Darwin.ftruncate(
            descriptor,
            off_t(Self.mappedSize)) == 0 else {
            _ = Darwin.close(descriptor)
            throw AccountDeletionLifecycleError.durability
        }
        let mapping = Darwin.mmap(
            nil,
            Self.mappedSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0)
        guard mapping != MAP_FAILED, let mapping else {
            _ = Darwin.close(descriptor)
            throw AccountDeletionLifecycleError.durability
        }
        self.descriptor = descriptor
        self.pointer = mapping.assumingMemoryBound(to: UInt64.self)
    }

    deinit {
        _ = Darwin.munmap(pointer, Self.mappedSize)
        _ = Darwin.close(descriptor)
    }

    var openEpoch: UInt64? {
        let word = load()
        guard word & Self.blockedBit == 0 else { return nil }
        return word & Self.epochMask
    }

    func isCurrent(epoch: UInt64) -> Bool {
        let word = load()
        return word & Self.blockedBit == 0
            && word & Self.epochMask == epoch
    }

    func acquire(epoch: UInt64) -> Lease? {
        while true {
            let expected = load()
            guard expected & Self.blockedBit == 0,
                  expected & Self.epochMask == epoch,
                  expected & Self.readerMask != Self.readerMask else {
                return nil
            }
            let desired = expected &+ Self.readerUnit
            if compareExchange(expected: expected, desired: desired) {
                return Lease(cell: self)
            }
        }
    }

    /// Advances the epoch and closes admission while preserving already admitted
    /// readers so the deletion writer can drain them before durable readback.
    func revoke() {
        while true {
            let expected = load()
            if expected & Self.blockedBit != 0 { return }
            let nextEpoch =
                (expected & Self.epochMask) &+ Self.epochUnit
            let desired = nextEpoch
                | (expected & Self.readerMask)
                | Self.blockedBit
            if compareExchange(expected: expected, desired: desired) {
                return
            }
        }
    }

    /// A completed deletion may admit a later activation, but always under a fresh
    /// epoch so bindings captured before deletion can never become current again.
    func reopenAfterCompletedDeletion() {
        while true {
            let expected = load()
            guard expected & Self.blockedBit != 0,
                  expected & Self.readerMask == 0 else { return }
            let nextEpoch =
                (expected & Self.epochMask) &+ Self.epochUnit
            if compareExchange(expected: expected, desired: nextEpoch) {
                return
            }
        }
    }

    func waitForReadersToDrain() {
        while load() & Self.readerMask != 0 {
            sched_yield()
        }
    }

    private func releaseReader() {
        while true {
            let expected = load()
            precondition(expected & Self.readerMask >= Self.readerUnit)
            let desired = expected &- Self.readerUnit
            if compareExchange(expected: expected, desired: desired) {
                return
            }
        }
    }

    private func load() -> UInt64 {
        // A naturally aligned Swift `pointee` load can still be a language-level
        // data race when another process changes this MAP_SHARED word. add(0) is
        // the deployment-target-safe Darwin atomic load: it is memory-only,
        // lock-free on the app's 64-bit architectures, and provides the barrier
        // needed to observe a writer's epoch transition.
        UInt64(bitPattern: OSAtomicAdd64Barrier(
            0,
            UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: Int64.self)))
    }

    private func compareExchange(
        expected: UInt64,
        desired: UInt64
    ) -> Bool {
        OSAtomicCompareAndSwap64Barrier(
            Int64(bitPattern: expected),
            Int64(bitPattern: desired),
            UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: Int64.self))
    }
}

enum SharedAccountAdmissionRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cells:
        [String: SharedAccountAdmissionCell] = [:]

    static func cell(
        container: URL,
        ownerScope: String
    ) throws -> SharedAccountAdmissionCell {
        let key = container.standardizedFileURL.path + "/" + ownerScope
        if let cached = lock.withLock({ cells[key] }) {
            return cached
        }
        let created = try SharedAccountAdmissionCell(
            container: container,
            ownerScope: ownerScope)
        return lock.withLock {
            if let raced = cells[key] { return raced }
            cells[key] = created
            return created
        }
    }

    static func resetForTests() {
        lock.withLock { cells.removeAll() }
    }
}
