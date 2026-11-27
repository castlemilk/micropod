import Darwin
import Foundation
import MicropodCore

/// First run of the hvf machine (`micropod setup`, RigService
/// `SetupMachine`, the app's setup view): the runtime files, the OS disk
/// and the cache disk, then a start and the default runtime, each reported
/// as one step. Every source is local: the runtime files and a base disk
/// come from the app bundle, the CLI package or `payload`, or the disk from
/// `diskFrom`. Only an explicit `diskImage` downloads anything.
///
/// Re-running keeps what is there: an installed machine reports each step
/// `kept` and changes nothing. Steps run in order and stop at the first
/// failure; the steps after it stay `pending`.
public struct HVFMachineBootstrap: Sendable {
    public struct Options: Sendable, Equatable {
        /// An app bundle or a directory with the runtime files (and maybe a
        /// base disk); nil: the running executable's package.
        public var payload: URL?
        /// A local ext4 image the disk is cloned (or, across volumes, copied)
        /// from; wins over a bundled base disk.
        public var diskFrom: URL?
        /// An OCI image unpacked into a fresh disk: the one step that pulls
        /// from a registry, taken only when asked for.
        public var diskImage: String?
        public var diskBytes: UInt64
        /// The cache disk's size; nil gives a new machine 32 GiB, and an
        /// installed machine without one none.
        public var cacheDiskBytes: UInt64?
        public var noCacheDisk: Bool
        public var cpus: Int?
        public var memoryMiB: Int?
        public var start: Bool
        public var startTimeout: Duration
        /// With `start` off: who starts the machine instead (`micropod setup
        /// --autostart`: launchd, once the LaunchAgent loads), for the step.
        public var startedBy: String?

        public init(
            payload: URL? = nil, diskFrom: URL? = nil, diskImage: String? = nil, diskBytes: UInt64 = 64 << 30,
            cacheDiskBytes: UInt64? = nil, noCacheDisk: Bool = false, cpus: Int? = nil, memoryMiB: Int? = nil,
            start: Bool = true, startTimeout: Duration = .seconds(180)
        ) {
            self.payload = payload
            self.diskFrom = diskFrom
            self.diskImage = diskImage
            self.diskBytes = diskBytes
            self.cacheDiskBytes = cacheDiskBytes
            self.noCacheDisk = noCacheDisk
            self.cpus = cpus
            self.memoryMiB = memoryMiB
            self.start = start
            self.startTimeout = startTimeout
            startedBy = nil
        }
    }

    /// A new machine's cache disk (sparse: only what the guest writes is
    /// allocated).
    public static let defaultCacheDiskBytes: UInt64 = 32 << 30

    public enum StepID: String, Codable, Sendable, CaseIterable {
        case runtimeFiles = "runtime-files"
        case disk
        case cacheDisk = "cache-disk"
        case start
        case defaultRuntime = "default-runtime"

        public var title: String {
            switch self {
            case .runtimeFiles: "runtime files"
            case .disk: "disk"
            case .cacheDisk: "cache disk"
            case .start: "start"
            case .defaultRuntime: "default runtime"
            }
        }
    }

    public enum StepState: String, Codable, Sendable {
        /// Not reached: an earlier step failed (or `plan` only).
        case pending
        case done
        /// Already in place; nothing changed.
        case kept
        /// Not asked for, or nothing to do.
        case skipped
        case failed
    }

    public struct Step: Codable, Sendable, Equatable {
        public var id: StepID
        public var state: StepState
        public var detail: String

        public init(_ id: StepID, _ state: StepState, _ detail: String) {
            self.id = id
            self.state = state
            self.detail = detail
        }
    }

    public enum Event: Sendable, Equatable {
        /// A step that takes a while (a copy, a pull, a boot) has begun.
        case started(StepID, String)
        /// A line of a running step's progress (the installer's own lines).
        case detail(StepID, String)
        case finished(Step)
    }

    /// The default runtime, read and set; the registry, or a stand-in.
    public struct Runtimes: Sendable {
        public var defaultName: @Sendable () -> String
        public var origin: @Sendable () -> InstallOrigin?

        public init(defaultName: @escaping @Sendable () -> String, origin: @escaping @Sendable () -> InstallOrigin?) {
            self.defaultName = defaultName
            self.origin = origin
        }

