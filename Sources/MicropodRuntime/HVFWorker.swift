import Crypto
import Darwin
import Foundation
import MicropodCore

/// Selects which macOS virtualization backend backs a native Micropod CI worker.
public enum CIWorkerVMM: String, Codable, Sendable {
    case vz
    case hvf

    public static func parse(_ raw: String?) throws -> CIWorkerVMM {
        guard let raw, !raw.isEmpty else { return .vz }
        guard let value = CIWorkerVMM(rawValue: raw.lowercased()) else {
            throw MicropodError.message("MICROPOD_CI_VMM must be 'vz' or 'hvf'")
        }
        return value
    }
}

struct HVFKernelArguments {
    static let environmentKey = "MICROPOD_SANDBOX_KERNEL_ARGS"
    private static let bootClockKey = "mp.boot_realtime_ns"
    private static let workspaceKey = "mp.workspace"
    private static let encodedWorkspaceKey = "mp.workspace_b64"
    private static let workspaceLabelPrefix = "io.micropod.workspace-sha256="
    private static let guestKeys: Set<String> = [
        "mp.worker", "mp.instance", workspaceKey, encodedWorkspaceKey, "mp.mtu", "micropod.ci_sysctls",
    ]
    private static let reserved = guestKeys.union(["--", "console", "panic", bootClockKey])
    private static let quotes = CharacterSet(charactersIn: "\"")

    private enum Selector: String {
        case scheduler = "micropod.ci_sched"
        case wakeup = "micropod.ci_wakeup"
        case congestion = "micropod.ci_cc"
        case idlePoll = "idle_poll_us"

        var supported: [String] {
            switch self {
            case .scheduler: ["hrtick", "hrtick-1ms", "hrtick-500us", "hrtick-250us", "hrtick-125us"]
            case .wakeup:
                ["next-buddy", "next-buddy,sync-colocate", "sync-colocate", "next-buddy,sync-colocate,no-ttwu-queue"]
            case .congestion: ["cubic", "bbr"]
            case .idlePoll: []
            }
        }
    }

    var scheduler = "hrtick-250us"
    var wakeup = "next-buddy,sync-colocate"
    var congestion = "cubic"
    var idlePollUS = 150
    var extra: String?

    static func parse(_ raw: String?) throws -> Self {
        guard let raw else { return Self() }
        var seen = Set<Selector>()
        var result = Self()
        var extra = ""
        var retainedStart = raw.startIndex
        for argument in try arguments(in: raw) {
            let (name, field) = parameter(argument)
            let key = name.trimmingCharacters(in: quotes)
            if reserved.contains(key) {
                throw MicropodError.message("Kernel argument \(key) is reserved by the HVF worker")
            }
            guard let selector = Selector(rawValue: key) else { continue }
            guard seen.insert(selector).inserted else {
                throw MicropodError.message("Specify \(key) at most once in \(environmentKey)")
            }
            switch selector {
            case .idlePoll:
                guard let field, name == key, let us = Int(String(field)), (0...2000).contains(us),
                    String(us) == String(field)
                else {
                    throw MicropodError.message("\(key) must be an integer between 0 and 2000")
                }
                result.idlePollUS = us
            default:
                guard let field, name == key, selector.supported.contains(String(field)) else {
                    let choices = selector.supported.map { "'\($0)'" }.joined(separator: ", ")
                    throw MicropodError.message("\(key) must be one of \(choices)")
                }
                let value = String(field)
                switch selector {
                case .scheduler: result.scheduler = value
                case .wakeup: result.wakeup = value
                case .congestion: result.congestion = value
                case .idlePoll: break
                }
            }
            extra += raw[retainedStart..<argument.startIndex]
            retainedStart = argument.endIndex
        }
        extra += raw[retainedStart...]
        // The VMM's clock guard, guest init and runner still scan whitespace-delimited fields.
        // A Linux-quoted value must not introduce a second managed field into those readers.
        for token in extra.split(whereSeparator: \.isWhitespace) {
            let (name, value) = parameter(token)
            let key = String(name)
            if key.trimmingCharacters(in: quotes) == bootClockKey
                || value != nil && (guestKeys.contains(key) || Selector(rawValue: key) != nil)
            {
                throw MicropodError.message(
                    "Managed kernel argument \(key) must be a separate argument in \(environmentKey)")
            }
        }
        result.extra = extra
        return result
    }

