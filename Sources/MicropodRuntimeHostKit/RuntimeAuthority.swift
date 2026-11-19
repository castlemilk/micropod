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
        /// Unprotected because the legacy SMAppService job is not retired.
        public var legacyActive: Bool = false
        public static let ok = Protection(protected: true, reason: nil)
        public static func unprotected(_ reason: String) -> Protection { .init(protected: false, reason: reason) }
        static func legacy(_ reason: String) -> Protection {
            .init(protected: false, reason: reason, legacyActive: true)
        }
    }

    /// `RuntimeHost/protection.json` (root-owned, world-readable): the last
    /// protection check, which the version manifest reports as the
    /// `runtime-authority` component's state.
    public struct PublishedProtection: Codable, Sendable, Equatable {
        public let protected: Bool
        public let legacyActive: Bool
        public let reason: String?
        public let checkedAt: Date
        public init(_ protection: Protection, checkedAt: Date) {
            protected = protection.protected
            legacyActive = protection.legacyActive
            reason = protection.reason
            self.checkedAt = checkedAt
        }
    }

    /// The live check every start makes, and every update repeats: this
    /// process runs the root-only program, the plist and program are
    /// protected, the plist is exactly the definition this build expects,
    /// and launchd's live job runs that program from that plist.
    /// - Parameters:
    ///   - launchctlPrint: `launchctl print system/<label>` output, or nil.
    ///   - legacy: the legacy SMAppService job's state, or nil if unreadable.
    ///     It must be unloaded and persistently disabled.
    public static func protection(
        executable: URL, program: URL = IsolatedRuntimePolicy.authorityProgram,
        plist: URL = IsolatedRuntimePolicy.authorityPlist, owner: uid_t = 0, group: gid_t = 0, boundary: String = "/",
        launchctlPrint: () -> String?, legacy: () -> LegacyJob?
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
        // The legacy SMAppService job has no SpawnConstraint and runs a
        // program in /Applications: while it can load, a root path through
        // an admin-writable folder remains.
        guard let legacy = legacy() else { return .unprotected("the legacy helper job's state could not be read") }
        guard !legacy.loaded else { return .legacy("the legacy SMAppService helper job is still loaded") }
        guard legacy.disabled else { return .legacy("the legacy SMAppService helper job is not disabled") }
        return .ok
    }

    /// The legacy SMAppService job (`com.skunkworq.micropod.runtime.host`).
    public struct LegacyJob: Equatable, Sendable {
        public let loaded: Bool
        public let disabled: Bool
        public init(loaded: Bool, disabled: Bool) {
            self.loaded = loaded
            self.disabled = disabled
        }

        /// From `launchctl print system/<label>` (nil when not loaded) and
        /// `launchctl print-disabled system`.
        public init?(printed: String?, printDisabled: String?, label: String = IsolatedRuntimePolicy.serviceName) {
            guard let printDisabled else { return nil }
            loaded = printed.flatMap { LiveJob($0) } != nil
            disabled = printDisabled.split(separator: "\n").contains { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return text.hasPrefix("\"" + label + "\" =>")
                    && (text.hasSuffix("=> disabled") || text.hasSuffix("=> true"))
            }
        }
    }

    public static func legacyJob() -> LegacyJob? {
        let disabled = try? NativeRuntimeComponentEnvironment.run(
            "/bin/launchctl", ["print-disabled", "system"], timeout: 10)
        return LegacyJob(
            printed: launchctlPrint(label: IsolatedRuntimePolicy.serviceName),
            printDisabled: disabled.map { String(decoding: $0, as: UTF8.self) })
    }

    /// The top-level `path` and `program` lines of `launchctl print`.
    public struct LiveJob: Equatable, Sendable {
        public let path: String?
        public let program: String?
        /// `running`, `not running`, ...
        public let state: String?
        public let pid: Int32?
        public init?(_ output: String) {
            var path: String?
            var program: String?
            var state: String?
            var pid: Int32?
            for line in output.split(separator: "\n") {
                // Top-level properties are indented by exactly one tab.
                guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
                let trimmed = line.dropFirst()
                if trimmed.hasPrefix("path = ") { path = path ?? String(trimmed.dropFirst(7)) }
                if trimmed.hasPrefix("program = ") { program = program ?? String(trimmed.dropFirst(10)) }
                if trimmed.hasPrefix("state = ") { state = state ?? String(trimmed.dropFirst(8)) }
                if trimmed.hasPrefix("pid = ") { pid = pid ?? Int32(trimmed.dropFirst(6)) }
            }
            guard path != nil || program != nil else { return nil }
            self.path = path
            self.program = program
            self.state = state
            self.pid = pid
        }
    }

    /// What a helper records once its XPC and rig servers listen
    /// (`RuntimeHost/serving.json`, root-only). install-authority reads it to
    /// prove the authority serves: the record's process must be the one
    /// launchd runs for the authority job now, born when the record says.
    public struct Serving: Codable, Equatable, Sendable {
        public let pid: Int32
        public let birthSeconds: Int64
        public let birthMicroseconds: Int64
        public let serviceName: String
        public let version: String
        public let helperSHA256: String
        public init(
            pid: Int32, birthSeconds: Int64, birthMicroseconds: Int64, serviceName: String, version: String,
            helperSHA256: String
        ) {
            self.pid = pid
            self.birthSeconds = birthSeconds
            self.birthMicroseconds = birthMicroseconds
            self.serviceName = serviceName
            self.version = version
            self.helperSHA256 = helperSHA256
        }

        /// This record describes `job`'s live authority process, whose
        /// birth is `birth` (nil: it is gone).
        public func describes(_ job: LiveJob?, birth: RuntimeProcessBirth?) -> Bool {
            guard let job, job.state == "running", job.pid == pid, let birth, birth.pid == pid else { return false }
            return serviceName == IsolatedRuntimePolicy.authorityServiceName && birth.seconds == birthSeconds
                && birth.microseconds == birthMicroseconds
        }
    }

    public static var servingRecord: URL { IsolatedRuntimePolicy.root.appendingPathComponent("serving.json") }
    public static var publishedProtection: URL { IsolatedRuntimePolicy.root.appendingPathComponent("protection.json") }

    /// Called by the helper once it serves.
    public static func recordServing(serviceName: String, version: String, executable: URL) throws {
        guard let birth = try RuntimeProcessBirth.read(getpid()) else {
            throw MicropodError.message("This helper's process birth is unavailable")
        }
        try RuntimeDurableFile.write(
            Serving(
                pid: getpid(), birthSeconds: birth.seconds, birthMicroseconds: birth.microseconds,
                serviceName: serviceName, version: version,
                helperSHA256: ManagedRuntimeInstaller.sha256(executable)),
            to: servingRecord)
    }

    /// The authority job's live helper, if it serves now.
    public static func authorityServing() -> Serving? {
        guard let data = try? RuntimeDurableFile.read(servingRecord, maximumBytes: 4096, ownerUID: 0),
            let record = try? JSONDecoder().decode(Serving.self, from: data)
        else { return nil }
        let job = launchctlPrint().flatMap { LiveJob($0) }
        let birth = job?.pid.flatMap { try? RuntimeProcessBirth.read($0) } ?? nil
        return record.describes(job, birth: birth) ? record : nil
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
    /// yields once a protected authority plist exists: from then on only the
    /// authority may serve, and clients only call the authority's service
    /// (``IsolatedRuntimePolicy/clientServiceNames``). So at most one helper
    /// serves; the cases where none does are in docs/runtime-component-update.md
    /// ("When no helper serves"), and running install-authority again recovers
    /// each of them.
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
    /// The legacy SMAppService job's bundle in /Applications, if any: its
    /// helper digest, and whether it is a sealed root-owned copy.
    func legacyBundle() -> (helperSHA256: String, sealed: Bool)?
    /// Replaces that bundle with a sealed root-owned copy of the authority
    /// bundle, so the legacy job can only ever start a helper that yields.
    func neutralizeLegacy() throws
    func authorityPlistInstalled() -> Bool
    func writeAuthorityPlist() throws
    func authorityLoaded() -> Bool
    func bootstrapAuthority() throws
    /// The legacy job is unloaded, persistently disabled, and its bundle (if
    /// any) is a sealed copy marked system-immutable.
    func legacyRetired() -> Bool
    /// `launchctl bootout` and `launchctl disable` the legacy job, then
    /// `chflags -R schg` its sealed bundle.
    func retireLegacy() throws
    /// The helper SHA-256 of the authority's live, serving helper, or nil.
    /// `wait` polls for a helper that is starting (launchd throttles a
    /// respawn by up to `ThrottleInterval` seconds).
    func authorityServing(wait: Bool) -> String?
    /// `launchctl kickstart` the authority; `kill` restarts a live one.
    func startAuthority(kill: Bool) throws
    /// No runtime operation, fence or worker is in flight.
    func runtimeIdle() throws -> Bool
    func checkpoint(_ name: String) throws
}