        public static func registry(_ registry: EngineRegistry) -> Runtimes {
            Runtimes(defaultName: { registry.defaultName }, origin: { registry.origin })
        }
    }

    public let layout: HVFMachineLayout
    public let options: Options
    let client: HVFMachineClient
    let packagedExecutable: URL?
    let runtimes: Runtimes

    public init(
        layout: HVFMachineLayout, options: Options, environment: [String: String] = ProcessInfo.processInfo.environment,
        packagedExecutable: URL? = CLIInstall.currentExecutable(), runtimes: Runtimes = .registry(.shared)
    ) {
        self.layout = layout
        self.options = options
        client = HVFMachineClient(layout: layout, environment: environment)
        self.packagedExecutable = packagedExecutable
        self.runtimes = runtimes
    }

    // MARK: Plan

    /// What each install step will do, decided before anything is touched.
    struct Plan: Sendable {
        var runtimeFiles: Step
        var disk: Step
        var cacheDisk: Step
        var distribution: URL?
        var diskFrom: URL?
        var diskImage: String?
        var cacheDiskBytes: UInt64?
        var steps: [Step] { [runtimeFiles, disk, cacheDisk] }
        var failure: Step? { steps.first { $0.state == .failed } }
        var firstPending: StepID { steps.first { $0.state == .pending }?.id ?? .runtimeFiles }
        /// Any install step has something to do.
        var installs: Bool { steps.contains { $0.state == .pending } }
    }

    /// The runtime files a machine needs, by layout name, and their names in
    /// a package (`bin` holds the VMM, `resources` the rest).
    static let runtimeFiles: [(layout: String, packaged: String, inBin: Bool)] = [
        ("micropod-vmm", "micropod-vmm", true), ("Image", "vmlinux-hvf", false),
        ("mp-hvf-init.cpio", "mp-hvf-init.cpio", false), ("tools/", "micropod-oci-tools", false),
    ]

    public static let payloadHint =
        "pass --payload <Micropod.app or a directory holding micropod-vmm, vmlinux-hvf, mp-hvf-init.cpio, "
        + "micropod-oci-tools>"

    public static var noBaseDisk: String {
        let image = HVFMachineInstaller.defaultDiskImage.split(separator: "@").first.map(String.init) ?? "docker"
        let short = image.replacingOccurrences(of: "docker.io/library/", with: "")
        return "no base disk: this package ships none. Pass --disk-from <ext4> (a local image), or "
            + "--disk-image default to download \(short) from Docker Hub."
    }

    /// The package runtime files and a base disk come from.
    func distribution() -> (url: URL?, problem: String?) {
        if let payload = options.payload {
            let path = HVFMachineLayout.canonicalPath(NSString(string: payload.path).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return (nil, "--payload \(payload.path) is not a directory") }
            return (URL(fileURLWithPath: path), nil)
        }
        return (packagedExecutable.flatMap(HVFMachineInstaller.packageDirectory(for:)), nil)
    }

