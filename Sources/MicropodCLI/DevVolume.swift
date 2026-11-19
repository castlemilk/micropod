import Darwin
import Foundation

struct DevVolumeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum DevTool {
    struct Result {
        let code: Int32
        let data: Data
        let error: String
        var output: String { String(decoding: data, as: UTF8.self) }
    }

    static let diskutil = "/usr/sbin/diskutil"
    static let mdutil = "/usr/bin/mdutil"
    static let sudo = "/usr/bin/sudo"

    static func capture(_ tool: String, _ arguments: [String]) throws -> Result {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmp) }
        func file(_ name: String) throws -> FileHandle {
            let url = tmp.appendingPathComponent(name)
            guard fm.createFile(atPath: url.path, contents: nil) else { throw DevVolumeError("Cannot capture \(tool)") }
            return try FileHandle(forUpdating: url)
        }
        let out = try file("stdout"), err = try file("stderr")
        defer {
            try? out.close()
            try? err.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        try out.seek(toOffset: 0)
        try err.seek(toOffset: 0)
        return Result(
            code: process.terminationStatus, data: try out.read(upToCount: 4 << 20) ?? Data(),
            error: String(decoding: try err.read(upToCount: 8192) ?? Data(), as: UTF8.self))
    }

    static func interact(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DevVolumeError("\(tool) exited \(process.terminationStatus)")
        }
    }

    static func plist(_ args: [String]) throws -> [String: Any] {
        let reply = try capture(diskutil, args)
        guard reply.code == 0 else { throw DevVolumeError("diskutil \(args.first ?? "") failed. \(reply.error)") }
        guard let result = try PropertyListSerialization.propertyList(from: reply.data, format: nil) as? [String: Any]
        else { throw DevVolumeError("diskutil returned an invalid property list") }
        return result
    }
}

struct DevVolume: Codable {
    struct Tree: Codable {
        let name: String
        let source: String
        var generation = UUID()
        var backup: String { source + ".micropod-original-" + generation.uuidString }
    }

    let token: UUID
    let containerID: UUID
    let encrypted: Bool
    let caseSensitive: Bool
    var initialized = false
    var volumeID: UUID?
    var trees: [Tree]
    var label: String { "MicropodDev-" + token.uuidString }
    var mount: String { "/Volumes/" + label }
    var payload: String { mount + "/data-" + token.uuidString }
    func destination(_ tree: Tree) -> String { payload + "/" + tree.name + "-" + tree.generation.uuidString }

