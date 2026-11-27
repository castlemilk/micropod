import Foundation

/// The host sync each of the machine's disks runs when the guest flushes it
/// (its ext4 journal commits): micropod-vmm's `--disk-flush` (both disks) and
/// `--disk-flush-os` (the OS disk alone).
///
/// The default is `barrier` on both: `F_BARRIERFSYNC`, so the guest's
/// journal reaches the drive in order and survives a host power loss or
/// kernel panic. `HVFMachineConfig.osDiskFlush` = `fsync` opts the OS disk
/// (`disk.ext4`: images, containers, volumes, BuildKit's state) out of that
/// ordering for faster commits; the cache disk (`caches.ext4`) keeps
/// `barrier`.
public struct HVFDiskFlush: Codable, Sendable, Equatable {
    /// The modes micropod-vmm accepts.
    public static let modes = ["barrier", "full", "fsync"]
    public static let defaultMode = "barrier"

    /// The OS disk's mode (`--disk`).
    public var osDisk: String
    /// The cache disk's mode (`--cache-disk`).
    public var cacheDisk: String

    public init(osDisk: String = HVFDiskFlush.defaultMode, cacheDisk: String = HVFDiskFlush.defaultMode) {
        self.osDisk = osDisk
        self.cacheDisk = cacheDisk
    }

    /// What `config` launches the VMM with: `osDiskFlush` for the OS disk;
    /// a `--disk-flush` among `extraArguments` (both disks; the VMM takes
    /// the last one) otherwise; `barrier`.
    public init(config: HVFMachineConfig) {
        var both = Self.defaultMode
        var i = config.extraArguments.startIndex
        while i < config.extraArguments.endIndex {
            if config.extraArguments[i] == "--disk-flush", i + 1 < config.extraArguments.endIndex {
                both = config.extraArguments[i + 1]
                i += 1
            }
            i += 1
        }
        self.init(osDisk: config.osDiskFlush ?? both, cacheDisk: both)
    }

    /// The risk an OS disk without ordered flushes carries, as the README
    /// states it.
    public static let osDiskRisk =
        "a host power loss or kernel panic can corrupt the OS disk; recover with "
        + "`micropod machine install --replace-disk`, which loses the images, containers and volumes on it"

    /// The modes, and the risk of each disk whose flushes are not ordered.
    public var description: String {
        let modes = osDisk == cacheDisk ? "\(osDisk) (both disks)" : "OS disk \(osDisk), cache disk \(cacheDisk)"
        var risks: [String] = []
        if osDisk == "fsync" {
            risks.append(
                Self.osDiskRisk
                    + (cacheDisk == "fsync" ? "" : " (the cache disk keeps \(cacheDisk) ordering)"))
        }
        if cacheDisk == "fsync" {
            risks.append("the same can corrupt the cache disk and the dependency stores on it")
        }
        return risks.isEmpty ? modes : "\(modes): " + risks.joined(separator: "; ")
    }
}

/// The `disk flush:` line of `machine status`: what the running VMM was
/// launched with and what the next start uses.
public struct HVFDiskFlushStatus: Codable, Sendable, Equatable {
    /// The running VMM's modes; nil when none runs, or a supervisor that
    /// predates the record launched it.
    public var running: HVFDiskFlush?
    /// From machine.json as it is now.
    public var nextStart: HVFDiskFlush
    /// A VMM runs and the next start uses different modes.
    public var restartPending: Bool
    public var summary: String

    public init(config: HVFMachineConfig, state: HVFMachineState?, supervisorAlive: Bool) {
        let next = HVFDiskFlush(config: config)
        let live = supervisorAlive && state?.vmmPID != nil
        running = live ? state?.diskFlush : nil
        nextStart = next
        restartPending = live && running != next
        if !live {
            summary = "\(next.description) at the next start"
        } else if let running, running == next {
            summary = next.description
        } else if let running {
            summary = "\(running.description); the next start uses \(next.description) (restart to apply)"
        } else {
            summary = "unknown (an older supervisor launched the VMM); the next start uses \(next.description)"
        }
    }
}