    func makePlan() -> Plan {
        let fm = FileManager.default
        let (distribution, distributionProblem) = distribution()
        let directories = distribution.map(HVFMachineInstaller.distributionDirectories(forDistribution:))
        var plan = Plan(
            runtimeFiles: Step(.runtimeFiles, .pending, ""), disk: Step(.disk, .pending, ""),
            cacheDisk: Step(.cacheDisk, .pending, ""), distribution: distribution)

        // Runtime files.
        let missing = layout.missingAssets().filter { $0 != "disk.ext4" }.map {
            $0.hasPrefix("tools/") ? "tools/" : $0
        }
        if missing.isEmpty {
            plan.runtimeFiles = Step(.runtimeFiles, .kept, "present, kept")
        } else if let distributionProblem {
            plan.runtimeFiles = Step(.runtimeFiles, .failed, distributionProblem)
        } else if let directories, let distribution {
            var absent: [String] = []
            var vmm: URL?
            for file in Self.runtimeFiles where missing.contains(file.layout) {
                let directory = file.inBin ? directories.bin : directories.resources
                guard let found = HVFMachineInstaller.packaged(file.packaged, in: directory) else {
                    absent.append(file.packaged)
                    continue
                }
                if file.layout == "tools/",
                    !fm.fileExists(atPath: found.appendingPathComponent("runner/start.sh").path)
                {
                    absent.append("\(file.packaged)/runner/start.sh")
                }
                if file.inBin { vmm = found }
            }
            if !absent.isEmpty {
                plan.runtimeFiles = Step(
                    .runtimeFiles, .failed,
                    "\(distribution.path) has no \(absent.joined(separator: ", ")); \(Self.payloadHint)")
            } else if let vmm, let problem = Self.signatureProblem(vmm) {
                plan.runtimeFiles = Step(.runtimeFiles, .failed, problem)
            } else {
                let names = Self.runtimeFiles.filter { missing.contains($0.layout) }.map {
                    $0.layout == "tools/" ? "tools/" : $0.layout
                }
                plan.runtimeFiles = Step(
                    .runtimeFiles, .pending, "\(names.joined(separator: ", ")) from \(distribution.path)")
            }
        } else {
            plan.runtimeFiles = Step(.runtimeFiles, .failed, Self.payloadHint)
        }

        // Disk.
        let diskPresent = HVFMachineLayout.isRegularFile(layout.disk)
        if options.diskFrom != nil, options.diskImage != nil {
            plan.disk = Step(.disk, .failed, "pass either --disk-from or --disk-image, not both")
        } else if diskPresent {
            let ignored =
                options.diskFrom != nil || options.diskImage != nil
                ? " (the disk holds this machine's containers; `micropod machine install --replace-disk` replaces it)"
                : ""
            plan.disk = Step(.disk, .kept, "present, kept" + ignored)
        } else if let diskFrom = options.diskFrom {
            let disk = URL(fileURLWithPath: HVFMachineLayout.canonicalPath(diskFrom.path))
            if !HVFMachineLayout.isRegularFile(disk) {
                plan.disk = Step(.disk, .failed, "--disk-from \(diskFrom.path) is not a file")
            } else if !HVFMachineInstaller.isExt4(disk) {
                plan.disk = Step(.disk, .failed, "--disk-from \(diskFrom.path) is not an ext4 image")
            } else {
                plan.diskFrom = disk
                plan.disk = Step(.disk, .pending, "from \(disk.path)")
            }
        } else if let image = options.diskImage {
            plan.diskImage = image
            plan.disk = Step(.disk, .pending, "unpacked from \(image) (downloads it)")
        } else if let resources = directories?.resources,
            let base = HVFMachineInstaller.packaged(HVFMachineInstaller.baseDiskName, in: resources)
        {
            if HVFMachineInstaller.isExt4(base) {
                plan.diskFrom = base
                plan.disk = Step(.disk, .pending, "from \(base.path)")
            } else {
                plan.disk = Step(.disk, .failed, "\(base.path) is not an ext4 image")
            }
        } else {
            plan.disk = Step(.disk, .failed, Self.noBaseDisk)
        }

        // Cache disk.
        let config = try? HVFMachineConfig.load(from: layout.config)
        if HVFMachineLayout.isRegularFile(layout.cacheDisk) {
            let size = layout.cacheDiskBytes().map { " (\(Self.size($0)))" } ?? ""
            plan.cacheDisk = Step(.cacheDisk, .kept, "present, kept\(size)")
        } else if options.noCacheDisk {
            plan.cacheDisk = Step(.cacheDisk, .skipped, "none (--no-cache-disk): the caches live on the OS disk")
        } else if let bytes = options.cacheDiskBytes ?? config?.cacheDiskBytes
            ?? (diskPresent ? nil : Self.defaultCacheDiskBytes)
        {
            if bytes < 256 << 20 {
                plan.cacheDisk = Step(.cacheDisk, .failed, "--cache-disk-size needs at least 256 MiB")
            } else {
                plan.cacheDiskBytes = bytes
                plan.cacheDisk = Step(.cacheDisk, .pending, "\(Self.size(bytes)) sparse")
            }
        } else {
            plan.cacheDisk = Step(
                .cacheDisk, .skipped, "none (the installed machine has none; --cache-disk-size 32g adds one)")
        }
        return plan
    }