    static func container(device: String? = nil, id: UUID? = nil) throws -> [String: Any] {
        var selected = device
        if selected == nil && id == nil {
            selected =
                try DevTool.plist(["info", "-plist", "/System/Volumes/Data"])["APFSContainerReference"] as? String
            guard selected != nil else { throw DevVolumeError("The startup Data volume has no APFS container") }
        }
        var args = ["apfs", "list", "-plist"]
        if let selected {
            guard selected.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
                throw DevVolumeError("An APFS container reference looks like disk3")
            }
            args.append(selected)
        }
        let list = try DevTool.plist(args)["Containers"] as? [[String: Any]] ?? []
        let matches = list.filter { row in
            if let id { return (row["APFSContainerUUID"] as? String).flatMap(UUID.init(uuidString:)) == id }
            return row["ContainerReference"] as? String == selected
        }
        guard matches.count == 1 else { throw DevVolumeError("Cannot uniquely locate the requested APFS container") }
        return matches[0]
    }

    func diskInfo(requireMount: Bool) throws -> [String: Any] {
        guard let volumeID else {
            throw DevVolumeError("Volume creation is incomplete. Repeat create with the same options.")
        }
        let container = try Self.container(id: containerID)
        let volumes = container["Volumes"] as? [[String: Any]] ?? []
        guard
            let row = volumes.first(where: {
                ($0["APFSVolumeUUID"] as? String).flatMap(UUID.init(uuidString:)) == volumeID
            }), row["Name"] as? String == label, let device = row["DeviceIdentifier"] as? String
        else {
            throw DevVolumeError("The recorded APFS volume is absent from its original container")
        }
        var info = try DevTool.plist(["info", "-plist", device])
        let locked =
            row["Locked"] as? Bool == true || info["Locked"] as? Bool == true
            || info["APFSVolumeLocked"] as? Bool == true
        guard info["DeviceIdentifier"] as? String == device,
            info["APFSContainerReference"] as? String == container["ContainerReference"] as? String,
            locked || Self.matches(info, volumeID, label)
        else { throw DevVolumeError("The recorded volume identity or container changed") }
        info["Locked"] = locked
        if let at = info["MountPoint"] as? String, !at.isEmpty {
            guard at == mount else { throw DevVolumeError("The recorded volume mounted at \(at); expected \(mount)") }
            let mounted = try DevTool.plist(["info", "-plist", at])
            guard Self.matches(mounted, volumeID, label) else {
                throw DevVolumeError("Mount point resolves to another volume")
            }
        } else if requireMount {
            throw DevVolumeError("The development volume is offline. Use mount first.")
        }
        return info
    }

    static func matches(_ info: [String: Any], _ id: UUID, _ label: String) -> Bool {
        (info["VolumeUUID"] as? String).flatMap(UUID.init(uuidString:)) == id
            && info["VolumeName"] as? String == label && (info["FilesystemType"] as? String)?.lowercased() == "apfs"
    }

    mutating func provision() throws {
        guard volumeID == nil else { return }
        let container = try Self.container(id: containerID)
        func matchingIDs(_ container: [String: Any]) -> [UUID] {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            return volumes.filter { $0["Name"] as? String == label }
                .compactMap { ($0["APFSVolumeUUID"] as? String).flatMap(UUID.init(uuidString:)) }
        }
        var matches = matchingIDs(container)
        if matches.isEmpty {
            guard let device = container["ContainerReference"] as? String else {
                throw DevVolumeError("Missing APFS device")
            }
            var args = [DevTool.diskutil, "apfs", "addVolume", device, caseSensitive ? "APFSX" : "APFS", label]
            if encrypted { args.append("-passprompt") }
            try DevTool.interact(DevTool.sudo, args)
            matches = matchingIDs(try Self.container(id: containerID))
        }
        guard matches.count == 1 else { throw DevVolumeError("Cannot identify the new volume by its recorded name") }
        volumeID = matches[0]
    }

    func mountVolume(remount: Bool = false) throws {
        let info = try diskInfo(requireMount: false)
        guard let device = info["DeviceIdentifier"] as? String else { throw DevVolumeError("Missing volume device") }
        if let path = info["MountPoint"] as? String, !path.isEmpty {
            if !remount { return }
            try DevTool.interact(DevTool.diskutil, ["unmount", device])
        }
        let current = try diskInfo(requireMount: false)
        if current["Locked"] as? Bool == true || current["APFSVolumeLocked"] as? Bool == true {
            try DevTool.interact(DevTool.diskutil, ["apfs", "unlockVolume", device, "-user", "disk"])
        } else {
            try DevTool.interact(DevTool.diskutil, ["mount", device])
        }
        _ = try diskInfo(requireMount: true)
    }

    // Only this operation runs as admin. It accepts volume identifiers, never user paths.
    static func initializeVolume(_ args: [String]) throws {
        let env = ProcessInfo.processInfo.environment
        guard geteuid() == 0, let uid = env["SUDO_UID"].flatMap(UInt32.init), uid != 0,
            let gid = env["SUDO_GID"].flatMap(UInt32.init), args.count == 2,
            let volume = UUID(uuidString: args[0]), let token = UUID(uuidString: args[1])
        else { throw DevVolumeError("Volume initialization requires the invoking login user and recorded UUIDs") }
        let label = "MicropodDev-" + token.uuidString, mount = "/Volumes/" + label
        for selector in [volume.uuidString, mount] {
            let info = try DevTool.plist(["info", "-plist", selector])
            guard matches(info, volume, label), info["MountPoint"] as? String == mount else {
                throw DevVolumeError("Refusing to initialize an unverified volume")
            }
        }
        let ownership = try DevTool.plist(["info", "-plist", volume.uuidString])
        if ownership["GlobalPermissionsEnabled"] as? Bool != true {
            try DevTool.interact(DevTool.diskutil, ["enableOwnership", volume.uuidString])
        }
        let fd = open(mount, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        func directory(_ name: String, _ mode: mode_t) throws -> Int32 {
            if mkdirat(fd, name, mode) != 0 && errno != EEXIST { throw DevVolumeError("Cannot create \(name)") }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var parentStat = stat(), childStat = stat()
            guard child >= 0 else { throw DevVolumeError("Unsafe directory \(name)") }
            guard fstat(fd, &parentStat) == 0, fstat(child, &childStat) == 0, childStat.st_dev == parentStat.st_dev
            else {
                close(child)
                throw DevVolumeError("Directory \(name) crosses a volume")
            }
            return child
        }
        func marker(_ dir: Int32, _ name: String) throws {
            let file = openat(dir, name, O_RDONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
            guard file >= 0 else { throw DevVolumeError("Cannot create \(name)") }
            defer { close(file) }
            var meta = stat()
            guard fstat(file, &meta) == 0, (meta.st_mode & S_IFMT) == S_IFREG, meta.st_size == 0 else {
                throw DevVolumeError("Unexpected indexing marker \(name)")
            }
        }
        let events = try directory(".fseventsd", 0o755)
        defer { close(events) }
        try marker(events, "no_log")
        try marker(fd, ".metadata_never_index")
        let payload = try directory("data-" + token.uuidString, 0o700)
        defer { close(payload) }
        var info = stat()
        guard fstat(payload, &info) == 0 else {
            throw DevVolumeError("Cannot stat payload directory: \(String(cString: strerror(errno)))")
        }
        guard [0, uid].contains(info.st_uid) else {
            throw DevVolumeError("Unexpected payload owner \(info.st_uid), expected root or \(uid)")
        }
        guard fchown(payload, uid, gid) == 0 else {
            throw DevVolumeError("Cannot set payload owner to \(uid):\(gid): \(String(cString: strerror(errno)))")
        }
        guard fchmod(payload, 0o700) == 0 else {
            throw DevVolumeError("Cannot set payload permissions: \(String(cString: strerror(errno)))")
        }
        let indexing = try DevTool.capture(DevTool.mdutil, ["-i", "off", mount])
        if indexing.code != 0 {
            let status = try DevTool.capture(DevTool.mdutil, ["-s", mount])
            guard (status.output + status.error).lowercased().contains("disabled") else {
                throw DevVolumeError(
                    "Spotlight could not apply the volume policy. \(indexing.output) \(indexing.error)")
            }
        }
    }
}
