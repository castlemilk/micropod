import Crypto
import Darwin
import Foundation
import MicropodCore

/// Immutable metadata stamped inside `<root>/versions/<id>/payload-manifest.json`.
public struct HVFPayloadManifest: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    public static let fileName = "payload-manifest.json"

    public var schema: Int
    public var version: String
    public var revision: String
    public var installedAt: Date
    public var digests: [String: String]

    public init(
        version: String, revision: String = "unknown", installedAt: Date = Date(), digests: [String: String] = [:]
    ) {
        schema = Self.currentSchema
        self.version = version
        self.revision = revision
        self.installedAt = installedAt
        self.digests = digests
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func load(from directory: URL) -> HVFPayloadManifest? {
        let file = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(HVFPayloadManifest.self, from: data)
    }

    public func save(to directory: URL) throws {
        try HVFFiles.writeAtomically(
            try Self.encoder.encode(self), to: directory.appendingPathComponent(Self.fileName))
    }
}

/// Where a rootless HVF payload update comes from.
public enum HVFPayloadSource: Sendable, Equatable {
    /// A `.app` bundle (`Contents/MacOS/micropod-vmm` + `Contents/Resources/...`)
    /// or a directory holding `micropod-vmm`, `vmlinux-hvf`/`Image`,
    /// `mp-hvf-init.cpio`, and `micropod-oci-tools`/`tools`.
    case directory(URL)
    case explicit(vmm: URL, kernel: URL, initrd: URL, tools: URL)
}

/// Snapshot of staged, previous, and currently running HVF payloads.
public struct HVFPayloadStatus: Codable, Sendable, Equatable {
    public var currentPath: String?
    public var previousPath: String?
    public var current: HVFPayloadManifest?
    public var previous: HVFPayloadManifest?
    public var runningPath: String?
    public var runningVersion: String?
    public var runningRevision: String?
    public var updatePending: Bool
    public var availableVersions: [String]
}

/// Outcome of activating a staged HVF payload.
public struct HVFActivationResult: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, Equatable {
        case noop
        case activated
        case deferred
        case rolledBack = "rolled_back"
    }

    public var action: Action
    public var fromVersion: String?
    public var toVersion: String?
    public var activeContainers: Int
    public var detail: String
}

/// Rootless atomic versioned payload store for the HVF microVM engine.
///
/// ```
/// <root>/versions/<version>-<shortrev>/
///   micropod-vmm
///   Image
///   mp-hvf-init.cpio
///   tools/
///   payload-manifest.json
/// <root>/current  -> versions/<version>-<shortrev>
/// <root>/previous -> versions/<prev-version>-<prev-rev>
/// ```
///
/// Staging NEVER mutates a running VMM's binaries or guest tools: it writes
/// a fresh immutable version directory, verifies SHA-256 digests and code
/// signature entitlements, and atomically flips `current`. Activation drains
/// or restarts the supervisor and automatically rolls back to `previous` if
/// the new payload fails boot or health verification.
public enum HVFPayloadStore {
    public struct ResolvedAssets: Sendable, Equatable {
        public var vmm: URL
        public var kernel: URL
        public var initrd: URL
        public var tools: URL
    }