    /// "32 GiB", "1.5 GiB", "256 MiB".
    public static func size(_ bytes: UInt64) -> String {
        let gib: UInt64 = 1 << 30
        if bytes >= gib {
            return bytes % gib == 0 ? "\(bytes / gib) GiB" : String(format: "%.1f GiB", Double(bytes) / Double(gib))
        }
        return "\(bytes >> 20) MiB"
    }

    /// The installer's codesign refusal for `vmm`, if it has one.
    static func signatureProblem(_ vmm: URL) -> String? {
        do {
            try HVFMachineInstaller.verifyHypervisorEntitlement(vmm)
            return nil
        } catch {
            return errorText(error)
        }
    }

    /// An error's message without the Connect code prefix.
    public static func errorText(_ error: any Error) -> String {
        let message = error.localizedDescription
        for code in ["failedPrecondition: ", "invalidArgument: ", "unavailable: ", "notFound: "]
        where message.hasPrefix(code) {
            return String(message.dropFirst(code.count))
        }
        return message
    }

    /// Every step as it stands, without running any (failed steps say why
    /// the run would stop there).
    public func plan() -> [Step] {
        let plan = makePlan()
        return plan.steps + [startPlan(), Step(.defaultRuntime, .pending, defaultRuntimeDetail())]
    }

    func startPlan() -> Step {
        if client.isServing { return Step(.start, .kept, "running") }
        guard options.start else {
            if let startedBy = options.startedBy { return Step(.start, .skipped, startedBy) }
            return Step(.start, .skipped, "not started (--no-start): `micropod machine start` boots it")
        }
        return Step(.start, .pending, "")
    }

    func defaultRuntimeDetail() -> String {
        let name = runtimes.defaultName()
        if name == "hvf" { return "hvf" }
        let why = runtimes.origin() == .fresh ? "kept" : "kept: an existing install keeps its default"
        return "\(name) (\(why); `micropod runtime use hvf` switches)"
    }

    // MARK: Run

    /// Runs the steps in order and returns all five; the run stops at the
    /// first failure, leaving the rest `pending`.
    public func run(progress: @escaping @Sendable (Event) -> Void = { _ in }) async -> [Step] {
        var plan = makePlan()
        var steps: [Step] = []
        func finish(_ step: Step) {
            steps.append(step)
            progress(.finished(step))
        }
        func pendingRest(after id: StepID) -> [Step] {
            StepID.allCases.drop { $0 != id }.dropFirst().map { Step($0, .pending, "not reached") }
        }

        if plan.failure != nil {
            // Every install step's source is checked before anything is
            // changed: each problem is reported at once.
            for step in plan.steps {
                finish(step.state == .pending ? Step(step.id, .pending, "nothing was changed") : step)
            }
            return steps + pendingRest(after: .cacheDisk)
        }

        if plan.installs {
            let request = HVFInstallRequest(
                diskFrom: plan.disk.state == .pending ? plan.diskFrom : nil,
                diskImage: plan.disk.state == .pending ? plan.diskImage : nil, diskBytes: options.diskBytes,
                cacheDiskBytes: plan.cacheDisk.state == .pending ? plan.cacheDiskBytes : nil,
                cpus: options.cpus, memoryMiB: options.memoryMiB,
                distribution: plan.runtimeFiles.state == .pending ? plan.distribution : nil,
                copyDiskAcrossVolumes: true)
            let current = InstallProgress()
            let firstPending = plan.firstPending
            if let image = plan.diskImage, plan.disk.state == .pending {
                progress(.started(.disk, "pulling \(image)"))
            }
            do {
                let warnings = try await HVFMachineInstaller.install(request, layout: layout, packagedExecutable: nil) {
                    line in
                    progress(.detail(current.observe(line, fallback: firstPending), line))
                }
                for warning in warnings { progress(.detail(.cacheDisk, "warning: \(warning)")) }
            } catch {
                let message = Self.errorText(error)
                let failedID = Self.attribute(message, plan: plan, progress: current)
                for step in plan.steps.prefix(while: { $0.id != failedID }) {
                    let committed = step.id == .runtimeFiles ? current.filesCommitted : current.step != step.id
                    finish(
                        step.state != .pending
                            ? step
                            : committed
                                ? Step(step.id, .done, step.detail)
                                : Step(step.id, .pending, "not changed"))
                }
                finish(Step(failedID, .failed, message))
                return steps + pendingRest(after: failedID)
            }
            if plan.runtimeFiles.state == .pending { plan.runtimeFiles.state = .done }
            if plan.disk.state == .pending {
                plan.disk = Step(
                    .disk, .done,
                    plan.diskImage.map { "created from \($0)" }
                        ?? "\(current.diskCopied ? "copied" : "cloned") \(plan.disk.detail)")
            }
            if plan.cacheDisk.state == .pending {
                plan.cacheDisk = Step(.cacheDisk, .done, "created (\(plan.cacheDisk.detail))")
            }
        }
        for step in plan.steps { finish(step) }

        // Start.
        var start = startPlan()
        if start.state == .pending {
            progress(.started(.start, "booting (up to \(options.startTimeout.components.seconds) s)"))
            do {
                try await client.ensureRunning(timeout: options.startTimeout)
                start = Step(.start, .done, await runningDetail())
            } catch {
                finish(Step(.start, .failed, Self.errorText(error)))
                return steps + pendingRest(after: .start)
            }
        } else if start.state == .kept {
            start.detail = await runningDetail()
        }
        finish(start)

        finish(Step(.defaultRuntime, runtimes.defaultName() == "hvf" ? .done : .kept, defaultRuntimeDetail()))
        return steps
    }

