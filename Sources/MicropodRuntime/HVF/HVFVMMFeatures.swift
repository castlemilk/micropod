import Darwin
import Foundation
import Synchronization

/// Whether a micropod-vmm binary takes a command-line flag.
public enum HVFVMMFlagSupport: Sendable, Equatable {
    case supported
    /// The binary's usage text does not name the flag: it predates it.
    case unsupported
    /// The binary would not say (it did not run, or printed no usage).
    case unknown(String)
}

/// What a payload's micropod-vmm accepts, asked of the binary itself.
///
/// machine.json outlives a payload: `update hvf rollback` (or an install
/// from an older bundle) can put a VMM under a configuration written for a
/// newer one, and micropod-vmm exits 2 on an argument it does not know. The
/// payload manifest lists digests, not capabilities, so the supervisor asks
/// the binary: `micropod-vmm --help` prints its usage and exits 0 without
/// touching a disk or the hypervisor, and every flag is named there (the
/// VMM's own tests hold `--disk-flush-os` to that).
public enum HVFVMMFeatures {
    /// The OS disk's flush mode (machine.json `osDiskFlush`).
    public static let osDiskFlushFlag = "--disk-flush-os"

    /// Whether `vmm` takes `--disk-flush-os`.
    public static func osDiskFlush(vmm: URL) -> HVFVMMFlagSupport { support(for: osDiskFlushFlag, vmm: vmm) }

    /// Whether `vmm` takes `flag`. A definite answer is kept for that file:
    /// the same path, device, inode, size and modification time are not
    /// asked again (a relaunch, each `machine status` of a long-lived
    /// process). An activation moves `current` to another directory, and so
    /// to another file.
    public static func support(for flag: String, vmm: URL, timeout: Duration = .seconds(5)) -> HVFVMMFlagSupport {
        let path = HVFMachineLayout.canonicalPath(vmm.path)
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .unknown("\(path): \(String(cString: strerror(errno)))")
        }
        let identity = HVFMachineConfig.FileIdentity(info)
        if let kept = keptUsage.withLock({ $0[path] }), kept.identity == identity {
            return support(for: flag, inUsage: kept.usage)
        }
        let usage: String
        switch usageText(of: URL(fileURLWithPath: path), timeout: timeout) {
        case .success(let text): usage = text
        case .failure(let failure): return .unknown(failure.reason)
        }
        keptUsage.withLock { $0[path] = (identity, usage) }
        return support(for: flag, inUsage: usage)
    }

    /// `flag` as a whole word of `usage`: `--disk-flush` does not make
    /// `--disk-flush-os` supported, nor the other way round.
    static func support(for flag: String, inUsage usage: String) -> HVFVMMFlagSupport {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var search = usage.startIndex..<usage.endIndex
        while let found = usage.range(of: flag, range: search) {
            let after = found.upperBound < usage.endIndex ? usage.unicodeScalars[found.upperBound] : nil
            let before =
                found.lowerBound > usage.startIndex
                ? usage.unicodeScalars[usage.unicodeScalars.index(before: found.lowerBound)] : nil
            if after.map(word.contains) != true, before.map(word.contains) != true { return .supported }
            search = found.upperBound..<usage.endIndex
        }
        return .unsupported
    }

    /// Usage probes run (tests).
    static var probes: Int { probeCount.withLock { $0 } }
    private static let probeCount = Mutex(0)
    private static let keptUsage = Mutex<[String: (identity: HVFMachineConfig.FileIdentity, usage: String)]>([:])

    struct ProbeFailure: Error { var reason: String }

    /// What `vmm --help` prints (stdout and stderr), when it exits 0 with a
    /// usage text. Anything else is no answer.
    static func usageText(of vmm: URL, timeout: Duration) -> Result<String, ProbeFailure> {
        probeCount.withLock { $0 += 1 }
        let process = Process()
        process.executableURL = vmm
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return .failure(ProbeFailure(reason: "\(vmm.path) --help did not run: \(error.localizedDescription)"))
        }
        let timedOut = Mutex(false)
        let watchdog = DispatchWorkItem {
            timedOut.withLock { $0 = true }
            kill(process.processIdentifier, SIGKILL)
        }
        let (seconds, attoseconds) = timeout.components
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Int(seconds)) + .nanoseconds(Int(attoseconds / 1_000_000_000)),
            execute: watchdog)
        // Read to end of file before waiting: a usage text longer than the
        // pipe's buffer would otherwise block the child.
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut.withLock({ $0 }) {
            return .failure(ProbeFailure(reason: "\(vmm.path) --help did not exit within \(timeout)"))
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let how = process.terminationReason == .exit ? "exited with status" : "was killed by signal"
            return .failure(ProbeFailure(reason: "\(vmm.path) --help \(how) \(process.terminationStatus)"))
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("--") else {
            return .failure(ProbeFailure(reason: "\(vmm.path) --help printed no usage"))
        }
        return .success(text)
    }
}
