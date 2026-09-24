import Foundation
import MicropodCore
import Network

/// Byte-pump between a guest vsock fd and an `NWConnection`.
///
/// The MicropodAPI endpoint `GET /v1/containers/{id}/vsock/{port}` replies
/// `200` then hands the live connection here: whatever the HTTP client
/// writes goes into the guest socket, whatever the guest writes comes back.
/// That makes the HTTP response body a raw duplex stream — which a Go
/// caller wraps as a `net.Conn` and runs gRPC (vminitd) over.
public enum VsockBridge {
    /// Splices `connection` ↔ `vsock`'s fd until either side closes.
    /// Half-close aware: a client FIN half-closes the guest socket's write
    /// direction while reads continue.
    public static func attach(connection: NWConnection, vsock: FileHandle) async {
        let fd = vsock.fileDescriptor

        // conn → fd
        let writer = Task.detached {
            while true {
                let chunk = await Self.receive(connection)
                guard let chunk, !chunk.isEmpty else {
                    shutdown(fd, SHUT_WR)
                    return
                }
                do {
                    try Self.writeAll(fd, data: chunk)
                } catch {
                    return
                }
            }
        }

        // fd → conn
        let reader = Task.detached {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(fd, &buffer, buffer.count)
                guard n > 0 else {
                    connection.cancel()
                    return
                }
                let sent = await Self.send(connection, data: Data(buffer[0..<n]))
                if !sent { return }
            }
        }

        _ = await (writer.value, reader.value)
        try? vsock.close()
        connection.cancel()
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                data, _, isComplete, _ in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private static func send(_ connection: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    cont.resume(returning: error == nil)
                })
        }
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw MicropodError.message("vsock write failed: \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }
    }
}