    /// Resolves HVF asset paths from either a `.app` bundle or a flat directory.
    public static func resolveAssets(from source: HVFPayloadSource) throws -> ResolvedAssets {
        let fm = FileManager.default
        switch source {
        case .explicit(let vmm, let kernel, let initrd, let tools):
            return try validateResolved(
                ResolvedAssets(
                    vmm: canonicalURL(vmm), kernel: canonicalURL(kernel), initrd: canonicalURL(initrd),
                    tools: canonicalURL(tools)))
        case .directory(let rawDir):
            let dir = canonicalURL(rawDir)
            let isApp =
                dir.pathExtension == "app"
                || fm.fileExists(atPath: dir.appendingPathComponent("Contents/MacOS").path)
            let binDir = isApp ? dir.appendingPathComponent("Contents/MacOS") : dir
            let resDir = isApp ? dir.appendingPathComponent("Contents/Resources") : dir

            func firstExisting(_ candidates: [URL]) -> URL? {
                candidates.first { fm.fileExists(atPath: $0.path) }.map(canonicalURL)
            }
            guard let vmm = firstExisting([binDir.appendingPathComponent("micropod-vmm")]) else {
                throw MicropodError.message("invalidArgument: no micropod-vmm found in \(dir.path)")
            }
            guard
                let kernel = firstExisting([
                    resDir.appendingPathComponent("vmlinux-hvf"), resDir.appendingPathComponent("Image"),
                ])
            else {
                throw MicropodError.message("invalidArgument: no vmlinux-hvf or Image found in \(dir.path)")
            }
            guard let initrd = firstExisting([resDir.appendingPathComponent("mp-hvf-init.cpio")]) else {
                throw MicropodError.message("invalidArgument: no mp-hvf-init.cpio found in \(dir.path)")
            }
            guard
                let tools = firstExisting([
                    resDir.appendingPathComponent("micropod-oci-tools"), resDir.appendingPathComponent("tools"),
                ])
            else {
                throw MicropodError.message("invalidArgument: no micropod-oci-tools or tools/ found in \(dir.path)")
            }
            return try validateResolved(ResolvedAssets(vmm: vmm, kernel: kernel, initrd: initrd, tools: tools))
        }
    }

    private static func validateResolved(_ assets: ResolvedAssets) throws -> ResolvedAssets {
        let fm = FileManager.default
        for (name, url) in [
            ("micropod-vmm", assets.vmm), ("Image", assets.kernel), ("mp-hvf-init.cpio", assets.initrd),
        ] {
            guard HVFMachineLayout.isRegularFile(url) else {
                throw MicropodError.message("invalidArgument: \(name) at \(url.path) is not a regular file")
            }
        }
        guard fm.fileExists(atPath: assets.tools.appendingPathComponent("runner/start.sh").path) else {
            throw MicropodError.message(
                "invalidArgument: \(assets.tools.path) is not a valid guest tool bundle (missing runner/start.sh)")
        }
        return assets
    }

