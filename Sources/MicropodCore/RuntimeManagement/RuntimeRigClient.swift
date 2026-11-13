import Darwin
import Foundation
import Security

public struct RuntimeRigReceipt: Codable, Sendable, Equatable {
    public let operation: UUID
    public let phase: String
    public let hostID: String
    public let owner: String
    public let generation: Int64
    public let reason: String?
}

public protocol RuntimeRigCoordinating: Sendable {
    func transition(operation: UUID, action: String, installRoot: URL, localGeneration: UInt64, targetState: String)
        async throws -> RuntimeRigReceipt?
}

/// Definite refusal before any request bytes reached a coordinator. Other
/// transport failures may have committed a grant and require compare-and-abort.
public enum RuntimeRigAdmissionError: LocalizedError, Sendable {
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// A missing socket is not permission to ignore an enrolled/offline rig.
/// Host credentials and authority remain inside the signed Cuttlefish process.
public struct RuntimeRigClient: RuntimeRigCoordinating {
    public init() {}
    public static var socketPath: String {
        NSHomeDirectory() + "/.cuttlefish/runner-state/micropod-maintenance.sock"
    }
    public func transition(
        operation: UUID, action: String, installRoot: URL, localGeneration: UInt64, targetState: String
    ) async throws -> RuntimeRigReceipt? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let knownRig =
            fm.fileExists(atPath: Self.socketPath)
            || fm.fileExists(atPath: home.appendingPathComponent(".cuttlefish/agent-desktop-state.json").path)
            || fm.fileExists(atPath: home.appendingPathComponent(".cuttlefish/desktop-state.json").path)
            || fm.fileExists(
                atPath: home.appendingPathComponent("Library/LaunchAgents/dev.cuttlefish.agent.desktop.plist").path)
            || fm.fileExists(
                atPath: home.appendingPathComponent("Library/LaunchAgents/dev.cuttlefish.agent.hostlocal.plist").path)
        guard knownRig else {
            throw RuntimeRigAdmissionError.unavailable(
                "Runtime files are staged. Activation requires a qualified runtime consumer coordinator; an idle snapshot cannot authorize a shared-service restart."
            )
        }
        struct Request: Encodable {
            let operation: UUID
            let action: String
            let version: String
            let packageSHA256: String
            let installRoot: String
            let localGeneration: UInt64
            let targetState: String
        }
        let request = Request(
            operation: operation, action: action, version: AppleRuntimeRelease.supported.version,
            packageSHA256: AppleRuntimeRelease.supported.packageSHA256, installRoot: installRoot.path,
            localGeneration: localGeneration, targetState: targetState)
        let data = try JSONEncoder().encode(request) + Data([10])
        let response = try await RuntimePeerSocket.exchange(path: Self.socketPath, request: data)
        let receipt = try JSONDecoder().decode(RuntimeRigReceipt.self, from: response)
        guard receipt.operation == operation, receipt.generation >= 0 else {
            throw MicropodError.message("Rig maintenance ownership did not match")
        }
        if let reason = receipt.reason, !reason.isEmpty, receipt.phase != "draining" {
            throw MicropodError.message(reason)
        }
        return receipt
    }
}

/// Authenticates the connected process, rather than a path/snapshot of the
/// listener. There are no HTTP redirects, cookies, bearer tokens or shell hooks.
enum RuntimePeerSocket {
    static func exchange(path: String, request: Data) async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try blockingExchange(path: path, request: request) })
            }
        }
    }
    private static func blockingExchange(path: String, request: Data) throws -> Data {
        guard request.count <= 8192 else { throw refused() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw notSent() }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw notSent() }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw notSent() }
        withUnsafeMutableBytes(of: &address.sun_path) { output in output.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw notSent() }
            do { try wait(fd, events: Int16(POLLOUT), deadline: deadline) } catch { throw notSent() }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw notSent() }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
            signedCoordinator(pid: pid)
        else { throw notSent() }
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                guard count > 0 else { throw refused() }
                offset += count
            }
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count <= 16384 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
                continue
            }
            guard count > 0 else { throw refused() }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 16384 else { throw refused() }
            if let newline = result.firstIndex(of: 10) { return result.prefix(upTo: newline) }
        }
        throw refused()
    }
    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw refused() }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, 20_000))
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0, errno == EINTR { continue }
            guard result > 0, descriptor.revents & Int16(POLLNVAL) == 0 else { throw refused() }
            return
        }
    }
    private static func signedCoordinator(pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let rule = #"anchor apple generic and certificate leaf[subject.OU] = "WFTX6CN23F" "#
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
        else { return false }
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
            let info = information as? [String: Any],
            let identifier = info[kSecCodeInfoIdentifier as String] as? String
        else { return false }
        return identifier == "cuttlefish-agent-runtime" || identifier.hasPrefix("cuttlefish-agent-runtime-")
            || identifier == "cuttlefish-agent" || identifier.hasPrefix("cuttlefish-agent-")
    }
    private static func refused() -> Error {
        MicropodError.message(
            "The rig maintenance coordinator is unavailable or its identity could not be verified. Update or reconnect Cuttlefish before managing this runtime."
        )
    }
    private static func notSent() -> Error {
        RuntimeRigAdmissionError.unavailable(
            "Runtime files are staged. The rig maintenance coordinator is unavailable or untrusted; update or reconnect Cuttlefish before activation."
        )
    }
}
