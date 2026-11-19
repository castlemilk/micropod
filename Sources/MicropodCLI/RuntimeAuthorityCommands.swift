import Darwin
import Foundation
import MachO
import MicropodCore
import MicropodRuntimeHostKit

/// `sudo micropod runtime install-authority`: the one administrator step.
/// It installs the root helper as a classic LaunchDaemon whose plist and
/// program only root can write, and migrates an existing SMAppService
/// install without ever leaving zero or two helpers able to serve
/// (``RuntimeAuthorityInstaller``). See docs/runtime-component-update.md.
///
/// Its trust anchor is the binary the administrator runs under sudo: the
/// release's own CLI, copied by root into a root-only directory and checked
/// there (``instructions``). Running as root, it refuses unless its own
/// executable is Micropod's Developer ID CLI on a path only root can change
/// (root-owned to `/`, no group or other write, no ACL, no symbolic link),
/// prints exactly what it installs, and asks to confirm.
enum RuntimeAuthorityCommands {
    static let usage = """
        usage: sudo /var/root/micropod-install/<version>/micropod runtime install-authority \
                 [--app <Micropod.app>] [--confirm <CDHash prefix>]
        """

    static func run(_ args: [String]) async throws {
        let parsed = try parseArgs(
            args, boolFlags: [], valueFlags: ["--app", "--confirm"], commandName: "install-authority")
        guard !parsed.has("--help") else {
            print(usage)
            return
        }
        guard geteuid() == 0 else {
            print(instructions)
            throw MicropodError.message("install-authority must run as root (sudo); nothing was changed")
        }
        let executable = try selfExecutable()
        if let problem = launchPathProblem(executable) {
            throw MicropodError.message(
                "Refusing to run as root from a path another account can change: \(problem). Copy the CLI into a "
                    + "root-only directory and run it from there:\n" + instructions)
        }
        do {
            try RuntimeCodeIdentity.verifyExecutable(executable, identifier: "com.skunkworq.micropod.cli")
        } catch {
            throw MicropodError.message(
                "Refusing to run as root: \(executable.path) is not Micropod's Developer ID-signed CLI")
        }

        let app = URL(fileURLWithPath: parsed.value("--app") ?? "/Applications/Micropod.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let manifest = try RuntimeComponentManifest.verified(
            RuntimeNonblockingFile.read(
                resources.appendingPathComponent(RuntimeComponentManifest.fileName),
                limit: RuntimeComponentManifest.maximumBytes),
            signature: RuntimeNonblockingFile.read(
                resources.appendingPathComponent(RuntimeComponentManifest.signatureFileName), limit: 1024))
        guard manifest.authorityDefinitionSHA256 == RuntimeAuthority.definitionSHA256 else {
            throw MicropodError.message(
                "This CLI writes another LaunchDaemon definition than Micropod \(manifest.version) expects; run "
                    + "that release's own CLI")
        }

        // A sealed root-only copy is inspected, shown and installed: nothing
        // is read twice from the user-writable app.
        try RootRuntimeStorage.prepareRoot()
        let staging = IsolatedRuntimePolicy.root.appendingPathComponent(
            "components/install-" + UUID().uuidString + "/" + RuntimeComponentUpdater.bundleName)
        defer { try? RuntimeSecureCopy.remove(staging.deletingLastPathComponent()) }
        try RuntimeSecureCopy.copy(
            app.appendingPathComponent("Contents/Helpers/" + RuntimeComponentUpdater.bundleName), to: staging)
        let environment = NativeRuntimeComponentEnvironment(
            executable: IsolatedRuntimePolicy.authorityProgram, runningVersion: manifest.version)
        try environment.verifyCode(staging, notarized: true)
        let target = try environment.inspect(staging)
        guard target.cdhash == manifest.setup.cdhash, target.helperSHA256 == manifest.helper.sha256,
            target.apiSHA256 == manifest.api.sha256, target.guestSHA256 == manifest.guestSHA256,
            target.version == manifest.version, target.revision == manifest.sourceRevision
        else { throw MicropodError.message("The setup app does not match its signed manifest; nothing was changed") }
        let updater = RuntimeComponentUpdater(environment: environment)
        let marks = try updater.state()
        if let highest = marks.highestVersion.flatMap(ReleaseVersion.init), let version = manifest.releaseVersion,
            version < highest
        {
            throw MicropodError.message(
                "Micropod \(manifest.version) is older than \(highest), the newest this host ran")
        }
        if let floor = marks.securityFloor.flatMap(ReleaseVersion.init), let version = manifest.releaseVersion,
            version < floor
        {
            throw MicropodError.message("Micropod \(manifest.version) is below the signed security floor \(floor)")
        }
        let installer = RuntimeAuthorityInstaller(host: NativeRuntimeAuthorityInstallHost())
        let pending = installer.pending(target: target)

        print("Micropod runtime authority \(target.version) (\(target.revision.prefix(12)))")
        print("  setup CDHash        \(target.cdhash)")
        print("  helper SHA-256      \(target.helperSHA256)")
        print("  dedicated API       \(target.apiSHA256)")
        print("  guest tool          \(target.guestSHA256 ?? "none")")
        print("  definition SHA-256  \(RuntimeAuthority.definitionSHA256)")
        print("  program             \(IsolatedRuntimePolicy.authorityProgram.path)")
        print("  LaunchDaemon        \(IsolatedRuntimePolicy.authorityPlist.path)")
        print(
            "  steps               \(pending.isEmpty ? "none: already installed" : pending.map(\.rawValue).joined(separator: ", "))"
        )
        guard !pending.isEmpty else { return }
        let expected = String(target.cdhash.prefix(12))
        if let confirmation = parsed.value("--confirm") {
            guard confirmation == expected else {
                throw MicropodError.message("--confirm does not match the CDHash shown; nothing was changed")
            }
        } else {
            print("Type the first 12 characters of the setup CDHash to install it: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces) == expected else {
                throw MicropodError.message("Not confirmed; nothing was changed")
            }
        }
        let done: [RuntimeAuthorityInstaller.Step]
        do {
            done = try installer.run(source: staging, manifest: manifest, target: target)
        } catch {
            // A staged authority counts for the high-water mark even when a
            // later step stopped; run install-authority again to finish.
            if installer.host.authorityIdentity() == target {
                try? updater.recordInstalled(version: target.version, floor: manifest.securityFloor)
            }
            throw error
        }
        try updater.recordInstalled(version: target.version, floor: manifest.securityFloor)
        // run() returns only once the legacy job is booted out, disabled and
        // its bundle immutable, and the authority's live helper is the target.
        print("Installed: \(done.map(\.rawValue).joined(separator: ", ")).")
        print("  legacy job          booted out, disabled; \(RuntimeSetupInstallation.installedURL.path) is schg")
        print("  authority           serving \(target.version)")
        print("Next, as yourself: `micropod runtime update` restarts the dedicated runtime onto it.")
        print("Optionally remove the old Login Items entry: Micropod Runtime Setup → Retire the Old Background Item.")
    }

