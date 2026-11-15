import Darwin
import Foundation
import MicropodCore
import Network

/// Retains the existing loopback API address while the native backend lives
/// in the service account. All requests cross the private admission gate.
enum IsolatedRuntimeProxy {
    static func forward(_ request: HTTPRequest, downstream: NWConnection) async {
        do {
            let identity = try IsolatedRuntimeIdentity.readRootOwned()
            let session = try await IsolatedRuntimeTransport.shared.session()
            let upstream = try RuntimeUnixSocket.connect(session.socketPath, expectedUID: identity.serviceUID)
            defer {
                close(upstream)
                downstream.cancel()
            }
            try RuntimeUnixSocket.timeout(upstream, seconds: 600)
            var components = URLComponents()
            components.queryItems = request.query.sorted(by: { $0.key < $1.key }).map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            let target = request.path + (request.query.isEmpty ? "" : "?" + (components.percentEncodedQuery ?? ""))
            let excluded: Set<String> = ["authorization", "content-length", "connection", "host"]
            var head =
                "\(request.method.rawValue) \(target) HTTP/1.1\r\nHost: localhost:45454\r\nConnection: close\r\nAuthorization: \(session.authorization)\r\nContent-Length: \(request.body.count)\r\n"
            for (key, value) in request.headers where !excluded.contains(key) {
                head += "\(key): \(value)\r\n"
            }
            try await write(Data((head + "\r\n").utf8) + request.body, fd: upstream)
            let input = Task { await forwardInput(downstream, fd: upstream) }
            do {
                while true {
                    let bytes = try await read(upstream)
                    if bytes.isEmpty { break }
                    let sent = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                        downstream.send(
                            content: bytes, completion: .contentProcessed { done.resume(returning: $0 == nil) })
                    }
                    if !sent { break }
                }
            } catch { /* An interrupted stream has no fabricated success response. */  }
            input.cancel()
            shutdown(upstream, SHUT_RDWR)
            downstream.cancel()
            await input.value
        } catch {
            let data = HTTPRequestFraming.errorResponse(
                status: 503, reason: "Managed runtime API unavailable; check runtime setup and maintenance")
            downstream.send(content: data, completion: .contentProcessed { _ in downstream.cancel() })
        }
    }
    private static func forwardInput(_ connection: NWConnection, fd: Int32) async {
        while !Task.isCancelled {
            let result = await withCheckedContinuation { (done: CheckedContinuation<(Data?, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, ended, error in
                    done.resume(returning: (data, ended || error != nil))
                }
            }
            if Task.isCancelled { return }
            if let bytes = result.0, !bytes.isEmpty {
                do { try await write(bytes, fd: fd) } catch { return }
            }
            if result.1 {
                shutdown(fd, SHUT_WR)
                return
            }
        }
    }
    private static func write(_ bytes: Data, fd: Int32) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try RuntimeUnixSocket.write(bytes, to: fd) })
            }
        }
    }
    private static func read(_ fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = [UInt8](repeating: 0, count: 65536)
                var count: Int
                repeat { count = Darwin.read(fd, &bytes, bytes.count) } while count < 0 && errno == EINTR
                if count < 0 {
                    done.resume(throwing: MicropodError.message("Managed API response was interrupted"))
                } else {
                    done.resume(returning: Data(bytes.prefix(count)))
                }
            }
        }
    }
}
