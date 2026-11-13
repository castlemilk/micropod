import Darwin
import Foundation
import MicropodCore

public enum RootRuntimeStorage {
    public static var apple: URL { IsolatedRuntimePolicy.root.appendingPathComponent("apple") }
    public static var operation: URL { IsolatedRuntimePolicy.root.appendingPathComponent("operation.json") }
    public static var accountPlan: URL { IsolatedRuntimePolicy.root.appendingPathComponent("account-plan.json") }
    public static func worker(digest: String) throws -> URL {
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw MicropodError.message("Runtime worker identity is invalid")
        }
        return IsolatedRuntimePolicy.root.appendingPathComponent("tools/" + digest + "/MicropodRuntimeHost")
    }

    public static func prepareRoot() throws {
        guard geteuid() == 0 else { throw MicropodError.message("Runtime setup requires the approved macOS helper") }
        try ensureRootDirectory(IsolatedRuntimePolicy.root.deletingLastPathComponent())
        try ensureRootDirectory(IsolatedRuntimePolicy.root)
    }

    public static func ensureRootDirectory(_ url: URL) throws {
        var parent = url
        var missing: [URL] = []
        var info = stat()
        while lstat(parent.path, &info) != 0 {
            guard errno == ENOENT, parent.path != "/" else {
                throw MicropodError.message("The system runtime location is unavailable")
            }
            missing.append(parent)
            parent.deleteLastPathComponent()
        }
        try validateAncestors(parent)
        for directory in missing.reversed() {
            guard mkdir(directory.path, 0o755) == 0 || errno == EEXIST else {
                throw MicropodError.message("Could not create the protected runtime location")
            }
            try validateAncestors(directory)
            try RuntimeDurableFile.syncDirectory(directory.deletingLastPathComponent())
        }
        // launchd starts the authority with umask 077. mkdir's requested 0755
        // is therefore insufficient, and older setup candidates left these
        // public control/tool ancestors at 0700. Publish only the requested
        // protected tree; never change permissions on system ancestors.
        let boundary = IsolatedRuntimePolicy.root.deletingLastPathComponent()
        var directory = url
        while directory == boundary || directory.path.hasPrefix(boundary.path + "/") {
            try publishReadableDirectory(directory, ownerUID: 0)
            if directory == boundary { break }
            directory.deleteLastPathComponent()
        }
    }

    static func publishReadableDirectory(_ url: URL, ownerUID: uid_t) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("The protected runtime directory is unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == ownerUID,
            info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0,
            fchmod(fd, 0o755) == 0, fsync(fd) == 0
        else { throw MicropodError.message("Could not publish the protected runtime directory") }
    }

    public static func validateAncestors(_ url: URL) throws {
        var path = url
        while path.path != "/" {
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_mode & 0o022 == 0
            else { throw MicropodError.message("The system runtime location is not protected") }
            path.deleteLastPathComponent()
        }
    }

    public static func publish(_ identity: IsolatedRuntimeIdentity, receipt: ManagedRuntimeReceipt) throws {
        let fm = FileManager.default
        let target = apple.appendingPathComponent("versions/" + receipt.selection.directoryName)
        for directory in [apple, apple.appendingPathComponent("versions"), target] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        // Only the dedicated runtime home is owned by the service account.
        // The verified executable tree and control metadata remain root-owned.
        if fm.fileExists(atPath: IsolatedRuntimePolicy.home.path) {
            var info = stat()
            guard lstat(IsolatedRuntimePolicy.home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == identity.serviceUID, info.st_gid == identity.serviceGID, info.st_mode & 0o077 == 0
            else { throw MicropodError.message("The dedicated runtime home already exists with another owner") }
        } else {
            try fm.createDirectory(
                at: IsolatedRuntimePolicy.home, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            guard chown(IsolatedRuntimePolicy.home.path, identity.serviceUID, identity.serviceGID) == 0 else {
                throw MicropodError.message("Could not assign the dedicated runtime home")
            }
        }
        try RuntimeDurableFile.write(identity, to: IsolatedRuntimePolicy.identityURL)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: IsolatedRuntimePolicy.identityURL.path)
        let fd = open(IsolatedRuntimePolicy.identityURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("Could not publish runtime identity") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw MicropodError.message("Could not synchronize runtime identity") }
        try prepareAdmission(identity)
    }

    private static func prepareAdmission(_ identity: IsolatedRuntimeIdentity) throws {
        let root = IsolatedRuntimePolicy.admissionRoot
        let fm = FileManager.default
        try ensureRootDirectory(root)
        let pending = root.appendingPathComponent("pending")
        if !fm.fileExists(atPath: pending.path) {
            try fm.createDirectory(
                at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard chown(pending.path, identity.serviceUID, identity.serviceGID) == 0 else {
                throw MicropodError.message("Could not create private workload admission")
            }
        }
        var pendingInfo = stat()
        guard lstat(pending.path, &pendingInfo) == 0, pendingInfo.st_mode & S_IFMT == S_IFDIR,
            pendingInfo.st_uid == identity.serviceUID, pendingInfo.st_gid == identity.serviceGID,
            pendingInfo.st_mode & 0o077 == 0
        else { throw MicropodError.message("Private workload admission has another owner") }
        let lock = root.appendingPathComponent("gate.lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o660)
        guard fd >= 0 else { throw MicropodError.message("Could not create runtime admission lock") }
        defer { close(fd) }
        guard fchown(fd, 0, identity.serviceGID) == 0, fchmod(fd, 0o660) == 0, fsync(fd) == 0 else {
            throw MicropodError.message("Could not protect runtime admission lock")
        }
        try RuntimeDurableFile.write(true, to: root.appendingPathComponent("enrolled"))
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("enrolled").path)
        try RuntimeDurableFile.syncDirectory(root)
    }

    public static func installAPI(
        from source: URL, identity: IsolatedRuntimeIdentity,
        selection: ManagedRuntimeLocation.Selection
    ) throws {
        let identifier = IsolatedRuntimeAPIConfiguration.executableIdentifier
        try RuntimeCodeIdentity.verifyExecutable(source, identifier: identifier)
        let digest = try ManagedRuntimeInstaller.sha256(source)
        let sourceGuest = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "Resources/micropod-guest")
        let guestDigest =
            FileManager.default.fileExists(atPath: sourceGuest.path)
            ? try ManagedRuntimeInstaller.sha256(sourceGuest) : nil
        let configuration = IsolatedRuntimeAPIConfiguration(
            instance: identity.instance, selection: selection,
            executableSHA256: digest, guestSHA256: guestDigest)
        let destination = IsolatedRuntimePolicy.root.appendingPathComponent(
            "tools/" + configuration.toolDirectoryName + "/MicropodAPI")
        try ensureRootDirectory(destination.deletingLastPathComponent())
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            let temp = destination.deletingLastPathComponent().appendingPathComponent(".api-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temp) }
            try copyProtected(source, to: temp)
            try RuntimeCodeIdentity.verifyExecutable(temp, identifier: identifier)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            guard try ManagedRuntimeInstaller.sha256(temp) == digest, rename(temp.path, destination.path) == 0 else {
                throw MicropodError.message("Could not install the managed API")
            }
            try RuntimeDurableFile.syncDirectory(destination.deletingLastPathComponent())
        }
        guard try ManagedRuntimeInstaller.sha256(destination) == digest else {
            throw MicropodError.message("The managed API executable changed")
        }
        try RuntimeCodeIdentity.verifyExecutable(destination, identifier: identifier)
        let guest = try installGuest(from: source, destination: destination.deletingLastPathComponent())
        guard try guest.map({ try ManagedRuntimeInstaller.sha256($0) }) == guestDigest else {
            throw MicropodError.message("The sealed guest artifact changed during installation")
        }
        let gateway = IsolatedRuntimeAPIConfiguration.socketURL.deletingLastPathComponent()
        // Only socket creation is delegated to the private uid. The parent,
        // executable, configuration and session registry stay root-owned.
        if !fm.fileExists(atPath: gateway.path) {
            try ensureRootDirectory(gateway)
            guard chown(gateway.path, 0, identity.serviceGID) == 0, chmod(gateway.path, 0o770) == 0 else {
                throw MicropodError.message("Could not protect the managed API gateway")
            }
        }
        var info = stat()
        guard lstat(gateway.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
            info.st_gid == identity.serviceGID, [mode_t(0o770), mode_t(0o771)].contains(info.st_mode & 0o777)
        else {
            throw MicropodError.message("The managed API gateway has another owner")
        }
        // Desktop clients need traverse access to reach the authenticated
        // socket, but cannot list, create, replace or remove gateway entries.
        guard chmod(gateway.path, 0o771) == 0 else {
            throw MicropodError.message("Could not publish the managed API gateway")
        }
        let stagedConfiguration = IsolatedRuntimePolicy.root.appendingPathComponent("pending-api-configuration.json")
        try RuntimeDurableFile.write(configuration, to: stagedConfiguration)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedConfiguration.path)
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MICROPOD_ISOLATED_RUNTIME": "1",
            "CONTAINER_APP_ROOT": IsolatedRuntimePolicy.appRoot.path,
        ]
        if let guest { environment["MICROPOD_GUEST_TOOL"] = guest.path }
        let plist: [String: Any] = [
            "Label": IsolatedRuntimeAPIConfiguration.serviceLabel,
            "ProgramArguments": [destination.path],
            "EnvironmentVariables": environment,
            "LimitLoadToSessionType": ["Background"],
            "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background", "ThrottleInterval": 10, "Umask": 0o077,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // Atomic bytes are encoded as Data only by this private helper.
        let temp = IsolatedRuntimePolicy.root.appendingPathComponent(".api-agent-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw MicropodError.message("Could not prepare managed API service metadata")
        }
        let fd = open(temp.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MicropodError.message("Could not synchronize API service metadata") }
        defer { close(fd) }
        guard fsync(fd) == 0,
            rename(temp.path, IsolatedRuntimePolicy.root.appendingPathComponent("pending-runtime-api.plist").path) == 0
        else {
            throw MicropodError.message("Could not publish API service metadata")
        }
        try RuntimeDurableFile.syncDirectory(IsolatedRuntimePolicy.root)
        try ensureRootDirectory(IsolatedRuntimeAPIConfiguration.sessionsRoot)
    }

    public static func activateAPI(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection)
        throws
    {
        let staged = IsolatedRuntimePolicy.root.appendingPathComponent("pending-api-configuration.json")
        if !FileManager.default.fileExists(atPath: staged.path) {
            guard try IsolatedRuntimeAPIConfiguration.read(identity: identity).selection == selection else {
                throw MicropodError.message("The managed API selection is unconfirmed")
            }
            return
        }
        let configuration = try JSONDecoder().decode(
            IsolatedRuntimeAPIConfiguration.self,
            from: RuntimeDurableFile.read(staged, maximumBytes: 16384, ownerUID: 0))
        try configuration.validate(identity: identity)
        guard configuration.selection == selection else {
            throw MicropodError.message("The staged API belongs to another runtime selection")
        }
        let tool = IsolatedRuntimePolicy.root.appendingPathComponent(
            "tools/" + configuration.toolDirectoryName + "/MicropodAPI")
        guard try ManagedRuntimeInstaller.sha256(tool) == configuration.executableSHA256 else {
            throw MicropodError.message("The managed API executable changed")
        }
        try RuntimeCodeIdentity.verifyExecutable(tool, identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier)
        try RuntimeDurableFile.write(configuration, to: IsolatedRuntimeAPIConfiguration.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: IsolatedRuntimeAPIConfiguration.fileURL.path)
        let stagedAgent = IsolatedRuntimePolicy.root.appendingPathComponent("pending-runtime-api.plist")
        guard rename(stagedAgent.path, IsolatedRuntimeAPIConfiguration.agentURL.path) == 0 else {
            throw MicropodError.message("Could not activate the selected managed API")
        }
        try RuntimeDurableFile.remove(staged)
        try RuntimeDurableFile.syncDirectory(IsolatedRuntimePolicy.root)
    }

    /// Copies from an unprivileged app through descriptors. No symlink from
    /// the source can become a root-owned destination or a chmod/chown target.
    private static func copyProtected(_ source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw MicropodError.message("The signed runtime source is unavailable") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 1 << 30
        else {
            throw MicropodError.message("The runtime source is not a bounded regular file")
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw MicropodError.message("Could not stage the runtime tool") }
        defer { close(output) }
        var bytes = [UInt8](repeating: 0, count: 65536)
        var total: Int64 = 0
        while true {
            let count = Darwin.read(input, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw MicropodError.message("Could not read the runtime tool") }
            if count == 0 { break }
            total += Int64(count)
            guard total <= info.st_size else {
                throw MicropodError.message("The runtime tool grew during installation")
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < count {
                    let wrote = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), count - offset)
                    if wrote < 0, errno == EINTR { continue }
                    guard wrote > 0 else { throw MicropodError.message("Could not stage the runtime tool") }
                    offset += wrote
                }
            }
        }
        guard total == info.st_size, fsync(output) == 0 else {
            throw MicropodError.message("The runtime tool copy is incomplete")
        }
    }
    private static func installGuest(from api: URL, destination: URL) throws -> URL? {
        let bundle = api.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = bundle.appendingPathComponent("Contents/Resources/micropod-guest")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        func verifyBundle() throws {
            if (try? RuntimeCodeIdentity.verifyExecutable(bundle, identifier: "com.skunkworq.micropod")) != nil {
                return
            }
            try RuntimeCodeIdentity.verifyExecutable(bundle, identifier: IsolatedRuntimePolicy.setupIdentifier)
        }
        try verifyBundle()
        let digest = try ManagedRuntimeInstaller.sha256(source)
        let guest = destination.appendingPathComponent("micropod-guest")
        if FileManager.default.fileExists(atPath: guest.path) {
            guard try ManagedRuntimeInstaller.sha256(guest) == digest else {
                throw MicropodError.message("The installed guest helper changed")
            }
            return guest
        }
        let temp = destination.appendingPathComponent(".guest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try copyProtected(source, to: temp)
        let file = try FileHandle(forReadingFrom: temp)
        let magic = try file.read(upToCount: 4)
        try file.close()
        guard magic == Data([0x7f, 0x45, 0x4c, 0x46]), try ManagedRuntimeInstaller.sha256(temp) == digest else {
            throw MicropodError.message("The guest helper is not the sealed Linux artifact")
        }
        try verifyBundle()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        guard rename(temp.path, guest.path) == 0 else {
            throw MicropodError.message("Could not install the sealed guest helper")
        }
        try RuntimeDurableFile.syncDirectory(destination)
        return guest
    }

    public static func installWorker(from executable: URL) throws -> String {
        try RuntimeCodeIdentity.verifyExecutable(executable, identifier: IsolatedRuntimePolicy.helperIdentifier)
        let fm = FileManager.default
        let digest = try ManagedRuntimeInstaller.sha256(executable)
        let destination = try worker(digest: digest)
        let dir = destination.deletingLastPathComponent()
        try ensureRootDirectory(dir)
        if fm.fileExists(atPath: destination.path) {
            guard try ManagedRuntimeInstaller.sha256(destination) == digest else {
                throw MicropodError.message("The installed runtime worker changed")
            }
            try RuntimeCodeIdentity.verifyExecutable(destination, identifier: IsolatedRuntimePolicy.helperIdentifier)
            return digest
        }
        let temp = dir.appendingPathComponent(".worker-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        try copyProtected(executable, to: temp)
        try RuntimeCodeIdentity.verifyExecutable(temp, identifier: IsolatedRuntimePolicy.helperIdentifier)
        guard try ManagedRuntimeInstaller.sha256(temp) == digest else {
            throw MicropodError.message("The runtime worker changed during installation")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        guard rename(temp.path, destination.path) == 0 else {
            throw MicropodError.message("Could not install runtime worker")
        }
        try RuntimeDurableFile.syncDirectory(dir)
        return digest
    }
}
