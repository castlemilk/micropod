import CryptoKit
import Darwin
import Foundation
import MicropodCore

/// The root helper's launchd job. It is a classic LaunchDaemon whose plist
/// (`/Library/LaunchDaemons`) and program (a sealed copy under `RuntimeHost`)
/// only root can write: every ancestor directory is root-owned with no group
/// or other write, no ACL and no symbolic link. Nothing in `/Applications`,
/// which any admin-group process can rename and replace, is ever on the
/// root path. The SpawnConstraint is defence in depth on top of that.
///
/// See docs/runtime-component-update.md, "The authority".
public enum RuntimeAuthority {
    /// launchd's Developer ID validation category.
    public static let developerIDValidationCategory = 6

    public static func definition(program: URL = IsolatedRuntimePolicy.authorityProgram) -> [String: Any] {
        [
            "Label": IsolatedRuntimePolicy.authorityLabel,
            "Program": program.path,
            "MachServices": [IsolatedRuntimePolicy.authorityServiceName: true],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "ThrottleInterval": 10,
            "Umask": 0o077,
            "AssociatedBundleIdentifiers": [IsolatedRuntimePolicy.setupIdentifier, "com.skunkworq.micropod"],
            "SpawnConstraint": [
                "team-identifier": IsolatedRuntimePolicy.teamIdentifier,
                "signing-identifier": IsolatedRuntimePolicy.helperIdentifier,
                "validation-category": developerIDValidationCategory,
            ],
        ]
    }

    /// Canonical SHA-256 of a definition: sorted-key JSON of its content.
    public static func digest(_ definition: [String: Any]) throws -> String {
        let canonical = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// The definition this build installs and expects to run under.
    public static var definitionSHA256: String { (try? digest(definition())) ?? "" }

    // MARK: Protection

    /// Why `url` is not protected, or nil. Every ancestor up to `/` and the
    /// entry itself must be root-owned, without group or other write, without
    /// an ACL entry and not a symbolic link (lstat, never followed).
    /// `boundary` stops the walk after that directory (tests; production
    /// walks to `/`).
    public static func unprotectedReason(_ url: URL, owner: uid_t = 0, boundary: String = "/") -> String? {
        var path = url.standardizedFileURL.path
        while true {
            var info = stat()
            guard lstat(path, &info) == 0 else { return "\(path) is missing" }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { return "\(path) is not a directory or file" }
            guard info.st_uid == owner else { return "\(path) is not owned by root" }
            guard info.st_mode & 0o022 == 0 else { return "\(path) is writable by group or others" }
            if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 { return "\(path) carries an ACL" }
            }
            if path == "/" || path == boundary { return nil }
            path = (path as NSString).deletingLastPathComponent
            if path.isEmpty { path = "/" }
        }
    }

    public struct Protection: Codable, Sendable, Equatable {
        public let protected: Bool
        public let reason: String?
        public static let ok = Protection(protected: true, reason: nil)
        public static func unprotected(_ reason: String) -> Protection { .init(protected: false, reason: reason) }
    }

    /// The live check every start makes, and every update repeats: this
    /// process runs the root-only program, the plist and program are
    /// protected, the plist is exactly the definition this build expects,
    /// and launchd's live job runs that program from that plist.
    /// - Parameters:
    ///   - launchctlPrint: `launchctl print system/<label>` output, or nil.
    public static func protection(
        executable: URL, program: URL = IsolatedRuntimePolicy.authorityProgram,
        plist: URL = IsolatedRuntimePolicy.authorityPlist, owner: uid_t = 0, group: gid_t = 0, boundary: String = "/",
        launchctlPrint: () -> String?
    ) -> Protection {
        guard executable.resolvingSymlinksInPath().path == program.path else {
            return .unprotected("the helper runs from \(executable.path), not the root-only authority program")
        }
        for entry in [program, plist] {
            if let reason = unprotectedReason(entry, owner: owner, boundary: boundary) { return .unprotected(reason) }
        }
        do {
            try RuntimeSecureCopy.assertSealed(
                program.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
                owner: owner, group: group)
        } catch { return .unprotected(error.localizedDescription) }
        guard let bytes = try? RuntimeNonblockingFile.read(plist, limit: 65536),
            let loaded = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
            let installed = try? digest(loaded)
        else { return .unprotected("the authority plist is unreadable") }
        guard installed == (try? digest(definition(program: program))) else {
            return .unprotected("the authority plist is not the definition this helper expects")
        }
        guard let printed = launchctlPrint(), let job = LiveJob(printed) else {
            return .unprotected("launchd's live authority job could not be read")
        }
        guard job.program == program.path, job.path == plist.path else {
            return .unprotected("launchd runs \(job.program ?? "?") from \(job.path ?? "?"), not the authority")
        }
        return .ok
    }

