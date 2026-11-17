import Darwin
import Foundation

extension RigUpgradeEngine {
    /// `renamex_np(RENAME_SWAP)`: both paths stay valid at every instant.
    @Sendable public static func swapItems(_ first: URL, _ second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw MicropodError.message(
                "Could not swap \(first.path) with \(second.path): \(String(cString: strerror(errno)))")
        }
    }

    /// The swap is a rename, so both bundles must share a volume and be writable.
    public static func requireAtomicSwap(_ staged: URL, _ app: URL) throws {
        var stagedInfo = stat()
        var appInfo = stat()
        let stagedParent = staged.deletingLastPathComponent().path
        let appParent = app.deletingLastPathComponent().path
        guard stat(stagedParent, &stagedInfo) == 0, stat(appParent, &appInfo) == 0 else {
            throw MicropodError.message("Cannot inspect \(stagedParent) and \(appParent)")
        }
        guard stagedInfo.st_dev == appInfo.st_dev else {
            throw MicropodError.message(
                "\(stagedParent) and \(appParent) are on different volumes, so \(app.lastPathComponent) cannot be "
                    + "swapped atomically")
        }
        // Moving a directory to another parent rewrites its "..": both
        // bundles and both parents must be this account's to change.
        for path in [appParent, stagedParent, app.path, staged.path] {
            var info = stat()
            guard lstat(path, &info) == 0, access(path, W_OK) == 0 else {
                throw MicropodError.message(
                    "This account cannot replace \(app.path) (\(path) is not writable); run as its owner")
            }
            if path == app.path || path == staged.path {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                    throw MicropodError.message(
                        "\(path) is not a directory this account owns; reinstall Micropod as this user first")
                }
            }
        }
    }

    /// Whether a file the upgrade replaces exists. A symbolic link or any
    /// other non-regular file is refused: it could be replaced forward but
    /// its previous bytes could not be restored.
    static func existingRegularFile(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else {
                throw MicropodError.message("\(url.path) cannot be inspected: \(String(cString: strerror(errno)))")
            }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw MicropodError.message(
                "\(url.path) is a symbolic link or not a regular file; replace it with a regular file before upgrading")
        }
        return true
    }

    /// The first program argument of a launch agent.
    static func programPath(_ plist: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: plist.path),
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (value["ProgramArguments"] as? [String])?.first ?? value["Program"] as? String
    }

    static func digest(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? UpdateServiceWitness.digest(URL(fileURLWithPath: path))
    }

    /// Copies `source` over `installed` through a temporary file in the same
    /// directory, fsynced, so a reader sees the old or the new bytes.
    static func install(_ source: URL, at installed: URL, mode: UInt16) throws {
        let fm = FileManager.default
        let directory = installed.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".rig-upgrade-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        guard chmod(temporary.path, mode_t(mode)) == 0 else {
            throw MicropodError.message("Cannot set the mode of \(installed.path)")
        }
        let fd = open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw MicropodError.message("Cannot open \(temporary.path)") }
        let synced = fsync(fd) == 0
        close(fd)
        guard synced, rename(temporary.path, installed.path) == 0 else {
            throw MicropodError.message("Cannot install \(installed.path): \(String(cString: strerror(errno)))")
        }
        try RuntimeDurableFile.syncDirectory(directory)
    }

    /// Records one file replacement and saves the installed file's bytes in
    /// the operation directory. New bytes are either `source` or `bytes`.
    func replacement(
        installed: URL, source: URL? = nil, bytes: Data? = nil, in directory: URL, mode: UInt16
    ) throws -> RigFileReplacement {
        let fm = FileManager.default
        let name = installed.lastPathComponent
        let replacement: URL
        if let source {
            replacement = source
        } else {
            replacement = directory.appendingPathComponent("new/" + name)
            try? fm.removeItem(at: replacement)
            guard
                fm.createFile(
                    atPath: replacement.path, contents: bytes ?? Data(), attributes: [.posixPermissions: 0o600])
            else { throw MicropodError.message("Cannot write \(replacement.path)") }
        }
        guard let replacementSHA256 = Self.digest(replacement.path) else {
            throw MicropodError.message("\(replacement.path) is not readable")
        }
        var backup: URL?
        var backupSHA256: String?
        if try Self.existingRegularFile(installed) {
            let saved = directory.appendingPathComponent("previous/" + name)
            try? fm.removeItem(at: saved)
            try fm.copyItem(at: installed, to: saved)
            backup = saved
            backupSHA256 = Self.digest(saved.path)
        }
        let attributes = try? fm.attributesOfItem(atPath: installed.path)
        let previousMode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value
        return RigFileReplacement(
            installed: installed.path, backup: backup?.path, backupSHA256: backupSHA256,
            replacement: replacement.path, replacementSHA256: replacementSHA256, mode: previousMode ?? mode)
    }

    /// A copy of the target outside the replaceable app, named as the app
    /// names its own payloads (`<build>-<executable sha256>`).
    func ensurePayload(_ target: RigBundleIdentity, from staged: URL) throws -> URL {
        let fm = FileManager.default
        let directory = layout.payloadsRoot.appendingPathComponent(target.build + "-" + target.executableSHA256)
        let payload = directory.appendingPathComponent("Micropod.app")
        if fm.fileExists(atPath: payload.path) {
            guard target.matches(payload) else {
                throw MicropodError.message("\(payload.path) exists but is not \(target.version); it was left alone")
            }
            try environment.verifier.verifyApp(payload)
            return payload
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".staged-" + UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: partial) }
        try fm.copyItem(at: staged, to: partial)
        guard target.matches(partial) else { throw MicropodError.message("The \(target.version) payload copy differs") }
        try environment.verifier.verifyApp(partial)
        try fm.moveItem(at: partial, to: payload)
        return payload
    }

    /// The swapped-out app becomes the kept previous release.
    func keepPrevious(_ journal: RigUpgradeJournal) -> [String] {
        let fm = FileManager.default
        let staged = URL(fileURLWithPath: journal.stagedBundle)
        let previous = URL(fileURLWithPath: journal.previousBundle)
        var notes: [String] = []
        if journal.source.matches(staged) {
            do {
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staged, to: previous)
                notes.append("The previous \(journal.source.version) app is kept at \(previous.path).")
            } catch {
                notes.append("The previous app stays at \(staged.path): \(Self.describe(error))")
            }
        }
        let stagedDirectory = staged.deletingLastPathComponent()
        try? fm.removeItem(at: stagedDirectory.appendingPathComponent(RigStagedRelease.fileName))
        if (try? fm.contentsOfDirectory(atPath: stagedDirectory.path))?.isEmpty == true {
            try? fm.removeItem(at: stagedDirectory)
        }
        return notes
    }

    /// Keeps the current and previous release directories, payloads and
    /// operation records; never removes a directory a running process uses
    /// or a payload a service record names.
    func collectGarbage(_ journal: RigUpgradeJournal) -> [String] {
        let fm = FileManager.default
        // Listings, the journal and the process table may spell one
        // directory differently (/var and /private/var): decide on names
        // within each root, and compare resolved paths for processes.
        let running = environment.runningExecutables().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        func inUse(_ directory: URL) -> Bool {
            let prefix = directory.resolvingSymlinksInPath().path + "/"
            return running.contains { $0.hasPrefix(prefix) }
        }
        func children(_ directory: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
        }
        var notes: [String] = []
        func remove(_ url: URL, _ what: String) {
            do {
                try fm.removeItem(at: url)
                notes.append("Removed \(what) \(url.lastPathComponent).")
            } catch { notes.append("Could not remove \(url.path): \(Self.describe(error))") }
        }

        let previousRelease = URL(fileURLWithPath: journal.previousBundle).deletingLastPathComponent().lastPathComponent
        // When the previous app could not be moved, its only copy is still
        // in the staged directory.
        let stagedRelease = URL(fileURLWithPath: journal.stagedBundle).deletingLastPathComponent().lastPathComponent
        let previousStayed = journal.source.matches(URL(fileURLWithPath: journal.stagedBundle))
        for directory in children(layout.releasesRoot) {
            if directory.lastPathComponent == previousRelease { continue }
            if previousStayed, directory.lastPathComponent == stagedRelease { continue }
            if let marker = RigStagedRelease.read(directory), marker.isNewer(than: journal.target.version) { continue }
            if inUse(directory) { continue }
            remove(directory, "release")
        }

        var payloads: Set<String> = [
            URL(fileURLWithPath: journal.targetPayload).deletingLastPathComponent().lastPathComponent
        ]
        func keepPayload(of record: RetainedServiceRecord) {
            guard let bundle = ComponentProbe.enclosingBundle(of: URL(fileURLWithPath: record.executable)) else {
                return
            }
            payloads.insert(bundle.deletingLastPathComponent().lastPathComponent)
        }
        for id in RetainedServiceLaunchAgent.ids {
            let url = RetainedServiceLaunchAgent.recordURL(id, servicesRoot: layout.servicesRoot)
            if let record = try? RetainedServiceLaunchAgent.readRecord(url) { keepPayload(of: record) }
        }
        for file in journal.files where file.installed.hasPrefix(layout.servicesRoot.path + "/") {
            if let backup = file.backup,
                let record = try? RetainedServiceLaunchAgent.readRecord(URL(fileURLWithPath: backup))
            {
                keepPayload(of: record)
            }
        }
        for directory in children(layout.payloadsRoot) {
            if payloads.contains(directory.lastPathComponent) || inUse(directory) { continue }
            remove(directory, "service payload")
        }

        let operations = children(layout.operationsRoot).sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        var keptOther = false
        for directory in operations {
            if directory.lastPathComponent == journal.operation.uuidString || inUse(directory) { continue }
            if !keptOther {
                keptOther = true
                continue
            }
            remove(directory, "upgrade record")
        }
        return notes
    }
}
