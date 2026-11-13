import Darwin
import Foundation
import MicropodCore

/// Read-only proof and enrollment boundary for the signed rig agent. Only
/// the helper's lifecycle controller can mutate runtime state or its fence.
public final class IsolatedRuntimeRigServer: @unchecked Sendable {
    private let controller: IsolatedRuntimeHostController
    private var source: DispatchSourceRead?
    private let slots = DispatchSemaphore(value: 32)
    public init(controller: IsolatedRuntimeHostController) { self.controller = controller }
    public func start() throws {
        let path = IsolatedRuntimeRigCall.socketPath
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
                throw MicropodError.message("Runtime control socket has another owner")
            }
        } else if errno != ENOENT {
            throw MicropodError.message("Runtime control socket is unavailable")
        }
        let fd = try RuntimeUnixSocket.open()
        do {
            var address = try RuntimeUnixSocket.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o666) == 0, listen(fd, 32) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw MicropodError.message("Could not start runtime control socket")
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setCancelHandler { close(fd) }
            source.setEventHandler { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { return }
                    guard slots.wait(timeout: .now()) == .success else {
                        close(client)
                        continue
                    }
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            try RuntimeUnixSocket.timeout(client, seconds: 10)
                            let peer = try RuntimeUnixSocket.peer(client)
                            let identity = try IsolatedRuntimeIdentity.readRootOwned()
                            guard peer.uid == identity.ownerUID, authorized(peer) else { throw refused() }
                            var bytes = Data()
                            var part = [UInt8](repeating: 0, count: 1024)
                            while !bytes.contains(10) {
                                let count = Darwin.read(client, &part, part.count)
                                if count < 0, errno == EINTR { continue }
                                guard count > 0 else { throw refused() }
                                bytes.append(contentsOf: part.prefix(count))
                                guard bytes.count <= 4096 else { throw refused() }
                            }
                            let call = try JSONDecoder().decode(IsolatedRuntimeRigCall.self, from: bytes)
                            guard try RuntimeUnixSocket.peer(client) == peer, authorized(peer) else { throw refused() }
                            Task { [self] in
                                defer {
                                    close(client)
                                    slots.signal()
                                }
                                do {
                                    let proof = try await controller.rigProof(call, identity: identity)
                                    guard try RuntimeUnixSocket.peer(client) == peer, authorized(peer) else {
                                        throw refused()
                                    }
                                    try RuntimeUnixSocket.write(JSONEncoder().encode(proof) + Data([10]), to: client)
                                } catch { /* A missing proof always refuses permission. */  }
                            }
                        } catch {
                            close(client)
                            slots.signal()
                        }
                    }
                }
            }
            self.source = source
            source.resume()
        } catch {
            close(fd)
            throw error
        }
    }
    private func authorized(_ birth: RuntimeProcessBirth) -> Bool {
        ["cuttlefish-agent", "cuttlefish-agent-runtime"].contains {
            RuntimeCodeIdentity.verifyProcess(birth.pid, identifier: $0)
        }
    }
    private func refused() -> Error { MicropodError.message("The rig agent identity is unconfirmed") }
}