extension RuntimeAuthorityInstallHost {
    public func checkpoint(_ name: String) throws {}
}

/// `install-authority`. Every step is decided by inspection, so a kill
/// anywhere is finished by running it again, and at most one helper serves
/// at any point. The order:
///
/// 1. stage the sealed authority bundle (the legacy job keeps serving);
/// 2. neutralize the legacy job: its bundle becomes a sealed copy of the new
///    helper, which yields once a protected authority plist exists;
/// 3. write the authority plist (after a reboot the authority serves and
///    the legacy job yields);
/// 4. bootstrap the authority (it waits on `host.lock` while the old helper
///    holds it);
/// 5. retire the legacy job: bootout (the old process ends and the authority
///    takes the lock), persistent disable, and `schg` on its bundle;
/// 6. start (or restart) the authority until its live helper is the target.
///
/// It finishes only when the legacy job is retired and the authority serves
/// the target build. Between steps 3 and 6 clients reach no helper (they no
/// longer call the legacy service); a kill there, a refused spawn, or a
/// release below the security floor leaves none serving until
/// install-authority runs again (docs/runtime-component-update.md).
public struct RuntimeAuthorityInstaller: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case stage, neutralize, plist, bootstrap, retireLegacy, start
    }
    public let host: any RuntimeAuthorityInstallHost
    public init(host: any RuntimeAuthorityInstallHost) { self.host = host }

    func needsNeutralizing(_ target: RuntimeComponentBundle) -> Bool {
        guard let legacy = host.legacyBundle() else { return false }
        return legacy.helperSHA256 != target.helperSHA256 || !legacy.sealed
    }

    /// The steps still to do, by inspection.
    public func pending(target: RuntimeComponentBundle) -> [Step] {
        var steps: [Step] = []
        if host.authorityIdentity() != target { steps.append(.stage) }
        if needsNeutralizing(target) { steps.append(.neutralize) }
        if !host.authorityPlistInstalled() { steps.append(.plist) }
        if !host.authorityLoaded() { steps.append(.bootstrap) }
        if !host.legacyRetired() { steps.append(.retireLegacy) }
        if host.authorityServing(wait: false) != target.helperSHA256 { steps.append(.start) }
        return steps
    }

    @discardableResult
    public func run(source: URL, manifest: RuntimeComponentManifest, target: RuntimeComponentBundle) throws
        -> [Step]
    {
        func requireIdle() throws {
            guard try host.runtimeIdle() else {
                throw MicropodError.message(
                    "Runtime maintenance is in flight; finish or recover it, then run install-authority again")
            }
        }
        var done: [Step] = []
        if host.authorityIdentity() != target {
            // Replacing the bundle of a live authority: it restarts below.
            if host.authorityLoaded() { try requireIdle() }
            guard try host.stageAuthority(from: source, manifest: manifest) == target else {
                throw MicropodError.message("The staged authority is not the verified release")
            }
            done.append(.stage)
            try host.checkpoint("staged")
        }
        if needsNeutralizing(target) {
            try requireIdle()
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
        if !host.legacyRetired() {
            try requireIdle()
            try host.retireLegacy()
            done.append(.retireLegacy)
            try host.checkpoint("retired")
        }
        guard host.legacyRetired() else {
            throw MicropodError.message(
                "The legacy helper job is still loaded or enabled; install-authority did not finish. Run it again")
        }
        // The authority started at bootstrap gives up while the legacy helper
        // holds the state lock and is respawned after the throttle; a live
        // authority running another build (or none) is restarted.
        let serving = host.authorityServing(wait: false)
        if serving != target.helperSHA256 {
            if serving != nil { try requireIdle() }
            try host.startAuthority(kill: serving != nil || done.contains(.stage))
            done.append(.start)
            try host.checkpoint("started")
        }
        guard host.authorityServing(wait: true) == target.helperSHA256 else {
            throw MicropodError.message(
                "The authority is installed but does not serve: see `sudo launchctl print system/"
                    + IsolatedRuntimePolicy.authorityLabel + "` (a refused spawn, or a release below the security "
                    + "floor) and run install-authority again with a good release")
        }
        return done
    }
}

