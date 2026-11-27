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

/// What one launch does about `osDiskFlush`, given whether the payload's
/// micropod-vmm takes `--disk-flush-os` (`HVFVMMFeatures`). A VMM that does
/// not would exit 2 on the flag and leave the machine down, so the launch
/// goes without it: the OS disk then follows `--disk-flush` (barrier unless
/// `extraArguments` say otherwise), which is never less safe than what
/// machine.json asked for being ignored silently.
public struct HVFDiskFlushPlan: Sendable, Equatable {
    /// The modes the VMM runs with.
    public var flush: HVFDiskFlush
    /// Whether the command line carries `--disk-flush-os`.
    public var passesOSDiskFlag: Bool
    /// Why the configured `osDiskFlush` is not in effect; nil when it is,
    /// or none is set.
    public var notInEffect: String?

    /// `payload` names the payload in the reason (`HVFMachinePayload.id`).
    public init(config: HVFMachineConfig, support: HVFVMMFlagSupport, payload: String) {
        let configured = HVFDiskFlush(config: config)
        guard let mode = config.osDiskFlush, support != .supported else {
            self.init(flush: configured, passesOSDiskFlag: config.osDiskFlush != nil, notInEffect: nil)
            return
        }
        var without = config
        without.osDiskFlush = nil
        let flush = HVFDiskFlush(config: without)
        // The mode both disks get anyway: nothing is lost with the flag.
        guard flush != configured else {
            self.init(flush: flush, passesOSDiskFlag: false, notInEffect: nil)
            return
        }
        let flag = HVFVMMFeatures.osDiskFlushFlag
        let why =
            switch support {
            case .unknown(let reason):
                "the micropod-vmm of payload \(payload) did not say whether it takes \(flag) (\(reason)), so it "
                    + "starts without the flag and the OS disk keeps \(flush.osDisk) ordering"
            default:
                "the micropod-vmm of payload \(payload) predates \(flag), so it starts without the flag and the "
                    + "OS disk keeps \(flush.osDisk) ordering; activate a payload that has it (`micropod update hvf`)"
            }
        self.init(
            flush: flush, passesOSDiskFlag: false, notInEffect: "osDiskFlush \(mode) is not in effect: \(why)")
    }

    init(flush: HVFDiskFlush, passesOSDiskFlag: Bool, notInEffect: String?) {
        self.flush = flush
        self.passesOSDiskFlag = passesOSDiskFlag
        self.notInEffect = notInEffect
    }
}

/// The `disk flush:` line of `machine status`: what the running VMM was
/// launched with and what the next start uses.
public struct HVFDiskFlushStatus: Codable, Sendable, Equatable {
    /// The running VMM's modes; nil when none runs, or a supervisor that
    /// predates the record launched it.
    public var running: HVFDiskFlush?
    /// What the next start launches the VMM with: machine.json as it is
    /// now, less an `osDiskFlush` the payload's VMM does not take. nil when
    /// the next start is refused (`nextStartRefused`).
    public var nextStart: HVFDiskFlush?
    /// What machine.json asks for; nil when it does not load.
    public var configured: HVFDiskFlush?
    /// Why the configured `osDiskFlush` is not, or will not be, in effect:
    /// the payload's micropod-vmm does not take `--disk-flush-os`.
    public var notInEffect: String?
    /// Why the next start is refused: machine.json does not load or
    /// validate (an `osDiskFlush` that is not a mode, say).
    public var nextStartRefused: String?
    /// A VMM runs and the next start uses different modes.
    public var restartPending: Bool
    public var summary: String

    /// `support`: whether the VMM the next start boots takes
    /// `--disk-flush-os`; `payload` names it. `configError`: why
    /// machine.json did not load (`config` is then ignored).
    public init(
        config: HVFMachineConfig, configError: String? = nil, state: HVFMachineState?, supervisorAlive: Bool,
        support: HVFVMMFlagSupport = .supported, payload: String = HVFMachinePayload.flatID
    ) {
        let live = supervisorAlive && state?.vmmPID != nil
        running = live ? state?.diskFlush : nil
        let runs =
            !live
            ? nil
            : running.map { [$0.description] + [state?.diskFlushNotInEffect].compactMap { $0 } }?
                .joined(separator: "; ") ?? "unknown (an older supervisor launched the VMM)"
        if let configError {
            nextStart = nil
            configured = nil
            notInEffect = live ? state?.diskFlushNotInEffect : nil
            nextStartRefused = configError
            restartPending = false
            summary = (runs.map { "\($0); " } ?? "") + "the next start is refused: \(configError)"
            return
        }
        let plan = HVFDiskFlushPlan(config: config, support: support, payload: payload)
        let next = plan.flush
        nextStart = next
        configured = HVFDiskFlush(config: config)
        nextStartRefused = nil
        restartPending = live && running != next
        notInEffect = plan.notInEffect ?? (live && !restartPending ? state?.diskFlushNotInEffect : nil)
        if !live {
            summary = ["\(next.description) at the next start", plan.notInEffect].compactMap { $0 }
                .joined(separator: "; ")
        } else if let running, running == next {
            summary = [next.description, notInEffect].compactMap { $0 }.joined(separator: "; ")
        } else {
            let restart = running == nil ? "" : " (restart to apply)"
            summary = ["\(runs ?? ""); the next start uses \(next.description)\(restart)", plan.notInEffect]
                .compactMap { $0 }.joined(separator: "; ")
        }
    }

    /// The status of the machine under `layout` as it is now: machine.json
    /// read afresh, and the VMM the next start boots (`current`) asked
    /// whether it takes `--disk-flush-os` when `osDiskFlush` is set.
    public static func current(
        layout: HVFMachineLayout, state: HVFMachineState?, supervisorAlive: Bool,
        support: (URL) -> HVFVMMFlagSupport = { HVFVMMFeatures.osDiskFlush(vmm: $0) }
    ) -> HVFDiskFlushStatus {
        let config: HVFMachineConfig
        do {
            config = try HVFMachineConfig.load(from: layout.config)
        } catch {
            return HVFDiskFlushStatus(
                config: HVFMachineConfig(), configError: error.localizedDescription, state: state,
                supervisorAlive: supervisorAlive)
        }
        guard config.osDiskFlush != nil else {
            return HVFDiskFlushStatus(config: config, state: state, supervisorAlive: supervisorAlive)
        }
        let payload = layout.resolvePayload()
        return HVFDiskFlushStatus(
            config: config, state: state, supervisorAlive: supervisorAlive, support: support(payload.vmm),
            payload: payload.id)
    }
}