    /// "running (engine micropod 0.4.1, Docker API 1.44–1.47)".
    func runningDetail() async -> String {
        guard let engine = await client.engineVersion(timeout: .seconds(3)) else { return "running" }
        let name = engine.version.isEmpty ? "" : "engine \(engine.version), "
        return "running (\(name)Docker API \(engine.minAPIVersion)–\(engine.apiVersion))"
    }

    /// The installer's failure belongs to the step it was committing, else
    /// to the step whose source it names (staging copies, clones and pulls
    /// everything before committing any of it), else to the first step
    /// with work.
    static func attribute(_ message: String, plan: Plan, progress: InstallProgress) -> StepID {
        if progress.step != .runtimeFiles { return progress.step }
        if plan.disk.state == .pending {
            let names = [plan.diskFrom?.path, plan.diskImage, "disk.ext4", "clone", "pull", "unpack"].compactMap { $0 }
            if names.contains(where: { message.contains($0) }) { return .disk }
        }
        if plan.cacheDisk.state == .pending, message.contains("caches.ext4") || message.contains("cache-disk") {
            return .cacheDisk
        }
        return plan.firstPending
    }

    /// The step the installer is on, read from the lines it prints as it
    /// commits: runtime files, then the disk, then the cache disk.
    final class InstallProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var current: StepID = .runtimeFiles
        private var committedFiles = false
        private var copied = false

        var step: StepID { lock.withLock { current } }
        var filesCommitted: Bool { lock.withLock { committedFiles } }
        var diskCopied: Bool { lock.withLock { copied } }

        /// Records `line` and returns the step it belongs to.
        func observe(_ line: String, fallback: StepID) -> StepID {
            lock.withLock {
                if line.hasPrefix("installed ") {
                    committedFiles = true
                    current = .runtimeFiles
                } else if line.hasPrefix("cloned disk.ext4") || line.hasPrefix("copied disk.ext4")
                    || line.hasPrefix("created disk.ext4")
                {
                    copied = copied || line.hasPrefix("copied")
                    current = .disk
                } else if line.hasPrefix("created persistent caches.ext4") {
                    current = .cacheDisk
                } else if !committedFiles, current == .runtimeFiles {
                    return fallback
                }
                return current
            }
        }
    }

    /// One line per step, as `micropod setup` prints it:
    /// `[2/5] disk            cloned from …`.
    public static func line(_ step: Step) -> String {
        let index = (StepID.allCases.firstIndex(of: step.id) ?? 0) + 1
        let title = step.id.title.padding(toLength: 16, withPad: " ", startingAt: 0)
        let prefix: String =
            switch step.state {
            case .failed: "failed: "
            case .pending: "pending: "
            default: ""
            }
        return "[\(index)/\(StepID.allCases.count)] \(title)\(prefix)\(step.detail)"
    }
}