    static let instructions = """
        The runtime authority is installed once by an administrator, from a clean admin session (a fresh login
        as a local administrator; no other user session or CI job running), with the release's own CLI:

          1. Download and unpack the release tarball (Micropod.<version>.tgz) into an empty directory; cd there.
          2. Copy the CLI into a root-only directory, so no other process can change it before or while it runs:
               sudo install -d -o root -g wheel -m 0700 /var/root/micropod-install
               sudo rm -rf /var/root/micropod-install/<version>
               sudo install -d -o root -g wheel -m 0700 /var/root/micropod-install/<version>
               sudo ditto --noextattr --noacl ./micropod /var/root/micropod-install/<version>/micropod
               sudo chown root:wheel /var/root/micropod-install/<version>/micropod
               sudo chmod 0755 /var/root/micropod-install/<version>/micropod
          3. Check that copy (not the download) before running it as root:
               sudo codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "WFTX6CN23F" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' /var/root/micropod-install/<version>/micropod
          4. Run it from there:
               sudo /var/root/micropod-install/<version>/micropod runtime install-authority --app ./Micropod.app
        It refuses to run from any path that is not root-owned all the way to /.
        """

    static func selfExecutable() throws -> URL {
        var count: UInt32 = 4096
        var path = [CChar](repeating: 0, count: Int(count))
        guard _NSGetExecutablePath(&path, &count) == 0 else {
            throw MicropodError.message("The CLI's own path is unavailable")
        }
        return try realPath(
            String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// realpath(3): every link resolved, `/private` kept (Foundation's
    /// resolvingSymlinksInPath drops it, which would name a symbolic link).
    static func realPath(_ path: String) throws -> URL {
        guard let resolved = realpath(path, nil) else { throw MicropodError.message("\(path) cannot be resolved") }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Why running `executable` as root is unsafe, or nil: it and every
    /// ancestor must be owned by root (`owners` exists for tests), not
    /// writable by group or others, carry no ACL, and not be a symbolic link.
    static func launchPathProblem(_ executable: URL, owners: Set<uid_t> = [0]) -> String? {
        var path = executable.path  // already realpath(3); standardizing would drop /private
        while true {
            var info = stat()
            guard lstat(path, &info) == 0 else { return "\(path) is missing" }
            guard info.st_mode & S_IFMT != S_IFLNK else { return "\(path) is a symbolic link" }
            guard owners.contains(info.st_uid) else { return "\(path) is not owned by root" }
            guard info.st_mode & 0o022 == 0 else { return "\(path) is writable by group or others" }
            if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                if acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0 { return "\(path) carries an ACL" }
            }
            if path == "/" { return nil }
            path = (path as NSString).deletingLastPathComponent
            if path.isEmpty { path = "/" }
        }
    }
}
