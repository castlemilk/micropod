import Foundation
import MicropodCore
import Testing

@testable import MicropodRuntime

@Suite("HVF Worker Integration")
struct HVFWorkerTests {
    @Test("CIWorkerVMM parses default, vz, hvf, and rejects unknown values")
    func parseVMMSelection() throws {
        #expect(try CIWorkerVMM.parse(nil) == .vz)
        #expect(try CIWorkerVMM.parse("") == .vz)
        #expect(try CIWorkerVMM.parse("vz") == .vz)
        #expect(try CIWorkerVMM.parse("HVF") == .hvf)
        #expect(throws: Error.self) {
            _ = try CIWorkerVMM.parse("qemu")
        }
    }

    @Test("CIWorker rejects MICROPOD_CI_VMM=hvf on legacy docker engine")
    func rejectsDockerEngineWithHVF() {
        let worker = CIWorker(environment: [
            "MICROPOD_CI_ENGINE": "docker",
            "MICROPOD_CI_VMM": "hvf",
        ])
        #expect(throws: Error.self) {
            _ = try worker.selectedVMM()
        }
    }

    @Test("CIWorker accepts MICROPOD_CI_VMM=hvf on containerd native engine")
    func acceptsContainerdEngineWithHVF() throws {
        let worker = CIWorker(environment: [
            "MICROPOD_CI_ENGINE": "containerd",
            "MICROPOD_CI_VMM": "hvf",
        ])
        #expect(try worker.selectedVMM() == .hvf)
    }

    @Test("Explicit backend selection checks the live session before handing out any endpoint")
    func refuseWrongBackend() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: home) }
        let base = ["MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd"]
        let worker = CIWorker(environment: base)
        try worker.prepareDirectory()
        let owner = try #require(try RuntimeProcessBirth.read(getpid()))
        let file = home.appendingPathComponent("session.json")
        let unused = home.appendingPathComponent("unused")
        // Older VZ supervisors omitted the repair flag or set it to true. The initial HVF supervisor wrote false.
        for (recorded, repair, expected) in [
            (nil, nil, CIWorkerVMM.vz), (nil, true, .vz), (nil, false, .hvf), (.hvf, true, .hvf), (.vz, false, .vz),
        ] as [(CIWorkerVMM?, Bool?, CIWorkerVMM)] {
            let active = CIWorker.Session(owner: owner, instance: UUID(), vmm: recorded, supportsNetworkRepair: repair)
            try JSONEncoder().encode(active).write(to: file, options: .atomic)
            let wrong = expected == .vz ? "hvf" : "vz"
            let client = CIWorker(environment: base.merging(["MICROPOD_CI_VMM": wrong]) { _, new in new })
            let error =
                "Requested VMM \(wrong), but the active worker uses \(expected.rawValue) at \(worker.directory.path)"
            await #expect(throws: MicropodError.message(error)) { _ = try await client.start(executable: unused) }
            await #expect(throws: MicropodError.message(error)) { _ = try await client.runEndpoint(executable: unused) }
            await #expect(throws: MicropodError.message(error)) { try await client.stop() }
            await #expect(throws: MicropodError.message("CI worker is booting")) { _ = try await worker.status() }
        }
    }

    @Test("A malformed session can be replaced once its supervisor releases the lifetime lock")
    func staleSession() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: home) }
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path])
        try worker.prepareDirectory()
        try Data("{".utf8).write(to: home.appendingPathComponent("session.json"))
        let fd = open(home.appendingPathComponent("worker.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: DecodingError.self) { _ = try await worker.status() }
        try #require(flock(fd, LOCK_UN) == 0)
        await #expect(throws: MicropodError.message("CI worker is stopped")) { _ = try await worker.status() }
    }

    @Test("A matching stop acknowledgement and released worker lock complete a foreground stop")
    func stopWithUnreapedOwner() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: home) }
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path])
        try worker.prepareDirectory()
        let owner = try #require(try RuntimeProcessBirth.read(getpid()))
        let active = CIWorker.Session(owner: owner, instance: UUID())
        let record = home.appendingPathComponent("session.json")
        try JSONEncoder().encode(active).write(to: record, options: .atomic)
        let fd = open(home.appendingPathComponent("worker.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let stop = Task { try await worker.stop() }
        defer { stop.cancel() }
        let request = home.appendingPathComponent("stop-" + active.instance.uuidString)
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: request.path) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        try Data(active.instance.uuidString.utf8).write(to: home.appendingPathComponent("stopped"), options: .atomic)
        try FileManager.default.removeItem(at: record)
        try #require(flock(fd, LOCK_UN) == 0)
        try await stop.value
    }

    @Test("A native worker reserves enough Unix socket path space for BuildKit")
    func buildkitPathLimit() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString.prefix(8))
            .standardizedFileURL
        defer { try? FileManager.default.removeItem(at: base) }
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let count = limit - base.path.utf8.count - "/x/buildkit.sock".utf8.count + 1
        try #require(count > 0)
        let home = base.appendingPathComponent(String(repeating: "w", count: count))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd"])
        #expect(worker.ociSocket.path.utf8.count < limit)
        #expect(worker.buildkitSocket.path.utf8.count == limit)
        #expect(throws: MicropodError.message("CI socket path is too long: \(worker.buildkitSocket.path)")) {
            try worker.prepareDirectory()
        }
    }

    @Test("Only native HVF includes the telemetry socket in its path limit")
    func telemetryPathLimit() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString.prefix(8))
            .standardizedFileURL
        defer { try? fm.removeItem(at: base) }
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let count = limit - base.path.utf8.count - "/telemetry.sock".utf8.count - 1
        try #require(count > 1)
        let home = base.appendingPathComponent(String(repeating: "w", count: count))
        let hvf = CIWorker(environment: [
            "MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "HVF",
        ])
        #expect(hvf.buildkitSocket.path.utf8.count < limit)
        #expect(hvf.telemetrySocket.path.utf8.count == limit)
        #expect(throws: MicropodError.message("CI socket path is too long: \(hvf.telemetrySocket.path)")) {
            try hvf.prepareDirectory()
        }
        #expect(!fm.fileExists(atPath: home.path))
        try CIWorker(environment: [
            "MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "vz",
        ]).prepareDirectory()
        try CIWorker(environment: ["MICROPOD_CI_HOME": home.path]).prepareDirectory()

        let shorter = base.appendingPathComponent(String(repeating: "w", count: count - 1))
        let fitting = CIWorker(environment: [
            "MICROPOD_CI_HOME": shorter.path, "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "hvf",
        ])
        #expect(fitting.telemetrySocket.path.utf8.count == limit - 1)
        try fitting.prepareDirectory()
    }

    @Test("Reopening a writable CI disk requires a single owned regular file")
    func writableDiskIdentity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: home) }
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path])
        try worker.prepareDirectory()
        try Data("volume".utf8).write(to: worker.disk)
        #expect(try worker.validatedDisk() == worker.disk)
        let other = home.appendingPathComponent("other")
        try FileManager.default.linkItem(at: worker.disk, to: other)
        #expect(throws: Error.self) { _ = try worker.validatedDisk() }
        try FileManager.default.removeItem(at: worker.disk)
        try FileManager.default.createSymbolicLink(at: worker.disk, withDestinationURL: other)
        #expect(throws: Error.self) { _ = try worker.validatedDisk() }
    }

    private func launchSpec(extra: String? = nil, workspace: String? = "/Users/dev/repo") -> HVFWorkerLaunchSpec {
        let wid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let iid = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
        return HVFWorkerLaunchSpec(
            vmmBinary: URL(fileURLWithPath: "/opt/micropod/micropod-vmm"),
            kernel: URL(fileURLWithPath: "/opt/micropod/Image"),
            initrd: URL(fileURLWithPath: "/opt/micropod/mp-hvf-init.cpio"),
            disk: URL(fileURLWithPath: "/tmp/ci/worker.ext4"),
            ociTools: URL(fileURLWithPath: "/opt/micropod/oci-tools"),
            workspace: workspace,
            dockerSocket: URL(fileURLWithPath: "/tmp/ci/docker.sock"),
            ociSocket: URL(fileURLWithPath: "/tmp/ci/oci.sock"),
            buildkitSocket: URL(fileURLWithPath: "/tmp/ci/buildkit.sock"),
            workerID: wid,
            instanceID: iid,
            cpus: 4,
            memoryMiB: 4096,
            publishedMTU: 9000,
            extraKernelArgs: extra
        )
    }

    @Test("HVFWorkerLaunchSpec builds deterministic CLI arguments and cmdline")
    func launchSpecArguments() throws {
        let spec = launchSpec(extra: "loglevel=4")
        let args = spec.arguments
        #expect(args == (try spec.validatedArguments()))
        #expect(!args.contains("--parent-pid"))
        #expect(args.contains("--published-net"))
        #expect(args.contains("oci-tools:/opt/micropod/oci-tools:ro"))
        #expect(args.contains("workspace:/Users/dev/repo"))
        #expect(args.contains("/tmp/ci/docker.sock:2375"))
        #expect(args.contains("/tmp/ci/oci.sock:2376"))
        #expect(args.contains("/tmp/ci/buildkit.sock:2377"))
        #expect(spec.kernelCmdline.contains("mp.worker=11111111-2222-3333-4444-555555555555"))
        #expect(spec.kernelCmdline.contains("mp.instance=66666666-7777-8888-9999-AAAAAAAAAAAA"))
        #expect(spec.kernelCmdline.contains("mp.workspace=/Users/dev/repo"))
        #expect(spec.kernelCmdline.contains("idle_poll_us=150"))
        #expect(spec.kernelCmdline.contains("micropod.ci_sysctls=perf"))
        #expect(spec.kernelCmdline.contains("micropod.ci_sched=hrtick-250us"))
        #expect(spec.kernelCmdline.contains("micropod.ci_wakeup=next-buddy,sync-colocate"))
        #expect(spec.kernelCmdline.contains("micropod.ci_cc=cubic"))
        #expect(spec.kernelCmdline.contains("loglevel=4"))
    }

    @Test("All launch arguments use the selected profile and preserve unrelated Linux quotes")
    func publicArgumentsMatchValidatedArguments() throws {
        let note = #"note="two  spaces -- console=ttyS0" word="four  five""#
        let spec = launchSpec(
            extra: "loglevel=4\t\(note)\n"
                + "micropod.ci_sched=hrtick-125us micropod.ci_cc=bbr micropod.ci_wakeup=next-buddy")
        let args = try spec.validatedArguments()
        #expect(spec.arguments == args)
        let option = try #require(args.firstIndex(of: "--cmdline"))
        let cmdline = args[option + 1]
        #expect(spec.kernelCmdline == cmdline)
        #expect(cmdline.contains("loglevel=4\t\(note)"))
        let options = cmdline.split(whereSeparator: \.isWhitespace)
        #expect(options.filter { $0.hasPrefix("micropod.ci_sched=") } == ["micropod.ci_sched=hrtick-125us"])
        #expect(options.filter { $0.hasPrefix("micropod.ci_wakeup=") } == ["micropod.ci_wakeup=next-buddy"])
        #expect(options.filter { $0.hasPrefix("micropod.ci_cc=") } == ["micropod.ci_cc=bbr"])
    }

    @Test("The HVF workspace encoding matches guest-init and its Docker readiness evidence")
    func workspaceProtocol() throws {
        let workspace = #"/private/tmp/build "two words" µ"#
        let spec = launchSpec(workspace: workspace)
        let flag = "mp.workspace_b64=L3ByaXZhdGUvdG1wL2J1aWxkICJ0d28gd29yZHMiIMK1."
        #expect(spec.kernelCmdline.split(separator: " ").contains(Substring(flag)))
        #expect(!spec.kernelCmdline.contains("mp.workspace="))
        #expect(try spec.validatedArguments().contains("workspace:\(workspace)"))

        let digest = "abb068e4cbe6891a3d3eae567b8dc117ff8188acc867e3cb7636b9b5ebbf383a"
        let label = "io.micropod.workspace-sha256=" + digest
        #expect(try HVFKernelArguments.attestWorkspace(workspace, labels: [label]) == digest)
        #expect(try HVFKernelArguments.attestWorkspace("/Users/dev/repo", labels: []) == nil)
        for labels in [[], [label, label], ["io.micropod.workspace-sha256=wrong"]] {
            #expect(throws: MicropodError.self) {
                _ = try HVFKernelArguments.attestWorkspace(workspace, labels: labels)
            }
        }
    }

    @Test("HVF passes the real workspace path with embedded quotes and kernel-like text")
    func workspaceUsesCanonicalPath() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/mp-share-" + UUID().uuidString)
        let directory = root.appendingPathComponent(#"checkout "for CI" mp.instance=literal"#)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: directory)
        let physical = try CIWorker.workspacePath(alias.path)
        #expect(physical == "/private" + directory.path)
        let spec = launchSpec(workspace: physical)
        let argv = try spec.validatedArguments()
        #expect(argv.contains("workspace:\(physical)"))
        #expect(!spec.kernelCmdline.contains("mp.instance=literal"))
        let prefix = "mp.workspace_b64="
        let field = try #require(spec.kernelCmdline.split(separator: " ").first { $0.hasPrefix(prefix) })
        let decoded = Data(base64Encoded: String(field.dropFirst(prefix.count).dropLast()))
        #expect(decoded == Data(physical.utf8))
    }

    @Test(
        "Ambiguous workspace share specifications fail before launch",
        arguments: [
            "/", "relative", "/private/tmp/../first", "/private/tmp/a:b", "/private/tmp/zero\0suffix",
        ])
    func rejectsInvalidWorkspacePaths(path: String) {
        let spec = launchSpec(workspace: path)
        #expect(throws: MicropodError.self) { _ = try spec.validatedArguments() }
        #expect(spec.arguments.isEmpty)
    }

    @Test("An older active HVF session cannot be joined for an unattested encoded workspace")
    func runningHVFRequiresWorkspaceEvidence() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/mp-share-" + UUID().uuidString.prefix(8))
        let workspace = root.appendingPathComponent("shared files")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let worker = CIWorker(environment: [
            "MICROPOD_CI_HOME": root.appendingPathComponent("worker").path, "MICROPOD_CI_ENGINE": "containerd",
            "MICROPOD_CI_VMM": "hvf", "MICROPOD_CI_WORKSPACE": workspace.path,
        ])
        try worker.prepareDirectory()
        _ = try worker.configuration(create: true)
        let owner = try #require(try RuntimeProcessBirth.read(getpid()))
        let old = CIWorker.Session(owner: owner, instance: UUID(), vmm: .hvf, started: true)
        try JSONEncoder().encode(old).write(to: worker.directory.appendingPathComponent("session.json"))
        let error = MicropodError.message(
            "The active HVF worker did not attest the configured workspace. Restart it with matching components.")
        await #expect(throws: error) { _ = try await worker.status() }
        let unused = root.appendingPathComponent("no-process")
        await #expect(throws: error) { _ = try await worker.runEndpoint(executable: unused) }
    }

    @Test("Managed snapshots require workspace evidence even for ordinary paths and absent shares")
    func managedSnapshotWorkspaceEvidence() throws {
        let workspace = "/Users/dev/repo"
        let digest = try #require(HVFKernelArguments.workspaceDigest(workspace, strict: true))
        let label = "io.micropod.workspace-sha256=" + digest
        #expect(try HVFKernelArguments.attestWorkspace(workspace, labels: []) == nil)
        #expect(try HVFKernelArguments.attestWorkspace(workspace, labels: [label], strict: true) == digest)
        #expect(try HVFKernelArguments.attestWorkspace(nil, labels: ["io.micropod.instance=a"], strict: true) == nil)
        for labels in [[], [label, label], ["io.micropod.workspace-sha256=stale"]] {
            #expect(throws: MicropodError.self) {
                _ = try HVFKernelArguments.attestWorkspace(workspace, labels: labels, strict: true)
            }
        }
        #expect(throws: MicropodError.self) {
            _ = try HVFKernelArguments.attestWorkspace(nil, labels: [label], strict: true)
        }
    }

    @Test("Restore workspace matching is byte exact and distinguishes an absent share")
    func managedSnapshotFrozenWorkspace() throws {
        let workspace = "/private/tmp/caf\u{e9}"
        let alternate = "/private/tmp/cafe\u{301}"
        #expect(workspace == alternate)
        try snapshotMetadata(workspace: workspace).validateWorkspace(workspace)
        for requested in [alternate, "/private/tmp/other", nil] {
            #expect(throws: MicropodError.self) {
                try snapshotMetadata(workspace: workspace).validateWorkspace(requested)
            }
        }
        try snapshotMetadata(workspace: nil).validateWorkspace(nil)
        #expect(throws: MicropodError.self) { try snapshotMetadata(workspace: nil).validateWorkspace(workspace) }
    }

    @Test("An invalid snapshot workspace does not write the destination worker manifest")
    func managedSnapshotValidatesWorkspaceBeforeProvisioning() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/mp-snap-" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("worker")
        let workspace = root.appendingPathComponent("workspace")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let worker = CIWorker(environment: [
            "MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd",
            "MICROPOD_CI_VMM": "hvf", "MICROPOD_CI_WORKSPACE": workspace.path,
        ])
        try worker.prepareDirectory()
        let canonical = try CIWorker.workspacePath(workspace.path)
        let mismatch = MicropodError.message(
            "HVF warm snapshot workspace none differs from the configured workspace \(String(reflecting: canonical)). "
                + "Use the captured workspace or take a new snapshot.")
        #expect(throws: mismatch) {
            _ = try worker.configuration(create: true, restoring: snapshotMetadata(workspace: nil))
        }
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("worker.json").path))
        let meta = snapshotMetadata(workspace: canonical)
        #expect(try worker.configuration(create: true, restoring: meta).worker == meta.workerID)
    }

    @Test("New managed restores require a fresh disk path including dangling symlinks")
    func managedSnapshotNeedsFreshDisk() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("mp-snap-" + UUID().uuidString.prefix(8))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path])
        try worker.prepareDirectory()
        defer { try? fm.removeItem(at: home) }
        #expect(try worker.freshHVFRestoreDisk() == worker.disk)
        try Data("existing".utf8).write(to: worker.disk)
        #expect(try worker.validatedDisk() == worker.disk)
        #expect(throws: MicropodError.self) { _ = try worker.freshHVFRestoreDisk() }
        #expect(try String(contentsOf: worker.disk, encoding: .utf8) == "existing")
        try fm.removeItem(at: worker.disk)
        try fm.createSymbolicLink(at: worker.disk, withDestinationURL: home.appendingPathComponent("missing"))
        #expect(throws: MicropodError.self) { _ = try worker.freshHVFRestoreDisk() }
    }

    @Test("Managed snapshots check READY, VM state, RAM length, disk length and metadata schema")
    func managedSnapshotCompletion() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("mp-snap-" + UUID().uuidString.prefix(8))
        defer { try? fm.removeItem(at: directory) }
        let meta = snapshotMetadata(workspace: nil, diskBytes: 8192)
        try meta.write(to: directory)
        let ready = directory.appendingPathComponent("READY")
        let ram = directory.appendingPathComponent("ram.bin")
        let vmstate = directory.appendingPathComponent("vmstate.bin")
        let disk = directory.appendingPathComponent("disk.ext4")
        #expect(throws: MicropodError.message("Incomplete HVF warm snapshot file at \(ready.path)")) {
            _ = try HVFManagedSnapshotMetadata.load(from: directory)
        }
        try Data("{}".utf8).write(to: ready)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }
        let receipt = Data(#"{"ram_total_bytes":1048576,"num_vcpus":4,"memory_mib":1}"#.utf8)
        try receipt.write(to: ready)
        try writeSizedFile(ram, bytes: 1048576)
        #expect(throws: MicropodError.message("Incomplete HVF warm snapshot file at \(vmstate.path)")) {
            _ = try HVFManagedSnapshotMetadata.load(from: directory)
        }
        // VM-state binary format validation belongs to micropod-vmm. This fixture exercises bundle checks.
        try writeSizedFile(vmstate, bytes: 16)
        #expect(throws: MicropodError.message("Incomplete HVF warm snapshot file at \(disk.path)")) {
            _ = try HVFManagedSnapshotMetadata.load(from: directory)
        }
        try writeSnapshotDisk(disk, bytes: 4096)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }
        try writeSnapshotDisk(disk, bytes: 8192)
        #expect(try HVFManagedSnapshotMetadata.load(from: directory) == meta)

        try writeSizedFile(ram, bytes: 1048575)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }
        try writeSizedFile(ram, bytes: 1048576)
        try Data(#"{"ram_total_bytes":1048576,"num_vcpus":2,"memory_mib":1}"#.utf8).write(to: ready)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }
        try receipt.write(to: ready)
        let metadata = directory.appendingPathComponent(HVFManagedSnapshotMetadata.filename)
        try JSONEncoder().encode(snapshotMetadata(schema: 2, workspace: nil)).write(to: metadata)
        #expect(throws: MicropodError.message("Unsupported HVF snapshot metadata schema 2")) {
            _ = try HVFManagedSnapshotMetadata.load(from: directory)
        }
        let legacy = snapshotMetadata(workspace: nil)
        try JSONEncoder().encode(legacy).write(to: metadata)
        #expect(try HVFManagedSnapshotMetadata.load(from: directory) == legacy)
        try writeSnapshotDisk(disk, bytes: 4096, blocks: 8)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }
        try writeSizedFile(disk, bytes: 8192)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }

        let blocks = UInt64(UInt32.max) << 32 | 4
        try writeSnapshotDisk(disk, bytes: 8192, blocks: blocks)
        #expect(try HVFManagedSnapshotMetadata.load(from: directory) == legacy)
        try writeSnapshotDisk(disk, bytes: 8192, blocks: blocks, feature64Bit: true)
        #expect(throws: MicropodError.self) { _ = try HVFManagedSnapshotMetadata.load(from: directory) }
    }

    @Test("Snapshot capture reserves one generation and preserves unrelated files")
    func managedSnapshotCaptureGeneration() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("mp-snap-" + UUID().uuidString.prefix(8))
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("other")
        let disk = directory.appendingPathComponent("disk.ext4")
        try Data("keep".utf8).write(to: unrelated)
        try Data("previous".utf8).write(to: disk)
        let meta = snapshotMetadata(workspace: nil)
        #expect(throws: MicropodError.self) { try meta.write(to: directory) }
        #expect(try String(contentsOf: disk, encoding: .utf8) == "previous")
        try fm.removeItem(at: disk)
        try meta.write(to: directory)
        #expect(throws: MicropodError.self) { try snapshotMetadata(workspace: nil).write(to: directory) }
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
    }

    private func snapshotMetadata(schema: Int = 1, workspace: String?, diskBytes: UInt64? = nil)
        -> HVFManagedSnapshotMetadata
    {
        HVFManagedSnapshotMetadata(
            schema: schema, workerID: UUID(), instanceID: UUID(), cpus: 4, memoryMiB: 1,
            publishedMTU: 9000, workspace: workspace, diskBytes: diskBytes)
    }

    private func writeSizedFile(_ url: URL, bytes: UInt64) throws {
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: bytes)
        try file.close()
    }

    private func writeSnapshotDisk(_ url: URL, bytes: UInt64, blocks: UInt64 = 4, feature64Bit: Bool = false) throws {
        try writeSizedFile(url, bytes: bytes)
        var superblock = Data(repeating: 0, count: 1024)
        func setField<Value: FixedWidthInteger>(_ value: Value, offset: Int) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                superblock.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
        }
        setField(UInt32(truncatingIfNeeded: blocks), offset: 0x04)
        setField(UInt16(0xef53), offset: 0x38)
        setField(UInt32(feature64Bit ? 0x80 : 0), offset: 0x60)
        setField(UInt32(blocks >> 32), offset: 0x150)
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: 1024)
        try file.write(contentsOf: superblock)
        try file.close()
    }

    @Test("The managed VMM receives its supervisor PID and one effective value per profile key")
    func managedLaunchPassesPIDAndProfile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("hvf-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: home) }

        let binary = home.appendingPathComponent("micropod-vmm")
        let initrd = home.appendingPathComponent("initrd")
        let script = """
            #!/bin/sh
            while [ "$#" -ne 0 ]; do
                if [ "$1" = "--cmdline" ]; then
                    printf '%s' "$2" >"$0.cmdline"
                    shift
                fi
                if [ "$1" = "--parent-pid" ]; then
                    [ "$2" = "$PPID" ]
                    exit $?
                fi
                shift
            done
            exit 2
            """
        try Data(script.utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data().write(to: initrd)

        let worker = CIWorker(environment: [
            "MICROPOD_CI_HOME": home.path,
            "MICROPOD_CI_ENGINE": "containerd",
            "MICROPOD_CI_HVF_BIN": binary.path,
            "MICROPOD_CI_HVF_INITRD": initrd.path,
            "MICROPOD_SANDBOX_KERNEL_ARGS":
                "loglevel=4 micropod.ci_sched=hrtick-125us micropod.ci_wakeup=next-buddy micropod.ci_cc=bbr note=\"two  spaces\"",
        ])
        let config = CIWorker.Configuration(
            schema: 1, image: CIWorker.Engine.containerd.image, worker: UUID(), cpus: .fixed(1),
            memoryMiB: 512, diskGiB: 1, workspace: nil, ext4MaxBatchUS: nil, kataTools: nil,
            kernel: home.appendingPathComponent("Image").path)
        let proc = try worker.launchHVFProcess(
            config: config, instanceID: UUID(), cpus: 1, diskURL: worker.disk, ociTools: home)
        proc.waitUntilExit()
        #expect(proc.terminationReason == .exit)
        #expect(proc.terminationStatus == 0)
        let cmdline = try String(contentsOf: binary.appendingPathExtension("cmdline"), encoding: .utf8)
        let options = cmdline.split(separator: " ")
        #expect(options.filter { $0.hasPrefix("micropod.ci_sched=") } == ["micropod.ci_sched=hrtick-125us"])
        #expect(options.filter { $0.hasPrefix("micropod.ci_wakeup=") } == ["micropod.ci_wakeup=next-buddy"])
        #expect(options.filter { $0.hasPrefix("micropod.ci_cc=") } == ["micropod.ci_cc=bbr"])
        #expect(options.filter { $0.hasPrefix("micropod.ci_sysctls=") } == ["micropod.ci_sysctls=perf"])
        #expect(options.contains("loglevel=4"))
        #expect(cmdline.contains("note=\"two  spaces\""))
        #expect(cmdline.hasSuffix("panic=-1"))

        let recorded = binary.appendingPathExtension("cmdline")
        try fm.removeItem(at: recorded)
        var invalidEnvironment = worker.resourceEnvironment
        invalidEnvironment["MICROPOD_CI_HOME"] = home.path
        invalidEnvironment["MICROPOD_SANDBOX_KERNEL_ARGS"] = "micropod.ci_sched=unknown"
        let invalid = CIWorker(environment: invalidEnvironment)
        #expect(throws: MicropodError.self) {
            _ = try invalid.launchHVFProcess(
                config: config, instanceID: UUID(), cpus: 1, diskURL: invalid.disk, ociTools: home)
        }
        #expect(!fm.fileExists(atPath: recorded.path))
    }

    @Test(
        "Managed HVF rejects HTTPS OTLP endpoints before launching the VMM", arguments: ["metrics", "traces", "legacy"])
    func managedLaunchRejectsHTTPS(_ exporter: String) throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("hvf-otlp-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: home) }
        let binary = home.appendingPathComponent("micropod-vmm")
        let initrd = home.appendingPathComponent("initrd")
        let configFile = home.appendingPathComponent("observability.yaml")
        try Data("#!/bin/sh\nprintf launched >\"$0.started\"\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data().write(to: initrd)

        let endpoint = "https://collector.example.test/v1/" + (exporter == "metrics" ? "metrics" : "traces")
        let yaml: String
        let setting: String
        switch exporter {
        case "metrics":
            yaml = "schema: 1\notlp:\n  enabled: true\n  endpoint: \(endpoint)\n"
            setting = "otlp.endpoint"
        case "traces":
            yaml = "schema: 1\ntracing:\n  enabled: true\n  endpoint: \(endpoint)\n"
            setting = "tracing.endpoint or otlp.traces_endpoint"
        default:
            yaml = "schema: 1\ntracing:\n  enabled: true\n  endpoint: ''\notlp:\n  traces_endpoint: \(endpoint)\n"
            setting = "tracing.endpoint or otlp.traces_endpoint"
        }
        try Data(yaml.utf8).write(to: configFile)
        let host = try ObservabilityConfig.parse(yaml: yaml)
        if exporter == "metrics" {
            #expect(host.otlp.endpoint == endpoint)
        } else {
            #expect(host.effectiveTracesEndpoint == endpoint)
            #expect(OTLPTracer.isEnabled(config: host, environment: [:]))
        }

        let worker = CIWorker(environment: [
            "MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "hvf",
            "MICROPOD_CI_HVF_BIN": binary.path, "MICROPOD_CI_HVF_INITRD": initrd.path,
            ObservabilityConfig.environmentKey: configFile.path,
        ])
        let config = CIWorker.Configuration(
            schema: 1, image: CIWorker.Engine.containerd.image, worker: UUID(), cpus: .fixed(1),
            memoryMiB: 512, diskGiB: 1, workspace: nil, ext4MaxBatchUS: nil, kataTools: nil,
            kernel: home.appendingPathComponent("Image").path)
        #expect(throws: MicropodError.message("The native HVF OTLP exporter requires an http:// URL for \(setting)")) {
            let process = try worker.launchHVFProcess(
                config: config, instanceID: UUID(), cpus: 1, diskURL: worker.disk, ociTools: home)
            process.waitUntilExit()
        }
        #expect(!fm.fileExists(atPath: binary.appendingPathExtension("started").path))
    }

    @Test(
        "Managed HVF rejects unsupported, repeated and reserved options",
        arguments: [
            "micropod.ci_sched=hrtick-800us", "micropod.ci_cc=reno", "micropod.ci_wakeup=",
            "micropod.ci_cc=bbr micropod.ci_cc=cubic", "mp.instance=replacement", "\"mp.workspace=/wrong\"",
            "mp.boot_realtime_ns=1", "micropod.ci_sysctls=perf", "panic=0", "--", "note=\"unclosed", "note=zero\0rest",
            "mp.worker=\u{301}changed", "note=\"contains micropod.ci_cc=bbr token\"",
            "note=\"contains mp.instance=replacement token\"", "note=\"contains mp.boot_realtime_ns token\"",
            "mp.workspace_b64=payload.", "note=\"contains mp.workspace_b64=payload. token\"",
            "idle_poll_us=-1", "idle_poll_us=2001", "idle_poll_us=fast", "idle_poll_us=0150",
            "idle_poll_us=100 idle_poll_us=200", "note=\"contains idle_poll_us=100 token\"",
        ])
    func rejectsInvalidKernelArguments(extra: String) {
        let worker = CIWorker(environment: [
            "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "hvf", "MICROPOD_SANDBOX_KERNEL_ARGS": extra,
        ])
        #expect(throws: MicropodError.self) { _ = try worker.selectedVMM() }
        let spec = launchSpec(extra: extra)
        #expect(throws: MicropodError.self) { _ = try spec.validatedArguments() }
        #expect(spec.arguments.isEmpty)
        #expect(spec.kernelCmdline.isEmpty)
    }

    @Test("Launch agents preserve the original kernel argument environment for each backend")
    func persistsKernelArgumentsForEachBackend() throws {
        let executable = URL(fileURLWithPath: "/opt/micropod/micropod")
        for vmm in [CIWorkerVMM.hvf, .vz, nil] {
            let extra =
                vmm == .hvf
                ? #"loglevel=4  micropod.ci_wakeup=next-buddy note="same  bytes""#
                : #"loglevel=4  panic=20 note="same  bytes""#
            var input = [
                "MICROPOD_CI_ENGINE": "containerd",
                "MICROPOD_SANDBOX_KERNEL_ARGS": extra,
            ]
            input["MICROPOD_CI_VMM"] = vmm?.rawValue
            let worker = CIWorker(environment: input)
            let data = try worker.launchAgent(executable: executable)
            let agent = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let environment = try #require(agent?["EnvironmentVariables"] as? [String: String])
            #expect(environment["MICROPOD_SANDBOX_KERNEL_ARGS"] == extra)
            #expect(try worker.selectedVMM() == (vmm ?? .vz))
        }
    }

    @Test("HVFWorkerLaunchSpec supports idle_poll_us overrides, snapshot flags, and .app Resources initrd discovery")
    func idlePollSnapshotsAndBundleDiscovery() throws {
        let custom = launchSpec(extra: "idle_poll_us=0")
        let options = custom.kernelCmdline.split(separator: " ")
        #expect(options.filter { $0.hasPrefix("idle_poll_us=") } == ["idle_poll_us=0"])

        let snap = HVFWorkerLaunchSpec(
            vmmBinary: URL(fileURLWithPath: "/opt/micropod/micropod-vmm"),
            kernel: URL(fileURLWithPath: "/opt/micropod/Image"),
            initrd: URL(fileURLWithPath: "/opt/micropod/mp-hvf-init.cpio"),
            disk: URL(fileURLWithPath: "/tmp/ci/worker.ext4"),
            ociTools: URL(fileURLWithPath: "/opt/micropod/oci-tools"),
            workspace: nil,
            dockerSocket: URL(fileURLWithPath: "/tmp/ci/docker.sock"),
            ociSocket: URL(fileURLWithPath: "/tmp/ci/oci.sock"),
            buildkitSocket: URL(fileURLWithPath: "/tmp/ci/buildkit.sock"),
            workerID: UUID(),
            instanceID: UUID(),
            cpus: 4,
            memoryMiB: 4096,
            extraKernelArgs: "idle_poll_us=250",
            restoreFrom: URL(fileURLWithPath: "/tmp/snap-in"),
            snapshotOut: URL(fileURLWithPath: "/tmp/snap-out")
        )
        let args = try snap.validatedArguments()
        #expect(args.contains("--restore-from"))
        #expect(args.contains("/tmp/snap-in"))
        #expect(args.contains("--snapshot-out"))
        #expect(args.contains("/tmp/snap-out"))
        #expect(snap.kernelCmdline.contains("idle_poll_us=250"))

        // Verify .app bundle layout: Contents/MacOS/micropod-vmm discovers Contents/Resources/mp-hvf-init.cpio
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mp-app-hvf-" + UUID().uuidString)
        let macos = root.appendingPathComponent("Contents/MacOS")
        let resources = root.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let vmmBin = macos.appendingPathComponent("micropod-vmm")
        let resInitrd = resources.appendingPathComponent("mp-hvf-init.cpio")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: vmmBin)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vmmBin.path)
        try Data("cpio".utf8).write(to: resInitrd)

        let worker = CIWorker(environment: [
            "MICROPOD_CI_ENGINE": "containerd",
            "MICROPOD_CI_VMM": "hvf",
            "MICROPOD_CI_HVF_BIN": vmmBin.path,
        ])
        let resolved = try worker.resolveHVFPaths()
        #expect(resolved.vmmBinary.path == vmmBin.path)
        #expect(resolved.initrd.path == resInitrd.path)

        // Verify .app bundle Resources/vmlinux-hvf auto-discovery.
        let resKernel = resources.appendingPathComponent("vmlinux-hvf")
        try Data("ARM64-IMAGE".utf8).write(to: resKernel)
        let resolvedKernel = try worker.resolveHVFKernel(configured: nil, vmmBinary: vmmBin)
        #expect(resolvedKernel.path == resKernel.path)

        // Verify YAML ObservabilityConfig parsing, validation, and live telemetry health evaluation
        let yaml = """
            schema: 1
            service_name: micropod-ci-test
            prometheus:
              enabled: true
              listen: 127.0.0.1:19464
              path: /metrics
            otlp:
              enabled: true
              endpoint: http://127.0.0.1:4318/v1/metrics
              export_interval_secs: 5
              resource_attributes:
                deployment.environment: gamma
            tracing:
              enabled: true
              endpoint: http://127.0.0.1:4318/v1/traces
              sample_rate: 1.0
              slow_op_threshold_ms: 8
            health:
              memory_warn_pct: 85
              vmm_timeout_ms: 1500
            """
        var obs = try ObservabilityConfig.parse(yaml: yaml)
        #expect(obs.serviceName == "micropod-ci-test")
        #expect(obs.prometheus.enabled && obs.prometheus.listen == "127.0.0.1:19464")
        #expect(obs.otlp.enabled && obs.otlp.endpoint == "http://127.0.0.1:4318/v1/metrics")
        #expect(obs.otlp.exportIntervalSecs == 5)
        #expect(obs.otlp.resourceAttributes["deployment.environment"] == "gamma")
        #expect(obs.tracing.enabled && obs.tracing.endpoint == "http://127.0.0.1:4318/v1/traces")
        #expect(obs.tracing.slowOpThresholdMs == 8)
        #expect(obs.health.memoryWarnPct == 85.0)
        let roundtripped = try ObservabilityConfig.parse(yaml: try obs.renderYAML())
        #expect(roundtripped == obs)

        // Verify dot-path YAML config setter + atomic save + reload
        try obs.set(key: "tracing.enabled", value: "false")
        #expect(!obs.tracing.enabled)
        #expect(!OTLPTracer.isEnabled(config: obs, environment: [:]))
        #expect(OTLPTracer.isEnabled(config: obs, environment: ["MICROPOD_TRACE": "1"]))
        try obs.set(key: "tracing.enabled", value: "true")
        try obs.set(key: "otlp.resource_attributes.team", value: "platform")
        let yamlFile = root.appendingPathComponent("observability.yaml")
        try obs.save(to: yamlFile)
        let loadedObs = try ObservabilityConfig.load(environment: [ObservabilityConfig.environmentKey: yamlFile.path])
        #expect(loadedObs == obs)
        #expect(loadedObs.otlp.resourceAttributes["team"] == "platform")
        #expect(throws: MicropodError.self) {
            var bad = obs
            try bad.set(key: "tracing.sample_rate", value: "2.5")
        }
        #expect(throws: MicropodError.self) {
            _ = try ObservabilityConfig.parse(yaml: "schema: 99\n")
        }
        #expect(throws: MicropodError.self) {
            _ = try ObservabilityConfig.parse(yaml: "schema: 1\notlp:\n  enabled: true\n  endpoint: ftp://bad\n")
        }

        // Verify launch spec forwards Prometheus / OTLP / tracing flags (zero metric files)
        let telSpec = HVFWorkerLaunchSpec(
            vmmBinary: vmmBin, kernel: resKernel, initrd: resInitrd,
            disk: root.appendingPathComponent("worker.ext4"), ociTools: root, workspace: nil,
            dockerSocket: root.appendingPathComponent("docker.sock"),
            ociSocket: root.appendingPathComponent("oci.sock"),
            buildkitSocket: root.appendingPathComponent("buildkit.sock"),
            workerID: UUID(), instanceID: UUID(), cpus: 4, memoryMiB: 4096,
            telemetrySocket: root.appendingPathComponent("telemetry.sock"),
            prometheusListen: obs.prometheus.listen,
            otlpEndpoint: obs.otlp.endpoint,
            otlpIntervalSecs: obs.otlp.exportIntervalSecs,
            tracingEnabled: obs.tracing.enabled,
            otlpTracesEndpoint: obs.effectiveTracesEndpoint,
            traceSlowMs: obs.tracing.slowOpThresholdMs,
            serviceName: obs.serviceName
        )
        let telArgs = try telSpec.validatedArguments()
        #expect(telArgs.contains("--telemetry-socket"))
        #expect(telArgs.contains("--prometheus-listen"))
        #expect(telArgs.contains("127.0.0.1:19464"))
        #expect(telArgs.contains("--otlp-endpoint"))
        #expect(telArgs.contains("http://127.0.0.1:4318/v1/metrics"))
        #expect(telArgs.contains("--otlp-interval-secs"))
        #expect(telArgs.contains("--trace"))
        #expect(telArgs.contains("--otlp-traces-endpoint"))
        #expect(telArgs.contains("http://127.0.0.1:4318/v1/traces"))
        #expect(telArgs.contains("--trace-slow-ms"))
        #expect(!telArgs.contains("--metrics-file"))

        // Verify live health evaluation (healthy / degraded on OOM & high memory / unhealthy on non-running VMM)
        let hv = CIWorker.HypervisorTelemetry(
            pid: 4242, state: "running", uptimeMs: 1234.5, ipaGranule: "16KiB", numVcpus: 4,
            vcpusOnline: 4, memoryMib: 4096, guestCtrlConnected: true, clockSyncCount: 2,
            lastClockSyncUnixSecs: 1_800_000_005, hostPhysFootprintMib: 128.5,
            hostPeakFootprintMib: 256.0, balloonReclaimedMib: 64.0, blkReadOps: 100, blkWriteOps: 50,
            blkReadBytes: 409_600, blkWriteBytes: 204_800, fsRequests: 500, fsBytesRead: 1_048_576,
            netTxPackets: 10, netTxBytes: 1000, netRxPackets: 12, netRxBytes: 2000,
            publishedBinds: 1, publishedConns: 3, mmioExits: 900, wfiExits: 400,
            tracingEnabled: true, sampledUnixSecs: 1_800_000_009)
        let okKernel = CIWorker.KernelHealthSummary(
            uptimeSeconds: 10, memoryBytes: 4_000_000_000, availableBytes: 3_000_000_000,
            memoryUsedPct: 25.0, oomKills: 0, cpuPressureSomeUsec: 0, memoryPressureSomeUsec: 0,
            ioPressureSomeUsec: 0)
        let evalOK = CIWorker.evaluateHealth(
            vmm: .hvf, hypervisor: hv, kernel: okKernel, nativeOCI: nil, thresholds: obs.health)
        #expect(evalOK.verdict == .healthy)
        #expect(evalOK.warnings.isEmpty)

        let oomKernel = CIWorker.KernelHealthSummary(
            uptimeSeconds: 10, memoryBytes: 4_000_000_000, availableBytes: 400_000_000,
            memoryUsedPct: 90.0, oomKills: 1, cpuPressureSomeUsec: 0, memoryPressureSomeUsec: 0,
            ioPressureSomeUsec: 0)
        let evalDeg = CIWorker.evaluateHealth(
            vmm: .hvf, hypervisor: hv, kernel: oomKernel, nativeOCI: nil, thresholds: obs.health)
        #expect(evalDeg.verdict == .degraded)
        #expect(evalDeg.warnings.count == 2)

        let evalUnreachable = CIWorker.evaluateHealth(
            vmm: .hvf, hypervisor: nil, kernel: okKernel, nativeOCI: nil, thresholds: obs.health)
        #expect(evalUnreachable.verdict == .degraded)
        #expect(evalUnreachable.warnings.contains { $0.contains("telemetry socket") })

        // Verify Docker API 5xx, Ryuk reaper errors, and Virtio-FS errors trigger degraded health warnings
        let errHV = CIWorker.HypervisorTelemetry(
            pid: 4242, state: "running", uptimeMs: 1234.5, ipaGranule: "16KiB", numVcpus: 4,
            vcpusOnline: 4, memoryMib: 4096, guestCtrlConnected: true, clockSyncCount: 2,
            lastClockSyncUnixSecs: 1_800_000_005, hostPhysFootprintMib: 128.5,
            hostPeakFootprintMib: 256.0, balloonReclaimedMib: 64.0, blkReadOps: 100, blkWriteOps: 50,
            blkReadBytes: 409_600, blkWriteBytes: 204_800, fsRequests: 500, fsBytesRead: 1_048_576,
            fsKeepCacheHits: 420, fsRoCacheHits: 410, fsRoCacheMisses: 10, fsNotifyEvents: 5,
            fsNotifyEpochResets: 1, fsErrors: 2,
            netTxPackets: 10, netTxBytes: 1000, netRxPackets: 12, netRxBytes: 2000,
            publishedBinds: 1, publishedConns: 3, mmioExits: 900, wfiExits: 400,
            tracingEnabled: true, sampledUnixSecs: 1_800_000_009)
        let errEngine = CIWorker.RuntimeEngineMetrics(
            containersCreated: 8, runsFinished: 8, runtimeFailures: 1, imageCacheHits: 8,
            preparedPodsUsed: 0, sharedCacheAttachments: 0, podMsTotal: 40, createMsTotal: 80,
            startMsTotal: 120, startParallelismLimit: 8, setupSlotsInUse: 0, setupWaitUsecTotal: 0,
            network: nil,
            api: CIWorker.DockerAPIMetrics(
                requestsTotal: 120, errors4xx: 3, errors5xx: 1, conflicts409: 2, notImplemented501: 0,
                slowRequestsTotal: 1, durationUsecTotal: 90_000, maxDurationUsec: 55_000, routes: nil),
            reaper: CIWorker.ReaperMetrics(
                activeSessions: 0, sessionsStarted: 1, sessionsClosed: 1, requestsTotal: 14,
                containersReaped: 8, networksReaped: 1, volumesReaped: 1, reapErrors: 1, reapDenied: 0,
                reapDurationUsecTotal: 45_000, maxReapDurationUsec: 12_000, lastReapUnixSecs: 1_800_000_008),
            recentIssues: nil)
        let evalIssues = CIWorker.evaluateHealth(
            vmm: .hvf, hypervisor: errHV, kernel: okKernel, nativeOCI: nil,
            runtimeEngine: errEngine, thresholds: obs.health)
        #expect(evalIssues.verdict == .degraded)
        #expect(evalIssues.warnings.contains { $0.contains("Virtio-FS reported 2") })
        #expect(evalIssues.warnings.contains { $0.contains("epoch reset") })
        #expect(evalIssues.warnings.contains { $0.contains("Docker API returned 1 server error") })
        #expect(evalIssues.warnings.contains { $0.contains("Ryuk session reaper recorded 1 cleanup error") })

        // Verify raw snake_case /micropod/metrics JSON decodes verbatim (including digit keys and route names)
        let rawEngineJSON = """
            {
              "containers_created": 9, "runs_finished": 8, "runtime_failures": 0,
              "image_cache_hits": 8, "prepared_pods_used": 0, "shared_cache_attachments": 0,
              "pod_ms_total": 12, "create_ms_total": 34, "start_ms_total": 56,
              "start_parallelism_limit": 8, "setup_slots_in_use": 0, "setup_wait_usec_total": 0,
              "api": {
                "requests_total": 42, "errors_4xx": 2, "errors_5xx": 0, "conflicts_409": 1,
                "not_implemented_501": 0, "slow_requests_total": 1, "duration_usec_total": 80000,
                "max_duration_usec": 55000,
                "routes": { "GET /_ping": { "count": 5, "errors": 0, "duration_usec_total": 500, "max_duration_usec": 200 } }
              },
              "reaper": {
                "active_sessions": 0, "sessions_started": 1, "sessions_closed": 1, "requests_total": 10,
                "containers_reaped": 8, "networks_reaped": 1, "volumes_reaped": 1,
                "reap_errors": 0, "reap_denied": 0, "reap_duration_usec_total": 12000,
                "max_reap_duration_usec": 4000, "last_reap_unix_secs": 1800000000
              },
              "recent_issues": [
                { "ts_unix_ns": 1800000000000000000, "kind": "conflict", "source": "docker_api",
                  "method": "POST", "route": "/containers/create", "status": 409, "duration_ms": 2.5,
                  "message": "Conflict" }
              ],
              "cache_attach": { "gomod": 4, "gobuild": 4, "npm": 2 },
              "cache_skip": { "store-failed": 1, "busy-exclusive": 2 },
              "cache_probes": 6,
              "cache_probe_failures": 1,
              "cache_probe_ms": 42,
              "cache_evictions": 3,
              "cache_evicted_units": 1,
              "cache_evicted_files": 120,
              "cache_evicted_bytes": 1048576,
              "cache_last_sweep_unix": 1800000010
            }
            """
        let decodedEngine = try CIWorker.makeRuntimeMetricsDecoder().decode(
            CIWorker.RuntimeEngineMetrics.self, from: Data(rawEngineJSON.utf8))
        #expect(decodedEngine.api?.errors4xx == 2)
        #expect(decodedEngine.api?.conflicts409 == 1)
        #expect(decodedEngine.api?.routes?["GET /_ping"]?.count == 5)
        #expect(decodedEngine.reaper?.containersReaped == 8)
        #expect(decodedEngine.recentIssues?.first?.kind == "conflict")
        #expect(decodedEngine.cacheAttach?["gomod"] == 4)
        #expect(decodedEngine.cacheSkip?["store-failed"] == 1)
        #expect(decodedEngine.cacheSkip?["busy-exclusive"] == 2)
        #expect(decodedEngine.cacheProbeFailures == 1)
        #expect(decodedEngine.cacheEvictions == 3)
        #expect(decodedEngine.cacheEvictedBytes == 1_048_576)
        // Verify cache probe/store failures & >=85% cache budget trigger health warnings
        let highCacheInv = HVFCacheInspection(
            root: "/var/lib/micropod/caches", mountPoint: "/micropod/cache", mountL0Point: "/micropod/cache-l0",
            policy: nil, policyDigest: "abc", scopes: [:], units: [],
            totals: HVFCacheTotals(
                totalBytes: 9_000_000_000, logicalBytes: 9_000_000_000, totalFiles: 100,
                scopeCount: 1, unitCount: 1, inUseCount: 0, l0Bytes: 4_000_000_000, l1Bytes: 5_000_000_000),
            budget: HVFCacheBudgetStatus(
                maxBytes: 10_000_000_000, minFreeBytes: 0, maxAgeDays: 0, utilizationPct: 90.0),
            evictions: nil)
        let evalCacheWarn = CIWorker.evaluateHealth(
            vmm: .hvf, hypervisor: hv, kernel: okKernel, nativeOCI: nil,
            runtimeEngine: decodedEngine, cacheInventory: highCacheInv, thresholds: obs.health)
        #expect(evalCacheWarn.verdict == .degraded)
        #expect(evalCacheWarn.warnings.contains { $0.contains("cache image probe failed") })
        #expect(evalCacheWarn.warnings.contains { $0.contains("store-failed") })
        #expect(evalCacheWarn.warnings.contains { $0.contains("cache budget utilization is high") })
        // Verify re-encoding preserves camelCase HealthReport schema
        let reencoded = String(decoding: try JSONEncoder().encode(decodedEngine), as: UTF8.self)
        #expect(reencoded.contains("\"containersCreated\":9"))
        #expect(reencoded.contains("\"errors4xx\":2"))

        // Verify HTTP/1.1 chunked transfer-encoding decoder (used by Go /micropod/traces)
        let chunked = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        let unchunked = try #require(CIWorker.decodeChunkedHTTPBody(chunked))
        #expect(String(decoding: unchunked, as: UTF8.self) == "hello world")
    }

    @Test("A cache disk that did not mount degrades health: shared caches are off for the boot")
    func cacheDiskUnavailableDegradesHealth() throws {
        let off = try JSONDecoder().decode(
            HVFCacheInspection.self,
            from: Data(
                """
                {"root":"/var/lib/micropod/caches","mountPoint":"/micropod/cache","policyDigest":"d","scopes":{},
                 "units":[],"cacheDisk":"unavailable",
                 "unavailable":"guest init found the cache disk missing or unmountable"}
                """.utf8))
        #expect(off.cacheDisk == HVFCacheDiskState(state: "unavailable", mounted: false))
        #expect(off.sharedCachesOffReason == "guest init found the cache disk missing or unmountable")
        let fromInventory = CIWorker.evaluateHealth(
            vmm: .vz, hypervisor: nil, kernel: nil, nativeOCI: nil, cacheInventory: off)
        #expect(fromInventory.verdict == .degraded)
        let expected =
            "Guest shared caches are off this boot (cache-disk-unavailable): "
            + "guest init found the cache disk missing or unmountable"
        #expect(fromInventory.warnings == [expected])

        // Without an inventory the engine's skip count says the same.
        let engine = try CIWorker.makeRuntimeMetricsDecoder().decode(
            CIWorker.RuntimeEngineMetrics.self,
            from: Data(
                """
                {"containers_created": 1, "runs_finished": 1, "runtime_failures": 0, "image_cache_hits": 0,
                 "prepared_pods_used": 0, "shared_cache_attachments": 0, "pod_ms_total": 0, "create_ms_total": 0,
                 "start_ms_total": 0, "start_parallelism_limit": 8, "setup_slots_in_use": 0,
                 "setup_wait_usec_total": 0, "cache_skip": {"cache-disk-unavailable": 3}}
                """.utf8))
        let fromSkips = CIWorker.evaluateHealth(
            vmm: .vz, hypervisor: nil, kernel: nil, nativeOCI: nil, runtimeEngine: engine)
        #expect(fromSkips.verdict == .degraded)
        #expect(fromSkips.warnings.contains { $0.contains("3 attachment(s) due to cache-disk-unavailable") })

        // A mounted cache disk, or none at all, is healthy.
        let mounted = try JSONDecoder().decode(
            HVFCacheInspection.self,
            from: Data(
                """
                {"root":"/var/lib/micropod/caches","mountPoint":"/micropod/cache","policyDigest":"d","scopes":{},
                 "units":[],"cacheDisk":"mounted"}
                """.utf8))
        #expect(mounted.sharedCachesOffReason == nil)
        let healthy = CIWorker.evaluateHealth(
            vmm: .vz, hypervisor: nil, kernel: nil, nativeOCI: nil, cacheInventory: mounted)
        #expect(healthy.verdict == .healthy)
        #expect(healthy.warnings.isEmpty)
    }
}