    /// The top-level `path` and `program` lines of `launchctl print`.
    public struct LiveJob: Equatable, Sendable {
        public let path: String?
        public let program: String?
        public init?(_ output: String) {
            var path: String?
            var program: String?
            for line in output.split(separator: "\n") {
                // Top-level properties are indented by exactly one tab.
                guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
                let trimmed = line.dropFirst()
                if trimmed.hasPrefix("path = ") { path = path ?? String(trimmed.dropFirst(7)) }
                if trimmed.hasPrefix("program = ") { program = program ?? String(trimmed.dropFirst(10)) }
            }
            guard path != nil || program != nil else { return nil }
            self.path = path
            self.program = program
        }
    }

    /// `launchctl print system/<label>` (read-only).
    public static func launchctlPrint(label: String = IsolatedRuntimePolicy.authorityLabel) -> String? {
        guard
            let data = try? NativeRuntimeComponentEnvironment.run(
                "/bin/launchctl", ["print", "system/" + label], timeout: 10)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A helper started by the legacy SMAppService job (from `/Applications`)
    /// yields to an installed authority: it exits at once, so exactly one
    /// helper serves. The authority plist must itself be protected and exact.
    public static func legacyJobShouldYield(
        plist: URL = IsolatedRuntimePolicy.authorityPlist, owner: uid_t = 0, boundary: String = "/"
    ) -> Bool {
        guard unprotectedReason(plist, owner: owner, boundary: boundary) == nil,
            let bytes = try? RuntimeNonblockingFile.read(plist, limit: 65536),
            let loaded = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        else { return false }
        return loaded["Label"] as? String == IsolatedRuntimePolicy.authorityLabel
    }
}

// MARK: - Installation and migration

/// What installing the authority changes, one idempotent step each. Tests
/// replace launchd and the file system with a model.
public protocol RuntimeAuthorityInstallHost: Sendable {
    /// The sealed authority bundle installed now, if any.
    func authorityIdentity() -> RuntimeComponentBundle?
    /// Seals, verifies and installs `source` as the authority bundle (the
    /// previous one is kept). Returns what it installed.
    func stageAuthority(from source: URL, manifest: RuntimeComponentManifest) throws -> RuntimeComponentBundle
    /// The setup app the legacy SMAppService job runs, if one is installed:
    /// its helper executable's digest.
    func legacyBundleHelper() -> String?
    /// Replaces that setup app with a sealed copy of the authority bundle, so
    /// the legacy job can only ever start a helper that yields.
    func neutralizeLegacy() throws
    func authorityPlistInstalled() -> Bool
    func writeAuthorityPlist() throws
    func authorityLoaded() -> Bool
    func bootstrapAuthority() throws
    /// A legacy-job process still running pre-authority code.
    func legacyRunsOldCode() -> Bool
    func stopLegacy() throws
    /// No runtime operation, fence or worker is in flight.
    func runtimeIdle() throws -> Bool
    func checkpoint(_ name: String) throws
}

extension RuntimeAuthorityInstallHost {
    public func checkpoint(_ name: String) throws {}
}

/// `sudo micropod runtime install-authority`. Every step is decided by
/// inspection, so a kill anywhere is finished by running it again, and the
/// order keeps exactly one helper able to serve at every point:
///
/// 1. stage the sealed authority bundle (the legacy job keeps serving);
/// 2. neutralize the legacy job: its bundle becomes the new helper, which
///    serves while no authority is installed and yields once one is;
/// 3. write the authority plist (at boot the authority serves and the legacy
///    job yields);
/// 4. bootstrap the authority (it waits on `host.lock` while the old helper
///    still holds it);
/// 5. stop the legacy job's old process; it restarts as the new helper and
///    yields, and the authority takes the lock.
public struct RuntimeAuthorityInstaller: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case stage, neutralize, plist, bootstrap, stopLegacy
    }
    public let host: any RuntimeAuthorityInstallHost
    public init(host: any RuntimeAuthorityInstallHost) { self.host = host }

    /// The steps still to do, by inspection.
    public func pending(target: RuntimeComponentBundle) -> [Step] {
        var steps: [Step] = []
        if host.authorityIdentity() != target { steps.append(.stage) }
        if let legacy = host.legacyBundleHelper(), legacy != target.helperSHA256 { steps.append(.neutralize) }
        if !host.authorityPlistInstalled() { steps.append(.plist) }
        if !host.authorityLoaded() { steps.append(.bootstrap) }
        if host.legacyRunsOldCode() { steps.append(.stopLegacy) }
        return steps
    }

    @discardableResult
    public func run(source: URL, manifest: RuntimeComponentManifest, target: RuntimeComponentBundle) throws
        -> [Step]
    {
        var done: [Step] = []
        if host.authorityIdentity() != target {
            guard try host.stageAuthority(from: source, manifest: manifest) == target else {
                throw MicropodError.message("The staged authority is not the verified release")
            }
            done.append(.stage)
            try host.checkpoint("staged")
        }
        if let legacy = host.legacyBundleHelper(), legacy != target.helperSHA256 {
            guard try host.runtimeIdle() else {
                throw MicropodError.message(
                    "Runtime maintenance is in flight; finish or recover it, then run install-authority again")
            }
            try host.neutralizeLegacy()
            done.append(.neutralize)
            try host.checkpoint("neutralized")
        }
        if !host.authorityPlistInstalled() {
            try host.writeAuthorityPlist()
            done.append(.plist)
            try host.checkpoint("plistWritten")
        }
        if !host.authorityLoaded() {
            try host.bootstrapAuthority()
            done.append(.bootstrap)
            try host.checkpoint("bootstrapped")
        }
        if host.legacyRunsOldCode() {
            guard try host.runtimeIdle() else {
                throw MicropodError.message(
                    "Runtime maintenance is in flight; finish or recover it, then run install-authority again")
            }
            try host.stopLegacy()
            done.append(.stopLegacy)
        }
        return done
    }
}

