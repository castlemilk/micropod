import Darwin
import Foundation
import MicropodCore

/// The only desktop entry to the dedicated account. Authentication happens on
/// the accepted BSD socket, using the kernel's uid/pid/start time, before a
/// byte is forwarded into the private home. Byte forwarding preserves duplex
/// guest bridges and all Connect/SSE framing without a second HTTP parser.
final class IsolatedRuntimeGateway: @unchecked Sendable {
    private let identity: IsolatedRuntimeIdentity
    private let socketPath: String
    private let internalSocketPath: String
    private let sessionsRoot: URL
    private let registryOwnerUID: UInt32
    private var source: DispatchSourceRead?
    private let slots = DispatchSemaphore(value: 128)
    init(
        identity: IsolatedRuntimeIdentity,
        socketPath: String = IsolatedRuntimeAPIConfiguration.socketURL.path,
        internalSocketPath: String = IsolatedRuntimeAPIConfiguration.internalSocketURL.path,
        sessionsRoot: URL = IsolatedRuntimeAPIConfiguration.sessionsRoot, registryOwnerUID: UInt32 = 0
    ) {
        self.identity = identity
        self.socketPath = socketPath
        self.internalSocketPath = internalSocketPath
        self.sessionsRoot = sessionsRoot
        self.registryOwnerUID = registryOwnerUID
    }
    func stop() {
        source?.cancel()
        source = nil
    }

    func start() throws {
        let path = socketPath
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == identity.serviceUID, existing.st_mode & S_IFMT == S_IFSOCK else {
                throw MicropodError.message("The managed API socket has another owner")
            }
            guard unlink(path) == 0 else { throw MicropodError.message("Could not replace the managed API socket") }
        } else if errno != ENOENT {
            throw MicropodError.message("Could not inspect the managed API socket")
        }
        let fd = try RuntimeUnixSocket.open()
        do {
            var address = try RuntimeUnixSocket.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o666) == 0, listen(fd, 64) == 0,
                fcntl(fd, F_SETFL, O_NONBLOCK) == 0
            else { throw MicropodError.message("Could not listen on the managed API socket") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setEventHandler { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { return }
                    do { try RuntimeUnixSocket.configureAccepted(client) } catch {
                        close(client)
                        continue
                    }
                    guard slots.wait(timeout: .now()) == .success else {
                        close(client)
                        continue
                    }
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        defer {
                            slots.signal()
                            close(client)
                        }
                        do { try serve(client) } catch {
                            // Tokens, headers, host paths and request bodies never enter logs.
                        }
                    }
                }
            }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        } catch {
            close(fd)
            throw error
        }
    }

    private func serve(_ client: Int32) throws {
        let peer = try RuntimeUnixSocket.peer(client)
        guard peer.uid == identity.ownerUID else { throw denied() }
        try RuntimeUnixSocket.timeout(client, seconds: 15)
        var prefix = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while prefix.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw denied() }
            prefix.append(contentsOf: buffer.prefix(count))
            guard prefix.count <= 65536 else { throw denied() }
        }
        guard let boundary = prefix.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: prefix[..<boundary.lowerBound], encoding: .utf8)
        else { throw denied() }
        let lines = head.components(separatedBy: "\r\n")
        let auth = lines.dropFirst().filter { $0.lowercased().hasPrefix("authorization:") }
        guard auth.count == 1 else { throw denied() }
        let value = auth[0].dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("Bearer ") else { throw denied() }
        let parts = value.dropFirst(7).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), parts[1].utf8.count == 43 else {
            throw denied()
        }
        let file = sessionsRoot.appendingPathComponent(id.uuidString + ".json")
        let record = try JSONDecoder().decode(
            IsolatedRuntimeAPISessionRecord.self,
            from: RuntimeDurableFile.read(file, maximumBytes: 4096, ownerUID: registryOwnerUID))
        guard record.accepts(token: String(parts[1]), peer: peer, instance: identity.instance),
            try RuntimeUnixSocket.peer(client) == peer
        else { throw denied() }
        let upstream = try RuntimeUnixSocket.connect(
            internalSocketPath, expectedUID: identity.serviceUID)
        defer { close(upstream) }
        // This server handles one request per connection. The private HTTP
        // parser rejects extra body bytes; no caller-provided credential is
        // copied into native requests, responses or diagnostics.
        let sanitized = lines.filter { !$0.lowercased().hasPrefix("authorization:") }.joined(separator: "\r\n")
        try RuntimeUnixSocket.write(Data((sanitized + "\r\n\r\n").utf8) + prefix[boundary.upperBound...], to: upstream)
        try RuntimeUnixSocket.timeout(client, seconds: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Self.copy(from: client, to: upstream)
            shutdown(upstream, SHUT_WR)
            group.leave()
        }
        Self.copy(from: upstream, to: client)
        // End the client read when the one-response upstream closes. The
        // handler's admission claim settles independently of this relay.
        shutdown(client, SHUT_RDWR)
        shutdown(upstream, SHUT_RDWR)
        group.wait()
    }
    private static func copy(from source: Int32, to destination: Int32) {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(source, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, (try? RuntimeUnixSocket.write(Data(bytes.prefix(count)), to: destination)) != nil else {
                return
            }
        }
    }
    private func denied() -> Error { MicropodError.message("The managed API client is not registered") }
}
