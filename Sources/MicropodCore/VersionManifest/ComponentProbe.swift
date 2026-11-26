import Darwin
import Foundation

/// The components a version manifest names, in reporting order.
public enum MicropodComponent: String, CaseIterable, Sendable {
    case app
    case connectAPI = "connect-api"
    case dedicatedAPI = "dedicated-api"
    case setupHelper = "setup-helper"
    case runtimeAuthority = "runtime-authority"
    case dockerShim = "docker-shim"
    case sharedFS = "shared-fs"
    case appleRuntime = "apple-runtime"
    case vminit
    case guest
    case kernel
}

public enum ComponentState: String, Sendable {
    case running, stopped, installed, missing
    case notConfigured = "not_configured"
    case unknown
    /// `runtime-authority` only: serving, but its last protection check
    /// failed; `legacy_active` when the legacy SMAppService job is the reason.
    case unprotected
    case legacyActive = "legacy_active"
}

/// Read-only observations of installed Micropod components. Probes read
/// files or connect to a socket; none runs a process. Anything a probe cannot
/// read is "unknown" with the reason in `detail`, never a guess.
public enum ComponentProbe {
    public static let unknown = "unknown"

    public static func component(
        _ name: MicropodComponent, version: String = unknown, revision: String = unknown, sha256: String = "",
        state: ComponentState, detail: String = ""
    ) -> Micropod_V1_ComponentVersion {
        Micropod_V1_ComponentVersion.with {
            $0.name = name.rawValue
            $0.version = version.isEmpty ? unknown : version
            $0.revision = revision.isEmpty ? unknown : revision
            $0.sha256 = sha256
            $0.state = state.rawValue
            $0.detail = detail
        }
    }

    /// Release and source revision a build declares.
    public struct Stamp: Equatable, Sendable {
        public let version: String
        public let revision: String
        public init(version: String, revision: String) {
            self.version = version.isEmpty ? ComponentProbe.unknown : version
            self.revision = revision.isEmpty ? ComponentProbe.unknown : revision
        }
    }