/// The Mac: root-only paths, `/Library/LaunchDaemons` and launchctl.
public struct NativeRuntimeAuthorityInstallHost: RuntimeAuthorityInstallHost {
    public static let legacyBundle = RuntimeSetupInstallation.installedURL
    let environment: NativeRuntimeComponentEnvironment

    public init() {
        environment = NativeRuntimeComponentEnvironment(
            executable: IsolatedRuntimePolicy.authorityProgram, runningVersion: "")
    }

    public func authorityIdentity() -> RuntimeComponentBundle? {
        let bundle = IsolatedRuntimePolicy.authorityBundle
        guard (try? RuntimeSecureCopy.assertSealed(bundle, owner: 0, group: 0)) != nil else { return nil }
        return try? environment.inspect(bundle)
    }

    public func stageAuthority(from source: URL, manifest: RuntimeComponentManifest) throws -> RuntimeComponentBundle {
        try RootRuntimeStorage.prepareRoot()
        let authority = IsolatedRuntimePolicy.authorityBundle.deletingLastPathComponent().deletingLastPathComponent()
        try RootRuntimeStorage.ensureRootDirectory(authority)
        let operation = UUID()
        let next = authority.appendingPathComponent(
            "next-" + operation.uuidString + "/" + RuntimeComponentUpdater.bundleName)
        defer { try? RuntimeSecureCopy.remove(next.deletingLastPathComponent()) }
        try RuntimeSecureCopy.copy(source, to: next)
        try environment.verifyCode(next, notarized: true)
        let target = try environment.inspect(next)
        guard target.cdhash == manifest.setup.cdhash, target.helperSHA256 == manifest.helper.sha256,
            target.apiSHA256 == manifest.api.sha256, target.guestSHA256 == manifest.guestSHA256,
            target.version == manifest.version, target.revision == manifest.sourceRevision
        else { throw MicropodError.message("The setup app does not match its signed manifest") }
        let probe = try environment.probe(next)
        guard probe.version == target.version, probe.authorityDefinitionSHA256 == RuntimeAuthority.definitionSHA256
        else {
            throw MicropodError.message(
                "The release's helper expects another authority definition than this installer writes")
        }
        let current = IsolatedRuntimePolicy.authorityBundle
        try FileManager.default.createDirectory(
            at: current.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        if FileManager.default.fileExists(atPath: current.path) {
            try environment.swap(next, current)
            let previous = IsolatedRuntimePolicy.root.appendingPathComponent(
                "components/authority-" + operation.uuidString + "/previous/" + RuntimeComponentUpdater.bundleName)
            try FileManager.default.createDirectory(
                at: previous.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard rename(next.path, previous.path) == 0 else {
                throw MicropodError.message("Could not retain the previous authority (\(errno))")
            }
        } else {
            guard rename(next.path, current.path) == 0 else {
                throw MicropodError.message("Could not install the authority (\(errno))")
            }
        }
        try RuntimeDurableFile.syncDirectory(current.deletingLastPathComponent())
        return target
    }

    public func legacyBundleHelper() -> String? {
        let helper = Self.legacyBundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? ManagedRuntimeInstaller.sha256(helper)
    }

    public func neutralizeLegacy() throws {
        let installed = Self.legacyBundle
        let staging = installed.deletingLastPathComponent().appendingPathComponent(
            ".micropod-runtime-setup-" + UUID().uuidString + ".app")
        defer { try? RuntimeSecureCopy.remove(staging) }
        try RuntimeSecureCopy.copy(IsolatedRuntimePolicy.authorityBundle, to: staging)
        try environment.swap(staging, installed)
        // The displaced legacy bundle is moved into root's directory unread.
        let kept = IsolatedRuntimePolicy.root.appendingPathComponent(
            "components/legacy-" + UUID().uuidString + "/" + RuntimeComponentUpdater.bundleName)
        try FileManager.default.createDirectory(
            at: kept.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard rename(staging.path, kept.path) == 0 else {
            throw MicropodError.message("Could not move the legacy setup app aside (\(errno))")
        }
    }

    public func authorityPlistInstalled() -> Bool {
        let plist = IsolatedRuntimePolicy.authorityPlist
        guard RuntimeAuthority.unprotectedReason(plist) == nil,
            let bytes = try? RuntimeNonblockingFile.read(plist, limit: 65536),
            let loaded = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
        else { return false }
        return (try? RuntimeAuthority.digest(loaded)) == RuntimeAuthority.definitionSHA256
    }

    public func writeAuthorityPlist() throws {
        let plist = IsolatedRuntimePolicy.authorityPlist
        if let reason = RuntimeAuthority.unprotectedReason(plist.deletingLastPathComponent()) {
            throw MicropodError.message("/Library/LaunchDaemons is not protected: \(reason)")
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: RuntimeAuthority.definition(), format: .xml, options: 0)
        let temp = plist.deletingLastPathComponent().appendingPathComponent(".micropod-authority-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw MicropodError.message("Could not write the authority plist (\(errno))") }
        defer { close(fd) }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count, fchown(fd, 0, 0) == 0, fchmod(fd, 0o644) == 0, fsync(fd) == 0,
            rename(temp.path, plist.path) == 0
        else { throw MicropodError.message("Could not install the authority plist (\(errno))") }
        try RuntimeDurableFile.syncDirectory(plist.deletingLastPathComponent())
    }

    public func authorityLoaded() -> Bool { RuntimeAuthority.launchctlPrint() != nil }

    public func bootstrapAuthority() throws {
        try NativeRuntimeComponentEnvironment.run(
            "/bin/launchctl", ["bootstrap", "system", IsolatedRuntimePolicy.authorityPlist.path], timeout: 30)
    }

    public func legacyRunsOldCode() -> Bool {
        guard let output = RuntimeAuthority.launchctlPrint(label: IsolatedRuntimePolicy.serviceName),
            output.contains("state = running"),
            let pid = output.split(separator: "\n").first(where: { $0.hasPrefix("\tpid = ") })
                .flatMap({ Int32($0.dropFirst(7)) })
        else { return false }
        return !RuntimeCodeIdentity.verifyProcess(pid, identifier: IsolatedRuntimePolicy.helperIdentifier)
    }

    public func stopLegacy() throws {
        try NativeRuntimeComponentEnvironment.run(
            "/bin/launchctl", ["kill", "SIGTERM", "system/" + IsolatedRuntimePolicy.serviceName], timeout: 10)
    }

    public func runtimeIdle() throws -> Bool {
        guard FileManager.default.fileExists(atPath: RootRuntimeStorage.operation.path) else { return true }
        let data = try RuntimeDurableFile.read(RootRuntimeStorage.operation, maximumBytes: 65536, ownerUID: 0)
        let status = try JSONDecoder().decode(IsolatedRuntimeStatus.self, from: data)
        let fenced = FileManager.default.fileExists(
            atPath: IsolatedRuntimePolicy.admissionRoot.appendingPathComponent("fence.json").path)
        let exited = try status.workerBirth?.hasExited() ?? true
        return status.isTerminal && status.phase != "recoveryRequired" && !fenced && status.rigAttempted != true
            && status.runtimeRigAttempted != true && exited
    }
}
