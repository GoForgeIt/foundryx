// MainThreadStackSampler — a cross-thread backtrace sampler that names WHERE the main
// thread is blocked WHILE it is blocked (track 20260717T0900 WS-A).
//
// MetricKit's hang stacks arrive ~daily and only for the worst hangs; the live stall
// watchdog sees a stall's DURATION but, because it only measures a ping AFTER it lands,
// never its LOCATION. This sampler closes that gap: the watchdog, on its utility control
// queue, calls `sample()` while a ping is still stuck in the (blocked) main queue — we
// suspend the main thread, read its register state + walk the frame-pointer chain, resume
// it, and THEN (never during the suspend) resolve raw addresses to `PerfStackFrame`s that
// the existing PerfDiag.hangStackLines machinery formats as `stallstack`/`stallimg` lines.
//
// SAFETY CONTRACT between thread_suspend and thread_resume:
//   • NO allocation, NO Swift runtime metadata calls, NO objc, NO locks. Everything is
//     preallocated; the only calls are mach syscalls (thread_get_state, vm_read_overwrite).
//   • EVERY memory read of the target's stack goes through vm_read_overwrite, so a torn or
//     unmapped frame returns an error instead of faulting the whole process.
//   • The frame-pointer walk is sanity-checked (non-zero, 16-byte aligned, strictly
//     increasing, hard frame cap) so a corrupt chain can't loop or wander.
// Address resolution (dladdr + LC_UUID parse) runs AFTER resume, where allocation and dyld
// locks are safe again.
//
// Pure-ish: no MetricKit, no UIKit. It produces `[PerfStackFrame]` — the same currency the
// hang-stack formatter already consumes — so the wire grammar stays byte-identical.

import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

public final class MainThreadStackSampler: @unchecked Sendable {

    /// The target thread's mach port (a send right owned by the thread; NOT a fresh ref —
    /// we never call mach_thread_self(), which would leak a ref per call). 0 until recorded.
    private let portLock = NSLock()
    private var _targetPort: UInt32 = 0

    /// Explicit-port init (tests hand us an arbitrary thread's port).
    public init(threadPort: UInt32) {
        self._targetPort = threadPort
    }

    /// Production init: record the target queue's thread port FROM that thread itself, so the
    /// port is the real worker backing the queue (for `.main`, the main thread). No extra ref.
    public convenience init(targetQueue: DispatchQueue = .main) {
        self.init(threadPort: 0)
        targetQueue.async { [weak self] in
            #if canImport(Darwin)
            let port = pthread_mach_thread_np(pthread_self())
            self?.setPort(port)
            #endif
        }
    }

    private func setPort(_ p: UInt32) {
        portLock.lock(); _targetPort = p; portLock.unlock()
    }

    private var targetPort: UInt32 {
        portLock.lock(); defer { portLock.unlock() }; return _targetPort
    }

    /// Sample the target thread's backtrace. Returns [] if the port isn't recorded yet, if we
    /// would be sampling our OWN thread (never suspend self), or on any mach failure.
    public func sample(maxFrames: Int = 64) -> [PerfStackFrame] {
        #if canImport(Darwin)
        let port = targetPort
        guard port != 0 else { return [] }
        // Never suspend the calling thread.
        guard port != pthread_mach_thread_np(pthread_self()) else { return [] }

        let cap = max(1, min(maxFrames, 64))
        // PREALLOCATE the address buffer before suspending — no allocation in the critical section.
        let addrs = UnsafeMutablePointer<UInt>.allocate(capacity: cap)
        defer { addrs.deallocate() }

        let count = Self.captureRawFrames(port: port, into: addrs, capacity: cap)
        guard count > 0 else { return [] }

        // AFTER resume: resolve raw addresses → frames (allocation + dyld locks are safe now).
        var frames: [PerfStackFrame] = []
        frames.reserveCapacity(count)
        var uuidCache: [UInt: String] = [:]   // dli_fbase → full UUID
        for i in 0..<count {
            if let f = Self.resolve(address: addrs[i], uuidCache: &uuidCache) { frames.append(f) }
        }
        return frames
        #else
        return []
        #endif
    }

    #if canImport(Darwin)

    // MARK: - Critical section (suspend → walk → resume)

    /// Suspend `port`, read its register state, walk the frame-pointer chain into `out`
    /// (every read via vm_read_overwrite), resume it. Returns the number of addresses written.
    /// NOTHING here allocates or touches the Swift runtime.
    private static func captureRawFrames(port: UInt32,
                                         into out: UnsafeMutablePointer<UInt>,
                                         capacity cap: Int) -> Int {
        guard thread_suspend(port) == KERN_SUCCESS else { return 0 }

        var (pc, fp) = registerState(port)
        var written = 0
        if pc != 0 { out[0] = strip(pc); written = 1 }

        // Walk saved (fp, return-address) pairs. arm64 & x86_64 both store the caller's frame
        // pointer at [fp] and the return address at [fp + 8].
        let task = mach_task_self_
        var prevFp: UInt = 0
        while written < cap,
              fp != 0,
              (fp & 0xF) == 0,      // 16-byte aligned
              fp > prevFp {          // strictly increasing (stack unwinds toward higher addresses)
            var savedFp: UInt = 0
            var savedRet: UInt = 0
            guard readWord(task: task, address: fp, into: &savedFp),
                  readWord(task: task, address: fp &+ 8, into: &savedRet) else { break }
            let ret = strip(savedRet)
            if ret == 0 { break }
            out[written] = ret
            written += 1
            prevFp = fp
            fp = savedFp
        }

        thread_resume(port)
        return written
    }