    /// The version and revision in a bundle's Info.plist. Throws the reason
    /// when the file cannot be read.
    public static func bundleStamp(_ bundle: URL) throws -> Stamp {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let data: Data
        do {
            data = try Data(contentsOf: plist)
        } catch {
            throw MicropodError.message("\(plist.path) is not readable: \(describe(error))")
        }
        guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw MicropodError.message("\(plist.path) is not a property list") }
        return Stamp(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            revision: info["MicropodSourceRevision"] as? String ?? "")
    }

    /// The innermost `.app` bundle holding a file, if any.
    public static func enclosingBundle(of file: URL) -> URL? {
        var url = file.standardizedFileURL.deletingLastPathComponent()
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Digests

    private struct DigestKey: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int
        let modifiedNanoseconds: Int
    }

    private final class DigestCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DigestKey: String] = [:]
        func value(_ key: DigestKey) -> String? { lock.withLock { values[key] } }
        func store(_ key: DigestKey, _ value: String) {
            lock.withLock {
                if values.count >= 64 { values.removeAll() }
                values[key] = value
            }
        }
    }

    private static let digests = DigestCache()

    /// SHA-256 of a regular file, hex; nil when it cannot be read. Cached by
    /// the file's identity (device, inode, size, modification time), so an
    /// unchanged file is hashed once per process and a replaced one again.
    public static func sha256(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let key = DigestKey(
            path: url.path, device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        if let cached = digests.value(key) { return cached }
        guard let digest = try? UpdateServiceWitness.digest(url) else { return nil }
        digests.store(key, digest)
        return digest
    }

    // MARK: - Sockets

    public enum SocketObservation: Equatable, Sendable {
        /// Something accepted (or queued) a connection.
        case accepting
        /// A socket file exists but nothing listens on it.
        case refused
        /// No socket at the path.
        case absent
        /// The path could not be checked.
        case unreadable(String)
    }

    /// Connects to a unix socket without blocking and closes it at once.
    public static func observeSocket(_ path: String) -> SocketObservation {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .absent : .unreadable(String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return .unreadable("\(path) is not a socket") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreadable(String(cString: strerror(errno))) }
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return .unreadable("\(path) is too long for a unix socket")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .accepting }
        switch errno {
        case EAGAIN, EINPROGRESS: return .accepting
        case ECONNREFUSED: return .refused
        case ENOENT: return .absent
        default: return .unreadable(String(cString: strerror(errno)))
        }
    }

    /// running / stopped / unknown for a service's endpoint socket.
    public static func serviceState(socket path: String) -> (ComponentState, String) {
        switch observeSocket(path) {
        case .accepting: (.running, "accepting on \(path)")
        case .refused: (.stopped, "nothing listens on \(path)")
        case .absent: (.stopped, "no socket at \(path)")
        case .unreadable(let reason): (.unknown, "\(path) could not be checked: \(reason)")
        }
    }

    // MARK: - Components

    /// A launchd-retained desktop service recorded under
    /// `~/.micropod/services/<id>.json`; nil when this account retains none.
    /// The version is read from the retained payload bundle the record names.
    public static func retainedService(
        _ name: MicropodComponent, id: String, servicesRoot: URL, socket: String, digest: Bool
    ) -> Micropod_V1_ComponentVersion? {
        let recordURL = servicesRoot.appendingPathComponent(id + ".json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        struct Record: Decodable {
            let sourceVersion: String
            let executable: String
            let sha256: String
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recordURL))
        } catch {
            return component(name, state: .unknown, detail: "\(recordURL.path) is not readable: \(describe(error))")
        }
        let executable = URL(fileURLWithPath: record.executable)
        var stamp = Stamp(version: record.sourceVersion, revision: "")
        var notes = ["retained payload " + record.executable]
        if let bundle = enclosingBundle(of: executable) {
            do { stamp = try bundleStamp(bundle) } catch { notes.append(describe(error)) }
        }
        var hash = ""
        if digest {
            if let value = sha256(executable) {
                hash = value
                if value != record.sha256 { notes.append("differs from its recorded sha256 \(record.sha256)") }
            } else {
                notes.append("its executable is not readable")
            }
        }
        let (state, observed) = serviceState(socket: socket)
        notes.append(observed)
        return component(
            name, version: stamp.version, revision: stamp.revision, sha256: hash, state: state,
            detail: notes.joined(separator: "; "))
    }

    /// A service binary shipped beside the answering server's executable
    /// (the same build), when no retained payload owns it.
    public static func bundledService(
        _ name: MicropodComponent, binary: String, besides executable: URL, build: Stamp, socket: String,
        digest: Bool
    ) -> Micropod_V1_ComponentVersion {
        let url = executable.deletingLastPathComponent().appendingPathComponent(binary)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let (state, observed) = serviceState(socket: socket)
            if state == .running {
                return component(name, state: .running, detail: "\(observed); its executable is not beside this server")
            }
            return component(name, state: .missing, detail: "no \(binary) beside \(executable.path)")
        }
        let (state, observed) = serviceState(socket: socket)
        return component(
            name, version: build.version, revision: build.revision,
            sha256: digest ? (sha256(url) ?? "") : "", state: state, detail: "\(url.path); \(observed)")
    }

    /// The runtime's default kernel: `kernels/default.kernel-arm64` under its
    /// app root, a link to `vmlinux-<release>`.
    public static func kernel(appRoot: URL, digest: Bool) -> Micropod_V1_ComponentVersion {
        let link = appRoot.appendingPathComponent("kernels/default.kernel-arm64")
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                readlink(link.path, $0, raw.count - 1)
            }
        }
        guard count >= 0 else {
            let code = errno
            switch code {
            case ENOENT:
                return component(.kernel, state: .missing, detail: "no default kernel at \(link.path)")
            case EINVAL:
                return component(
                    .kernel, sha256: digest ? (sha256(link) ?? "") : "", state: .installed,
                    detail: "\(link.path) is not a versioned link")
            default:
                return component(
                    .kernel, state: .unknown, detail: "\(link.path) is not readable: \(String(cString: strerror(code)))"
                )
            }
        }
        let target = String(decoding: buffer.prefix(count), as: UTF8.self)
        let resolved =
            target.hasPrefix("/")
            ? URL(fileURLWithPath: target) : link.deletingLastPathComponent().appendingPathComponent(target)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return component(.kernel, state: .missing, detail: "default kernel link points at missing \(resolved.path)")
        }
        let file = resolved.lastPathComponent
        let version = file.hasPrefix("vmlinux-") ? String(file.dropFirst("vmlinux-".count)) : unknown
        return component(
            .kernel, version: version, sha256: digest ? (sha256(resolved) ?? "") : "", state: .installed,
            detail: resolved.path)
    }

    /// Micropod Runtime Setup, which carries the root helper and the
    /// dedicated API. `running` is nil when the caller did not look.
    public static func setupHelper(at app: URL, running: Bool?, digest: Bool) -> Micropod_V1_ComponentVersion {
        guard FileManager.default.fileExists(atPath: app.path) else {
            return component(.setupHelper, state: .notConfigured, detail: "\(app.path) is not installed")
        }
        let stamp: Stamp
        do {
            stamp = try bundleStamp(app)
        } catch {
            return component(.setupHelper, state: .unknown, detail: describe(error))
        }
        var notes = [app.path]
        var version = stamp.version
        // Setup apps packaged before version stamping all declared 0.1.0 and
        // no revision, whatever release they came from.
        if stamp.revision == unknown, stamp.version == "0.1.0" {
            version = unknown
            notes.append("packaged before version stamping; its 0.1.0 is a placeholder")
        }
        let helper = app.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost")
        let state: ComponentState = running.map { $0 ? .running : .stopped } ?? .installed
        return component(
            .setupHelper, version: version, revision: stamp.revision,
            sha256: digest ? (sha256(helper) ?? "") : "", state: state, detail: notes.joined(separator: "; "))
    }

    /// The root-owned runtime authority (docs/runtime-component-update.md),
    /// from world-readable facts only: its plist, its bundle's Info.plist,
    /// the paths of root `MicropodRuntimeHost` processes (`helpers`) and the
    /// protection check the authority publishes (`RuntimeHost/protection.json`,
    /// root-owned). States: `missing` while a dedicated runtime still depends
    /// on the legacy SMAppService helper; `legacy_active` while the authority
    /// serves but the legacy job is not retired; `unprotected` for any other
    /// failed check; `running`; `stopped`. Fleet views list the rigs that
    /// need `install-authority` before the legacy identifier's sunset.
    public static func runtimeAuthority(
        helpers: [String], dedicated: Bool, plist: URL = IsolatedRuntimePolicy.authorityPlist,
        bundle: URL = IsolatedRuntimePolicy.authorityBundle,
        legacyBundle: URL = RuntimeSetupInstallation.installedURL,
        protection: URL = IsolatedRuntimePolicy.root.appendingPathComponent("protection.json"),
        protectionOwner: uid_t = 0
    ) -> Micropod_V1_ComponentVersion {
        let program = bundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost").path
        let legacyProgram = legacyBundle.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost").path
        let legacyRuns = helpers.contains(legacyProgram)
        let sunset = ISO8601DateFormatter.string(
            from: IsolatedRuntimePolicy.legacyHelperSunset, timeZone: TimeZone(identifier: "UTC")!,
            formatOptions: [.withFullDate])
        guard FileManager.default.fileExists(atPath: plist.path) else {
            guard dedicated || legacyRuns else {
                return component(.runtimeAuthority, state: .notConfigured, detail: "No runtime authority is installed")
            }
            return component(
                .runtimeAuthority, state: .missing,
                detail: "The dedicated runtime's root helper runs from the legacy SMAppService job; an "
                    + "administrator runs `sudo micropod runtime install-authority` before \(sunset), when releases "
                    + "stop accepting its signing identifier")
        }
        let stamp = try? bundleStamp(bundle)
        var notes = [plist.path]
        if legacyRuns {
            notes.append("the legacy SMAppService helper still runs: run install-authority again to retire it")
        }
        func report(_ state: ComponentState) -> Micropod_V1_ComponentVersion {
            component(
                .runtimeAuthority, version: stamp?.version ?? unknown, revision: stamp?.revision ?? unknown,
                state: state, detail: notes.joined(separator: "; "))
        }
        guard helpers.contains(program) else { return report(.stopped) }
        struct Published: Decodable {
            let protected: Bool
            let legacyActive: Bool
            let reason: String?
            /// The last component update root forced over a failed check.
            let forced: RuntimeForcedComponentUpdate?
        }
        guard let data = try? RuntimeDurableFile.read(protection, maximumBytes: 4096, ownerUID: protectionOwner),
            let published = try? JSONDecoder().decode(Published.self, from: data)
        else {
            notes.append("its protection check is not published")
            return report(.unknown)
        }
        // A forced update leaves the state alone (consumers know every state
        // value) and is named in the detail, whatever the check says now.
        if let forced = published.forced { notes.append("a component \(forced.line)") }
        if published.protected { return report(.running) }
        notes.append("unprotected: " + (published.reason ?? "unknown"))
        if published.legacyActive {
            notes.append("the legacy SMAppService job is not retired: run install-authority again")
            return report(.legacyActive)
        }
        return report(.unprotected)
    }

    /// `micropod-guest` beside the answering server's executable or in its
    /// bundle's Resources: shipped with that build.
    public static func guest(besides executable: URL, build: Stamp, digest: Bool) -> Micropod_V1_ComponentVersion {
        let directory = executable.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("micropod-guest"),
            directory.deletingLastPathComponent().appendingPathComponent("Resources/micropod-guest"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return component(
                .guest, state: .missing,
                detail: "no micropod-guest beside \(executable.path); sandboxes use the image's shell tools")
        }
        return component(
            .guest, version: build.version, revision: build.revision, sha256: digest ? (sha256(url) ?? "") : "",
            state: .installed, detail: url.path)
    }

    /// The init image the runtime boots containers with.
    public static func vminit(reference: String?, unavailable: String) -> Micropod_V1_ComponentVersion {
        guard let reference, !reference.isEmpty else {
            return component(.vminit, state: .unknown, detail: unavailable)
        }
        var name = Substring(reference)
        var revision = unknown
        if let at = reference.firstIndex(of: "@") {
            revision = String(reference[reference.index(after: at)...])
            name = reference[..<at]
        }
        var version = unknown
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            version = String(name[name.index(after: colon)...])
        }
        return component(.vminit, version: version, revision: revision, state: .installed, detail: reference)
    }

    /// Release and commit from Apple's apiserver version: a bare release
    /// ("1.5.0") or, through 1.3.x, its banner
    /// ("container-apiserver version 1.3.1 (build: release, commit: a9a62e2)").
    public static func appleRelease(_ reported: String) -> Stamp {
        let version =
            reported.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression).map { String(reported[$0]) } ?? ""
        let revision =
            reported.range(of: #"commit: *[0-9A-Za-z]+"#, options: .regularExpression).map {
                reported[$0].replacingOccurrences(of: "commit:", with: "").trimmingCharacters(in: .whitespaces)
            } ?? ""
        return Stamp(version: version, revision: revision)
    }

    static func describe(_ error: Error) -> String {
        let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(posix.code)))
        }
        return error.localizedDescription
    }
}