    /// Reads current, previous, and live running payload state without booting anything.
    public static func status(layout: HVFMachineLayout) -> HVFPayloadStatus {
        let fm = FileManager.default
        let currentTarget = resolveLinkTarget(layout.currentLink)
        let previousTarget = resolveLinkTarget(layout.previousLink)
        let currentManifest = currentTarget.flatMap(HVFPayloadManifest.load(from:))
        let previousManifest = previousTarget.flatMap(HVFPayloadManifest.load(from:))
        let alive = HVFFileLock.isHeld(layout.supervisorLock)
        let state = alive ? (try? HVFMachineState.load(from: layout.state)) : nil

        let runningPath = state?.loadedPayloadPath.map(HVFMachineLayout.canonicalPath)
        let currentCanonical = currentTarget.map { HVFMachineLayout.canonicalPath($0.path) }
        let updatePending: Bool
        if alive, let currentCanonical {
            if let runningPath {
                updatePending = runningPath != currentCanonical
            } else {
                // Supervisor started on legacy flat layout while a versioned payload is now staged.
                updatePending = HVFMachineLayout.canonicalPath(layout.root.path) != currentCanonical
            }
        } else {
            updatePending = false
        }

        let versions =
            ((try? fm.contentsOfDirectory(atPath: layout.versionsDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()

        return HVFPayloadStatus(
            currentPath: currentCanonical,
            previousPath: previousTarget.map { HVFMachineLayout.canonicalPath($0.path) },
            current: currentManifest,
            previous: previousManifest,
            runningPath: runningPath,
            runningVersion: state?.loadedPayloadVersion,
            runningRevision: state?.loadedPayloadRevision,
            updatePending: updatePending,
            availableVersions: versions)
    }

    /// Stages an immutable payload directory under `<root>/versions/<id>/` and
    /// atomically updates `<root>/current` (preserving the old target at `previous`).
    /// Safe to invoke while the HVF supervisor & VMM are actively running.
    @discardableResult
    public static func stage(
        from source: HVFPayloadSource,
        version: String,
        revision: String = "unknown",
        layout: HVFMachineLayout,
        verifySignature: Bool = true,
        progress: @Sendable (String) -> Void = { _ in }
    ) throws -> HVFPayloadManifest {
        try layout.validatePaths()
        let assets = try resolveAssets(from: source)
        if verifySignature {
            try HVFMachineInstaller.verifyHypervisorEntitlement(assets.vmm)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: layout.versionsDirectory, withIntermediateDirectories: true)

        let id = sanitizeVersionID(version: version, revision: revision)
        let stageDir = layout.versionsDirectory.appendingPathComponent(".stage-\(UUID().uuidString)")
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        var cleanupStage = true
        defer { if cleanupStage { try? fm.removeItem(at: stageDir) } }

        let dstVMM = stageDir.appendingPathComponent("micropod-vmm")
        let dstKernel = stageDir.appendingPathComponent("Image")
        let dstInitrd = stageDir.appendingPathComponent("mp-hvf-init.cpio")
        let dstTools = stageDir.appendingPathComponent("tools")

        progress("staging HVF payload \(id)…")
        try cloneOrCopy(assets.vmm, to: dstVMM)
        try cloneOrCopy(assets.kernel, to: dstKernel)
        try cloneOrCopy(assets.initrd, to: dstInitrd)
        try cloneOrCopy(assets.tools, to: dstTools)
        if verifySignature {
            try HVFMachineInstaller.verifyHypervisorEntitlement(dstVMM)
        }

        var digests: [String: String] = [
            "micropod-vmm": try sha256File(dstVMM),
            "Image": try sha256File(dstKernel),
            "mp-hvf-init.cpio": try sha256File(dstInitrd),
            "tools/runner/start.sh": try sha256File(dstTools.appendingPathComponent("runner/start.sh")),
        ]
        let jobBin = dstTools.appendingPathComponent("runner/bin/job")
        if HVFMachineLayout.isRegularFile(jobBin) {
            digests["tools/runner/bin/job"] = try sha256File(jobBin)
        }
        let manifest = HVFPayloadManifest(version: version, revision: revision, digests: digests)
        try manifest.save(to: stageDir)
        try verify(payloadDirectory: stageDir)

        var targetName = id
        var targetDir = layout.versionsDirectory.appendingPathComponent(targetName)
        if fm.fileExists(atPath: targetDir.path) {
            // Never overwrite an immutable directory in place (a running VMM may map it).
            let shortDigest = String((digests["micropod-vmm"] ?? UUID().uuidString).prefix(8))
            targetName = "\(id)-\(shortDigest)"
            targetDir = layout.versionsDirectory.appendingPathComponent(targetName)
            if fm.fileExists(atPath: targetDir.path) {
                targetName = "\(id)-\(UUID().uuidString.prefix(8).lowercased())"
                targetDir = layout.versionsDirectory.appendingPathComponent(targetName)
            }
        }
        guard rename(stageDir.path, targetDir.path) == 0 else {
            throw HVFFiles.posixError("commit payload \(targetDir.path)")
        }
        cleanupStage = false

        let oldCurrent = readRelativeLink(layout.currentLink)
        if let oldCurrent, oldCurrent != "versions/\(targetName)" {
            try atomicSymlink(destination: oldCurrent, at: layout.previousLink)
        }
        try atomicSymlink(destination: "versions/\(targetName)", at: layout.currentLink)
        progress("staged \(targetName) (current -> versions/\(targetName))")
        return manifest
    }

    /// Re-verifies every SHA-256 digest recorded in `payload-manifest.json`.
    public static func verify(payloadDirectory dir: URL) throws {
        guard let manifest = HVFPayloadManifest.load(from: dir) else {
            throw MicropodError.message(
                "failedPrecondition: missing or unreadable payload-manifest.json in \(dir.path)")
        }
        for (rel, expected) in manifest.digests.sorted(by: { $0.key < $1.key }) {
            let file = dir.appendingPathComponent(rel)
            guard HVFMachineLayout.isRegularFile(file) else {
                throw MicropodError.message("failedPrecondition: payload asset missing: \(file.path)")
            }
            let actual = try sha256File(file)
            guard actual == expected else {
                throw MicropodError.message(
                    "failedPrecondition: payload digest mismatch for \(rel) (want \(expected.prefix(12)), got \(actual.prefix(12)))"
                )
            }
        }
    }

    /// Activates the staged `current` payload on `layout`.
    /// - If the machine is stopped, verifies `current` and returns `.activated` (next start uses it).
    /// - If running with active containers and `!force`, waits up to `drainTimeout` for them to exit;
    ///   if still busy, returns `.deferred` so live workloads are never disrupted.
    /// - Stops, restarts on `current`, and verifies `healthProbe`; on failure automatically rolls back
    ///   `current` to `previous` and restarts on `previous`.
    public static func activate(
        layout: HVFMachineLayout,
        client: HVFMachineClient? = nil,
        force: Bool = false,
        drainTimeout: Duration = .zero,
        healthProbe: (@Sendable (HVFMachineClient) async -> Bool)? = nil,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> HVFActivationResult {
        let client = client ?? HVFMachineClient(layout: layout)
        let snap = status(layout: layout)
        guard let currentDir = resolveLinkTarget(layout.currentLink) else {
            throw MicropodError.message("failedPrecondition: no staged versioned payload under \(layout.root.path)")
        }
        try verify(payloadDirectory: currentDir)

        let running = HVFFileLock.isHeld(layout.supervisorLock)
        if !running {
            return HVFActivationResult(
                action: .activated,
                fromVersion: snap.previous?.version,
                toVersion: snap.current?.version,
                activeContainers: 0,
                detail:
                    "Machine is stopped; next start will boot \(snap.current?.version ?? currentDir.lastPathComponent)")
        }
        if !snap.updatePending {
            return HVFActivationResult(
                action: .noop,
                fromVersion: snap.runningVersion,
                toVersion: snap.current?.version,
                activeContainers: 0,
                detail: "Already running staged payload \(snap.current?.version ?? currentDir.lastPathComponent)")
        }

        if !force {
            var active = await runningContainerCount(client: client)
            if active > 0 && drainTimeout > .zero {
                progress("waiting up to \(drainTimeout) for \(active) running container(s) to finish…")
                let deadline = ContinuousClock.now + drainTimeout
                while active > 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(500))
                    active = await runningContainerCount(client: client)
                }
            }
            if active > 0 {
                return HVFActivationResult(
                    action: .deferred,
                    fromVersion: snap.runningVersion,
                    toVersion: snap.current?.version,
                    activeContainers: active,
                    detail:
                        "\(active) container(s) still running; keeping current VM alive (re-run when idle or pass --force)"
                )
            }
        }

        let probe = healthProbe ?? defaultHealthProbe
        progress("restarting HVF machine onto \(snap.current?.version ?? currentDir.lastPathComponent)…")
        do {
            try await client.stop()
            try await client.ensureRunning()
            guard await probe(client) else {
                throw MicropodError.message(
                    "health gate failed after switching to \(snap.current?.version ?? "new payload")")
            }
            return HVFActivationResult(
                action: .activated,
                fromVersion: snap.runningVersion,
                toVersion: snap.current?.version,
                activeContainers: 0,
                detail: "Activated \(snap.current?.version ?? currentDir.lastPathComponent) and verified health")
        } catch let activationError {
            guard let prevRel = readRelativeLink(layout.previousLink) else {
                throw activationError
            }
            progress("activation failed (\(activationError.localizedDescription)); rolling back to \(prevRel)…")
            try atomicSymlink(destination: prevRel, at: layout.currentLink)
            _ = try? await client.stop()
            try await client.ensureRunning()
            return HVFActivationResult(
                action: .rolledBack,
                fromVersion: snap.current?.version,
                toVersion: snap.previous?.version,
                activeContainers: 0,
                detail:
                    "Activation failed (\(activationError.localizedDescription)); rolled back to \(snap.previous?.version ?? prevRel)"
            )
        }
    }

    /// Explicitly rolls `current` back to `previous` and cycles the supervisor if running.
    public static func rollback(
        layout: HVFMachineLayout,
        client: HVFMachineClient? = nil,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> HVFActivationResult {
        guard let prevRel = readRelativeLink(layout.previousLink),
            let prevDir = resolveLinkTarget(layout.previousLink)
        else {
            throw MicropodError.message("failedPrecondition: no previous payload available for rollback")
        }
        try verify(payloadDirectory: prevDir)
        let oldCurrent = readRelativeLink(layout.currentLink)
        let prevManifest = HVFPayloadManifest.load(from: prevDir)
        let curManifest = resolveLinkTarget(layout.currentLink).flatMap(HVFPayloadManifest.load(from:))

        try atomicSymlink(destination: prevRel, at: layout.currentLink)
        if let oldCurrent, oldCurrent != prevRel {
            try atomicSymlink(destination: oldCurrent, at: layout.previousLink)
        }

        let client = client ?? HVFMachineClient(layout: layout)
        if HVFFileLock.isHeld(layout.supervisorLock) {
            progress(
                "restarting HVF machine on rolled-back payload \(prevManifest?.version ?? prevDir.lastPathComponent)…")
            try await client.stop()
            try await client.ensureRunning()
        }
        return HVFActivationResult(
            action: .rolledBack,
            fromVersion: curManifest?.version,
            toVersion: prevManifest?.version,
            activeContainers: 0,
            detail: "Rolled back current -> \(prevRel)")
    }

    /// Prunes old immutable payload directories while preserving `current`, `previous`,
    /// any currently running supervisor's payload, and the newest `keep` versions.
    @discardableResult
    public static func pruneVersions(layout: HVFMachineLayout, keep: Int = 2) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: layout.versionsDirectory.path) else { return [] }
        let snap = status(layout: layout)
        var protected: Set<String> = []
        for path in [snap.currentPath, snap.previousPath, snap.runningPath].compactMap({ $0 }) {
            protected.insert(HVFMachineLayout.canonicalPath(path))
        }
        let candidates =
            entries
            .filter { !$0.hasPrefix(".") }
            .map { layout.versionsDirectory.appendingPathComponent($0) }
            .sorted { a, b in
                let ma =
                    (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let mb =
                    (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return ma > mb
            }
        var kept = 0
        var removed: [String] = []
        for dir in candidates {
            let canon = HVFMachineLayout.canonicalPath(dir.path)
            if protected.contains(canon) || kept < max(keep, 1) {
                kept += 1
                continue
            }
            if (try? fm.removeItem(at: dir)) != nil {
                removed.append(dir.lastPathComponent)
            }
        }
        return removed
    }

    // MARK: Helpers

    static func defaultHealthProbe(_ client: HVFMachineClient) async -> Bool {
        guard await HVFMachineClient.ping(client.layout.dockerSocket, timeout: .seconds(5)) else { return false }
        guard let resp = try? await client.docker.request("GET", "/micropod/metrics", timeout: .seconds(5)),
            resp.status == 200
        else { return false }
        return true
    }

    static func runningContainerCount(client: HVFMachineClient) async -> Int {
        guard let resp = try? await client.docker.request("GET", "/containers/json", timeout: .seconds(3)),
            resp.status == 200,
            let list = (try? resp.json()) as? [[String: Any]]
        else { return 0 }
        return list.count
    }

    static func resolveLinkTarget(_ link: URL) -> URL? {
        guard let rel = readRelativeLink(link) else { return nil }
        let target =
            rel.hasPrefix("/")
            ? URL(fileURLWithPath: rel)
            : link.deletingLastPathComponent().appendingPathComponent(rel)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return target.standardizedFileURL
    }

    static func readRelativeLink(_ link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    static func atomicSymlink(destination: String, at link: URL) throws {
        let dir = link.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(link.lastPathComponent).\(getpid()).\(UUID().uuidString)")
        defer { unlink(tmp.path) }
        guard symlink(destination, tmp.path) == 0 else {
            throw HVFFiles.posixError("symlink \(tmp.path) -> \(destination)")
        }
        guard rename(tmp.path, link.path) == 0 else {
            throw HVFFiles.posixError("rename symlink \(link.path)")
        }
    }

    static func sanitizeVersionID(version: String, revision: String) -> String {
        let clean: (String) -> String = { raw in
            let filtered = raw.map {
                ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")) ? $0 : "-"
            }
            return String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let v = clean(version)
        let r = clean(String(revision.prefix(12)))
        if v.isEmpty { return "release-\(UUID().uuidString.prefix(8).lowercased())" }
        if r.isEmpty || r == "unknown" { return v }
        return "\(v)-\(r)"
    }

    static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func cloneOrCopy(_ source: URL, to destination: URL) throws {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
        if isDir.boolValue { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw HVFFiles.posixError("copy \(source.path) to \(destination.path)")
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        URL(fileURLWithPath: HVFMachineLayout.canonicalPath(url.path))
    }
}