    /// Read one pointer-sized word from the target task via vm_read_overwrite (safe: an
    /// unmapped/torn address returns an error rather than faulting). Returns false on failure.
    private static func readWord(task: vm_map_t, address: UInt, into value: inout UInt) -> Bool {
        var outSize: vm_size_t = 0
        let kr = withUnsafeMutablePointer(to: &value) { dst -> kern_return_t in
            vm_read_overwrite(task,
                              vm_address_t(address),
                              vm_size_t(MemoryLayout<UInt>.size),
                              vm_address_t(UInt(bitPattern: dst)),
                              &outSize)
        }
        return kr == KERN_SUCCESS && outSize == vm_size_t(MemoryLayout<UInt>.size)
    }

    /// (pc, fp) from the suspended thread's register state, per architecture. Read by fixed
    /// register index off a UInt64 rebinding so the opaque (arm64e, PAC) vs plain field
    /// naming of the thread-state struct never matters — the binary layout is identical.
    private static func registerState(_ port: UInt32) -> (pc: UInt, fp: UInt) {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { p -> kern_return_t in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        // arm_thread_state64: __x[29] (indices 0..28), __fp=29, __lr=30, __sp=31, __pc=32.
        let (fp, pc) = withUnsafeBytes(of: &state) { buf -> (UInt, UInt) in
            let words = buf.bindMemory(to: UInt64.self)
            return (UInt(words[29]), UInt(words[32]))
        }
        return (pc, fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { p -> kern_return_t in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(port, thread_state_flavor_t(x86_THREAD_STATE64), raw, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        // x86_thread_state64: rax,rbx,rcx,rdx,rdi,rsi,rbp(6),rsp,r8..r15,rip(16).
        let (fp, pc) = withUnsafeBytes(of: &state) { buf -> (UInt, UInt) in
            let words = buf.bindMemory(to: UInt64.self)
            return (UInt(words[6]), UInt(words[16]))
        }
        return (pc, fp)
        #else
        return (0, 0)
        #endif
    }

    /// Strip an ARM pointer-authentication (PAC) signature + any top-byte tag from a code
    /// address so dladdr sees the real VA. macOS/iOS user space is ≤47-bit, so clearing the
    /// high bits recovers the address for all mapped images. No-op where PAC never applies.
    private static func strip(_ addr: UInt) -> UInt {
        #if arch(arm64)
        return addr & 0x0000_7FFF_FFFF_FFFF
        #else
        return addr
        #endif
    }

    // MARK: - Resolution (post-resume: allocation + dyld locks are safe)

    /// Resolve one raw address → PerfStackFrame via dladdr: binary = basename(dli_fname),
    /// offset = address − dli_fbase, uuid = LC_UUID of the mach image at dli_fbase (cached).
    private static func resolve(address: UInt, uuidCache: inout [UInt: String]) -> PerfStackFrame? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
              let fbase = info.dli_fbase else { return nil }
        let base = UInt(bitPattern: fbase)
        let name = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
        let offset = Int(address &- base)

        let uuid: String
        if let cached = uuidCache[base] {
            uuid = cached
        } else {
            uuid = imageUUID(machHeader: fbase) ?? ""
            uuidCache[base] = uuid
        }
        return PerfStackFrame(binaryName: name, binaryUUID: uuid, offset: offset, symbol: nil)
    }

    /// Parse the LC_UUID load command from a mach-O image header. Returns the canonical
    /// upper-case dashed UUID string (PerfDiag lowercases downstream), or nil if absent.
    private static func imageUUID(machHeader: UnsafeRawPointer) -> String? {
        let header = machHeader.assumingMemoryBound(to: mach_header_64.self)
        guard header.pointee.magic == MH_MAGIC_64 || header.pointee.magic == MH_CIGAM_64 else { return nil }
        var cmdPtr = machHeader.advanced(by: MemoryLayout<mach_header_64>.size)
        let ncmds = Int(header.pointee.ncmds)
        for _ in 0..<ncmds {
            let cmd = cmdPtr.assumingMemoryBound(to: load_command.self)
            if cmd.pointee.cmd == LC_UUID {
                let uuidCmd = cmdPtr.assumingMemoryBound(to: uuid_command.self)
                let u = uuidCmd.pointee.uuid
                return String(format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                              u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                              u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15)
            }
            cmdPtr = cmdPtr.advanced(by: Int(cmd.pointee.cmdsize))
        }
        return nil
    }
    #endif
}