/// The Mac: root-only paths, `/Library/LaunchDaemons` and launchctl.
public struct NativeRuntimeAuthorityInstallHost: RuntimeAuthorityInstallHost {
    public static let legacyBundle = RuntimeSetupInstallation.installedURL
    let environment: NativeRuntimeComponentEnvironment
    /// The install-authority CLI running this, for the VM gate's kill hook.
    let cli: URL?

    public init(cli: URL? = nil) {
        environment = NativeRuntimeComponentEnvironment(
            executable: IsolatedRuntimePolicy.authorityProgram, runningVersion: "")
        self.cli = cli
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

    public func legacyBundle() -> (helperSHA256: String, sealed: Bool)? {
        let bundle = Self.legacyBundle
        let helper = bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            let digest = try? ManagedRuntimeInstaller.sha256(helper)
        else { return nil }
        return (digest, Self.sealedIgnoringImmutable(bundle))
    }

    /// Sealed root-owned, except that `schg` (set by retirement) is allowed.
    static func sealedIgnoringImmutable(_ bundle: URL) -> Bool {
        (try? RuntimeSecureCopy.walk(bundle, limits: .init()) { path, info in
            guard info.st_uid == 0, info.st_gid == 0, info.st_mode & 0o7022 == 0,
                info.st_flags & ~UInt32(SF_IMMUTABLE) == 0
            else { throw MicropodError.message("\(path) is not sealed") }
        }) != nil
    }

    public func neutralizeLegacy() throws {
        let installed = Self.legacyBundle
        // A bundle retirement marked immutable is root's own sealed copy.
        try NativeRuntimeComponentEnvironment.run("/usr/bin/chflags", ["-R", "noschg", installed.path], timeout: 30)
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

    public func legacyRetired() -> Bool {
        guard let job = RuntimeAuthority.legacyJob(), !job.loaded, job.disabled else { return false }
        guard let legacy = legacyBundle() else { return true }
        var info = stat()
        return legacy.sealed && lstat(Self.legacyBundle.path, &info) == 0 && info.st_flags & UInt32(SF_IMMUTABLE) != 0
    }

    public func retireLegacy() throws {
        let service = "system/" + IsolatedRuntimePolicy.serviceName
        if RuntimeAuthority.launchctlPrint(label: IsolatedRuntimePolicy.serviceName) != nil {
            try NativeRuntimeComponentEnvironment.run("/bin/launchctl", ["bootout", service], timeout: 30)
        }
        try NativeRuntimeComponentEnvironment.run("/bin/launchctl", ["disable", service], timeout: 10)
        if legacyBundle()?.sealed == true {
            // Belt and braces: no rename, replacement or write of the
            // neutralized bundle, even by an admin-group process. Undo with
            // `sudo chflags -R noschg "/Applications/Micropod Runtime Setup.app"`.
            try NativeRuntimeComponentEnvironment.run(
                "/usr/bin/chflags", ["-R", "schg", Self.legacyBundle.path], timeout: 30)
        }
    }

    public func authorityServing(wait: Bool) -> String? {
        let deadline = Date().addingTimeInterval(wait ? 45 : 0)
        while true {
            if let serving = RuntimeAuthority.authorityServing() { return serving.helperSHA256 }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    public func startAuthority(kill: Bool) throws {
        try NativeRuntimeComponentEnvironment.run(
            "/bin/launchctl", ["kickstart"] + (kill ? ["-k"] : []) + ["system/" + IsolatedRuntimePolicy.authorityLabel],
            timeout: 30)
    }

    public func checkpoint(_ name: String) throws {
        if let cli { RuntimeGateHooks.killIfRequested(at: name, cli: cli) }
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