    private static func parameter(_ argument: Substring) -> (Substring, Substring?) {
        guard let equals = argument.utf8.firstIndex(of: 0x3d) else { return (argument, nil) }
        return (argument[..<equals], argument[argument.utf8.index(after: equals)...])
    }

    private static func arguments(in raw: String) throws -> [Substring] {
        let bytes = raw.utf8
        var result: [Substring] = []
        var start: String.Index?
        var quoted = false
        // Linux groups double-quoted text without applying shell escapes.
        for index in bytes.indices {
            let byte = bytes[index]
            guard byte != 0 else { throw MicropodError.message("\(environmentKey) cannot contain a NUL character") }
            if byte == 0x22 { quoted.toggle() }
            if !quoted, byte == 0x20 || (0x09...0x0d).contains(byte) {
                if let begin = start { result.append(raw[begin..<index]) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        guard !quoted else { throw MicropodError.message("Unclosed double quote in \(environmentKey)") }
        if let start { result.append(raw[start...]) }
        return result
    }

    static func workspaceArgument(_ path: String) throws -> String {
        let bytes = path.utf8
        let components = bytes.split(separator: 0x2f, omittingEmptySubsequences: false).dropFirst()
        guard bytes.first == 0x2f, !bytes.contains(0), !components.isEmpty,
            !components.contains(where: { $0.isEmpty || $0.elementsEqual([0x2e]) || $0.elementsEqual([0x2e, 0x2e]) })
        else {
            throw MicropodError.message("The HVF workspace must be a canonical absolute path below the root")
        }
        guard !bytes.contains(0x3a) else {
            throw MicropodError.message("The HVF workspace path cannot contain a colon in the VMM share specification")
        }
        if needsWorkspaceEncoding(path) {
            // The suffix lets guest-init reject an argument truncated to a shorter base64 string.
            return "\(encodedWorkspaceKey)=\(Data(bytes).base64EncodedString())."
        }
        return "\(workspaceKey)=\(path)"
    }

    private static func needsWorkspaceEncoding(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.properties.isWhitespace || $0 == "\"" || $0 == "'" }
    }

    static func workspaceDigest(_ path: String?, strict: Bool = false) -> String? {
        guard let path, strict || needsWorkspaceEncoding(path) else { return nil }
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func attestWorkspace(_ path: String?, labels: [String], strict: Bool = false) throws -> String? {
        let digest = workspaceDigest(path, strict: strict)
        guard strict || digest != nil else { return nil }
        let evidence = labels.filter { $0.hasPrefix(workspaceLabelPrefix) }
        guard evidence == (digest.map { [workspaceLabelPrefix + $0] } ?? []) else {
            throw MicropodError.message(
                "The HVF worker did not attest its workspace. Use a matching initrd and runner tools.")
        }
        return digest
    }
}

/// Metadata recorded alongside a managed HVF warm snapshot (`micropod-snapshot.json`)
/// so restored CoW workers validate topology and preserve the captured guest identity.
public struct HVFManagedSnapshotMetadata: Codable, Sendable, Equatable {
    public let schema: Int
    public let workerID: UUID
    public let instanceID: UUID
    public let cpus: Int
    public let memoryMiB: Int
    public let publishedMTU: UInt32
    public let workspace: String?
    public let diskBytes: UInt64?

    public init(
        schema: Int = 1, workerID: UUID, instanceID: UUID, cpus: Int, memoryMiB: Int,
        publishedMTU: UInt32, workspace: String?, diskBytes: UInt64? = nil
    ) {
        self.schema = schema
        self.workerID = workerID
        self.instanceID = instanceID
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.publishedMTU = publishedMTU
        self.workspace = workspace
        self.diskBytes = diskBytes
    }

    public static let filename = "micropod-snapshot.json"
    private static let generationFiles = [
        "READY", "vmstate.bin", "ram.bin", "disk.ext4", "READY.tmp", "vmstate.bin.tmp", "ram.bin.tmp",
    ]

    private struct Ready: Decodable {
        let ramTotalBytes: UInt64
        let numVcpus: Int
        let memoryMib: Int
    }

    public static func load(from directory: URL) throws -> Self {
        let metaURL = directory.appendingPathComponent(filename)
        let readyURL = directory.appendingPathComponent("READY")
        let meta = try decodeSnapshotJSON(Self.self, at: metaURL, using: JSONDecoder())
        guard meta.schema == 1 else {
            throw MicropodError.message("Unsupported HVF snapshot metadata schema \(meta.schema)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let ready = try decodeSnapshotJSON(Ready.self, at: readyURL, using: decoder)
        let (expectedRAM, overflow) = UInt64(max(0, meta.memoryMiB)).multipliedReportingOverflow(by: 1 << 20)
        guard !overflow, expectedRAM > 0, meta.cpus > 0, ready.ramTotalBytes == expectedRAM,
            ready.memoryMib == meta.memoryMiB, ready.numVcpus == meta.cpus
        else {
            throw MicropodError.message("HVF warm snapshot READY does not match the metadata at \(directory.path)")
        }
        let actualRAM = try regularFileSize(directory.appendingPathComponent("ram.bin"))
        guard actualRAM == expectedRAM else {
            throw MicropodError.message(
                "HVF warm snapshot RAM has \(actualRAM) bytes, expected \(expectedRAM) at \(directory.path)")
        }
        // The VMM checks the binary state schema and checksum before opening the restore disk.
        _ = try regularFileSize(directory.appendingPathComponent("vmstate.bin"), minimum: 16)
        let actualDisk = try ext4FileSize(directory.appendingPathComponent("disk.ext4"))
        if let expectedDisk = meta.diskBytes, actualDisk != expectedDisk {
            throw MicropodError.message(
                "HVF warm snapshot disk has \(actualDisk) bytes, expected \(expectedDisk) at \(directory.path)")
        }
        return meta
    }

    private static func decodeSnapshotJSON<Value: Decodable>(
        _ type: Value.Type, at url: URL, using decoder: JSONDecoder
    ) throws -> Value {
        let size = try regularFileSize(url)
        guard size <= 65536 else { throw MicropodError.message("Oversized HVF snapshot metadata at \(url.path)") }
        let bytes = try Data(contentsOf: url)
        do {
            return try decoder.decode(type, from: bytes)
        } catch {
            throw MicropodError.message("Invalid HVF snapshot metadata at \(url.path): \(error)")
        }
    }

    private static func regularFileSize(_ url: URL, minimum: UInt64 = 1) throws -> UInt64 {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_size >= 0, UInt64(attributes.st_size) >= minimum
        else {
            throw MicropodError.message("Incomplete HVF warm snapshot file at \(url.path)")
        }
        return UInt64(attributes.st_size)
    }

    static func ext4FileSize(_ url: URL) throws -> UInt64 {
        // An older capture may omit diskBytes. The primary ext4 superblock
        // still gives the minimum complete filesystem length, excluding any padding.
        let size = try regularFileSize(url, minimum: 2048)
        guard size.isMultiple(of: 512) else {
            throw MicropodError.message("HVF snapshot disk does not contain whole sectors at \(url.path)")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: 1024)
        guard let header = try file.read(upToCount: 1024), header.count == 1024 else {
            throw MicropodError.message("Missing ext4 superblock in HVF snapshot disk at \(url.path)")
        }
        let (magic, logBlockSize, blocks) = header.withUnsafeBytes { bytes in
            func field(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            let magic = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 0x38, as: UInt16.self))
            let has64BitBlocks = field(0x60) & 0x80 != 0
            let low = UInt64(field(0x04))
            let high = has64BitBlocks ? UInt64(field(0x150)) << 32 : 0
            return (magic, field(0x18), high | low)
        }
        guard magic == 0xef53, logBlockSize <= 6 else {
            throw MicropodError.message("Invalid ext4 superblock in HVF snapshot disk at \(url.path)")
        }
        let (filesystemBytes, overflow) = blocks.multipliedReportingOverflow(by: 1024 << logBlockSize)
        guard !overflow, filesystemBytes >= 2048, filesystemBytes <= size else {
            throw MicropodError.message("Invalid ext4 filesystem length for the HVF snapshot disk at \(url.path)")
        }
        return size
    }

    func validateWorkspace(_ requested: String?) throws {
        switch (workspace, requested) {
        case (nil, nil): return
        case (let saved?, let current?) where saved.utf8.elementsEqual(current.utf8): return
        default:
            let saved = workspace.map { String(reflecting: $0) } ?? "none"
            let current = requested.map { String(reflecting: $0) } ?? "none"
            throw MicropodError.message(
                "HVF warm snapshot workspace \(saved) differs from the configured workspace \(current). "
                    + "Use the captured workspace or take a new snapshot.")
        }
    }

    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in Self.generationFiles {
            let url = directory.appendingPathComponent(name)
            var attributes = stat()
            if lstat(url.path, &attributes) == 0 {
                throw MicropodError.message(
                    "HVF snapshot capture would overwrite \(url.path). Choose a new snapshot directory.")
            }
            guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        let data = try JSONEncoder().encode(self)
        let path = directory.appendingPathComponent(Self.filename).path
        // Claim this generation before publishing the trigger. READY publishes the completed bundle.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST {
            throw MicropodError.message(
                "HVF snapshot capture would overwrite \(path). Choose a new snapshot directory.")
        }
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
    }
}

/// Deterministic command-line launch specification for the Rust Hypervisor.framework VMM (`micropod-vmm`).
public struct HVFWorkerLaunchSpec: Sendable, Equatable {
    public let vmmBinary: URL
    public let kernel: URL
    public let initrd: URL
    public let disk: URL
    public let ociTools: URL
    public let workspace: String?
    public let dockerSocket: URL
    public let ociSocket: URL
    public let buildkitSocket: URL
    public let workerID: UUID
    public let instanceID: UUID
    public let cpus: Int
    public let memoryMiB: Int
    public let publishedMTU: UInt32
    public let extraKernelArgs: String?
    public let expectedParentPID: Int32?
    public let restoreFrom: URL?
    public let snapshotOut: URL?
    public let snapshotTrigger: URL?
    public let telemetrySocket: URL?
    public let prometheusListen: String?
    public let otlpEndpoint: String?
    public let otlpIntervalSecs: Int?
    public let tracingEnabled: Bool
    public let otlpTracesEndpoint: String?
    public let traceSlowMs: Int?
    public let serviceName: String?

    public init(
        vmmBinary: URL, kernel: URL, initrd: URL, disk: URL, ociTools: URL, workspace: String?,
        dockerSocket: URL, ociSocket: URL, buildkitSocket: URL, workerID: UUID, instanceID: UUID,
        cpus: Int, memoryMiB: Int, publishedMTU: UInt32 = 9000, extraKernelArgs: String? = nil,
        expectedParentPID: Int32? = nil, restoreFrom: URL? = nil, snapshotOut: URL? = nil,
        snapshotTrigger: URL? = nil, telemetrySocket: URL? = nil, prometheusListen: String? = nil,
        otlpEndpoint: String? = nil, otlpIntervalSecs: Int? = nil, tracingEnabled: Bool = false,
        otlpTracesEndpoint: String? = nil, traceSlowMs: Int? = nil, serviceName: String? = nil
    ) {
        self.vmmBinary = vmmBinary
        self.kernel = kernel
        self.initrd = initrd
        self.disk = disk
        self.ociTools = ociTools
        self.workspace = workspace
        self.dockerSocket = dockerSocket
        self.ociSocket = ociSocket
        self.buildkitSocket = buildkitSocket
        self.workerID = workerID
        self.instanceID = instanceID
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.publishedMTU = publishedMTU
        self.extraKernelArgs = extraKernelArgs
        self.expectedParentPID = expectedParentPID
        self.restoreFrom = restoreFrom
        self.snapshotOut = snapshotOut
        self.snapshotTrigger = snapshotTrigger
        self.telemetrySocket = telemetrySocket
        self.prometheusListen = prometheusListen
        self.otlpEndpoint = otlpEndpoint
        self.otlpIntervalSecs = otlpIntervalSecs
        self.tracingEnabled = tracingEnabled
        self.otlpTracesEndpoint = otlpTracesEndpoint
        self.traceSlowMs = traceSlowMs
        self.serviceName = serviceName
    }

    /// The command line sent to the VMM, or an empty string when the specification is invalid.
    public var kernelCmdline: String { (try? validatedKernelCmdline()) ?? "" }

    private func validatedKernelCmdline() throws -> String {
        let options = try HVFKernelArguments.parse(extraKernelArgs)
        var parts = [
            "quiet",
            "console=ttyAMA0",
            "rcupdate.rcu_expedited=1",
            "psi=1",
            "cgroup.memory=nokmem,nosocket",
            "slab_min_order=2",
            "swiotlb=noforce",
            "workqueue.power_efficient=1",
            "idle_poll_us=\(options.idlePollUS)",
            "micropod.ci_sched=\(options.scheduler)",
            "micropod.ci_wakeup=\(options.wakeup)",
            "micropod.ci_sysctls=perf",
            "micropod.ci_cc=\(options.congestion)",
            "mp.worker=\(workerID.uuidString)",
            "mp.instance=\(instanceID.uuidString)",
            "mp.mtu=\(publishedMTU)",
        ]
        if let workspace, !workspace.isEmpty {
            parts.append(try HVFKernelArguments.workspaceArgument(workspace))
        }
        if let extra = options.extra?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            parts.append(extra)
        }
        parts.append("panic=-1")
        return parts.joined(separator: " ")
    }

    /// The VMM arguments, or an empty array when the specification is invalid.
    public var arguments: [String] { (try? validatedArguments()) ?? [] }

    /// Build the VMM arguments or report an invalid launch setting.
    public func validatedArguments() throws -> [String] {
        let cmdline = try validatedKernelCmdline()
        for (endpoint, setting) in [
            (otlpEndpoint, "otlp.endpoint"),
            (otlpTracesEndpoint, "tracing.endpoint or otlp.traces_endpoint"),
        ] {
            guard let endpoint, !endpoint.isEmpty else { continue }
            guard endpoint.hasPrefix("http://"), URLComponents(string: endpoint)?.host?.isEmpty == false else {
                throw MicropodError.message("The native HVF OTLP exporter requires an http:// URL for \(setting)")
            }
        }
        return arguments(kernelCmdline: cmdline)
    }

    private func arguments(kernelCmdline: String) -> [String] {
        var args = [
            "--kernel", kernel.path,
            "--initrd", initrd.path,
            "--disk", disk.path,
            "--cpus", String(cpus),
            "--memory-mib", String(memoryMiB),
            "--share", "oci-tools:\(ociTools.path):ro",
        ]
        if let workspace, !workspace.isEmpty {
            args += ["--share", "workspace:\(workspace)"]
        }
        args += [
            "--vsock-expose", "\(dockerSocket.path):2375",
            "--vsock-expose", "\(ociSocket.path):2376",
            "--vsock-expose", "\(buildkitSocket.path):2377",
            "--published-net",
            "--published-mtu", String(publishedMTU),
            "--cmdline", kernelCmdline,
        ]
        if let expectedParentPID {
            args += ["--parent-pid", String(expectedParentPID)]
        }
        if let restoreFrom {
            args += ["--restore-from", restoreFrom.path]
        }
        if let snapshotOut {
            args += ["--snapshot-out", snapshotOut.path]
        }
        if let snapshotTrigger {
            args += ["--snapshot-trigger", snapshotTrigger.path]
        }
        if let telemetrySocket {
            args += ["--telemetry-socket", telemetrySocket.path]
        }
        if let prometheusListen, !prometheusListen.isEmpty {
            args += ["--prometheus-listen", prometheusListen]
        }
        if let otlpEndpoint, !otlpEndpoint.isEmpty {
            args += ["--otlp-endpoint", otlpEndpoint]
            if let otlpIntervalSecs {
                args += ["--otlp-interval-secs", String(otlpIntervalSecs)]
            }
        }
        if tracingEnabled {
            args += ["--trace"]
        }
        if let otlpTracesEndpoint, !otlpTracesEndpoint.isEmpty {
            args += ["--otlp-traces-endpoint", otlpTracesEndpoint]
        }
        if let traceSlowMs {
            args += ["--trace-slow-ms", String(traceSlowMs)]
        }
        if let serviceName, !serviceName.isEmpty {
            args += ["--service-name", serviceName]
        }
        if telemetrySocket != nil || prometheusListen != nil || otlpEndpoint != nil || tracingEnabled
            || otlpTracesEndpoint != nil
        {
            args += ["--worker-id", workerID.uuidString]
        }
        return args
    }
}

extension CIWorker {
    func selectedVMM() throws -> CIWorkerVMM {
        let vmm = try CIWorkerVMM.parse(resourceEnvironment["MICROPOD_CI_VMM"])
        if vmm == .hvf && !isNativeRunner {
            throw MicropodError.message("MICROPOD_CI_VMM=hvf requires MICROPOD_CI_ENGINE=containerd")
        }
        if vmm == .hvf {
            _ = try HVFKernelArguments.parse(resourceEnvironment[HVFKernelArguments.environmentKey])
        }
        return vmm
    }

    func resolveHVFPaths() throws -> (vmmBinary: URL, initrd: URL) {
        let fm = FileManager.default
        let binPath: String
        if let explicit = resourceEnvironment["MICROPOD_CI_HVF_BIN"], !explicit.isEmpty {
            binPath = explicit
        } else if let exeDir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            let sibling = exeDir.appendingPathComponent("micropod-vmm").path
            guard fm.isExecutableFile(atPath: sibling) else {
                throw MicropodError.message(
                    "Set MICROPOD_CI_HVF_BIN to the signed micropod-vmm binary when using MICROPOD_CI_VMM=hvf")
            }
            binPath = sibling
        } else {
            throw MicropodError.message("Missing MICROPOD_CI_HVF_BIN for MICROPOD_CI_VMM=hvf")
        }
        guard fm.isExecutableFile(atPath: binPath) else {
            throw MicropodError.message("MICROPOD_CI_HVF_BIN is not executable: \(binPath)")
        }

        let initrdPath: String
        if let explicit = resourceEnvironment["MICROPOD_CI_HVF_INITRD"], !explicit.isEmpty {
            initrdPath = explicit
        } else {
            let binDir = URL(fileURLWithPath: binPath).deletingLastPathComponent()
            let sibling = binDir.appendingPathComponent("mp-hvf-init.cpio").path
            let bundledResource = binDir.deletingLastPathComponent()
                .appendingPathComponent("Resources/mp-hvf-init.cpio").path
            if fm.fileExists(atPath: sibling) {
                initrdPath = sibling
            } else if fm.fileExists(atPath: bundledResource) {
                initrdPath = bundledResource
            } else {
                throw MicropodError.message(
                    "Set MICROPOD_CI_HVF_INITRD to mp-hvf-init.cpio when using MICROPOD_CI_VMM=hvf")
            }
        }
        guard fm.fileExists(atPath: initrdPath) else {
            throw MicropodError.message("MICROPOD_CI_HVF_INITRD not found: \(initrdPath)")
        }
        return (URL(fileURLWithPath: binPath), URL(fileURLWithPath: initrdPath))
    }

    func resolveHVFKernel(configured: String?, vmmBinary: URL) throws -> URL {
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let fm = FileManager.default
        let binDir = vmmBinary.deletingLastPathComponent()
        let sibling = binDir.appendingPathComponent("vmlinux-hvf").path
        let bundledResource = binDir.deletingLastPathComponent()
            .appendingPathComponent("Resources/vmlinux-hvf").path
        if fm.fileExists(atPath: sibling) {
            return URL(fileURLWithPath: sibling)
        }
        if fm.fileExists(atPath: bundledResource) {
            return URL(fileURLWithPath: bundledResource)
        }
        throw MicropodError.message("MICROPOD_CI_VMM=hvf requires MICROPOD_CI_KERNEL (Linux ARM64 Image)")
    }

    func hvfRestoreSource() throws -> (directory: URL, metadata: HVFManagedSnapshotMetadata)? {
        guard let raw = resourceEnvironment["MICROPOD_CI_HVF_RESTORE_FROM"], !raw.isEmpty else {
            return nil
        }
        let dir = URL(fileURLWithPath: raw).standardizedFileURL
        return (dir, try HVFManagedSnapshotMetadata.load(from: dir))
    }

    func freshHVFRestoreDisk() throws -> URL {
        var attributes = stat()
        if lstat(disk.path, &attributes) == 0 {
            throw MicropodError.message(
                "HVF warm restore needs an absent destination disk at \(disk.path). "
                    + "Use a fresh MICROPOD_CI_HOME to clone the captured disk.")
        }
        guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return disk
    }

    func hvfCaptureSnapshotDirectory() -> URL? {
        guard let raw = resourceEnvironment["MICROPOD_CI_HVF_CAPTURE_SNAPSHOT"], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    public var telemetrySocket: URL {
        directory.appendingPathComponent("telemetry.sock")
    }

    func launchHVFProcess(
        config: Configuration, instanceID: UUID, cpus: Int, diskURL: URL, ociTools: URL,
        restoreFrom: URL? = nil, snapshotOut: URL? = nil, snapshotTrigger: URL? = nil
    ) throws -> Process {
        let (vmmBin, initrd) = try resolveHVFPaths()
        let kernelURL: URL
        if restoreFrom != nil {
            kernelURL = config.kernel.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/dev/null")
        } else {
            kernelURL = try resolveHVFKernel(configured: config.kernel, vmmBinary: vmmBin)
        }
        let obs = try ObservabilityConfig.load(environment: resourceEnvironment)
        let traceActive = OTLPTracer.isEnabled(config: obs, environment: resourceEnvironment)
        let spec = HVFWorkerLaunchSpec(
            vmmBinary: vmmBin,
            kernel: kernelURL,
            initrd: initrd,
            disk: diskURL,
            ociTools: ociTools,
            workspace: config.workspace,
            dockerSocket: dockerSocket,
            ociSocket: ociSocket,
            buildkitSocket: buildkitSocket,
            workerID: config.worker,
            instanceID: instanceID,
            cpus: cpus,
            memoryMiB: config.memoryMiB,
            publishedMTU: config.publishedMTU ?? 9000,
            extraKernelArgs: resourceEnvironment[HVFKernelArguments.environmentKey],
            expectedParentPID: getpid(),
            restoreFrom: restoreFrom,
            snapshotOut: snapshotOut,
            snapshotTrigger: snapshotTrigger,
            telemetrySocket: telemetrySocket,
            prometheusListen: obs.prometheus.enabled ? obs.prometheus.listen : nil,
            otlpEndpoint: obs.otlp.enabled ? obs.otlp.endpoint : nil,
            otlpIntervalSecs: obs.otlp.enabled ? obs.otlp.exportIntervalSecs : nil,
            tracingEnabled: traceActive,
            otlpTracesEndpoint: (traceActive || obs.otlp.enabled) ? obs.effectiveTracesEndpoint : nil,
            traceSlowMs: obs.tracing.slowOpThresholdMs,
            serviceName: obs.serviceName
        )
        let proc = Process()
        proc.executableURL = spec.vmmBinary
        proc.arguments = try spec.validatedArguments()
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        return proc
    }
}
