import Darwin
import Foundation
import MicropodCore

/// The dedicated runtime's API reached from an HTTP/2 stream. HTTP/1.1
/// relays (`IsolatedRuntimeProxy.forward`) copy the upstream's bytes onto
/// the client's connection as they are; an HTTP/2 stream has no raw bytes
/// to hand over, so `forwardParsed` sends the same request upstream (over
/// HTTP/1.1, `Connection: close`) and reads the answer back as a response:
/// a complete one (Content-Length) or a stream delimited by the close.
extension IsolatedRuntimeProxy {
    static func forwardParsed(_ request: HTTPRequest) async -> HTTPResponse {
        await forwardParsed(request) {
            let identity = try IsolatedRuntimeIdentity.readRootOwned()
            let session = try await IsolatedRuntimeTransport.shared.session()
            let fd = try RuntimeUnixSocket.connect(session.socketPath, expectedUID: identity.serviceUID)
            return (fd, session.authorization)
        }
    }

    /// `upstream`: a connected socket to the dedicated runtime's API and the
    /// capability its gateway checks.
    static func forwardParsed(
        _ request: HTTPRequest, upstream: () async throws -> (fd: Int32, authorization: String)
    ) async -> HTTPResponse {
        let unavailable = HTTPResponse.json(
            503,
            [
                "code": "unavailable",
                "message": "Managed runtime API unavailable; check runtime setup and maintenance",
            ])
        let fd: Int32
        do {
            let connection = try await upstream()
            fd = connection.fd
            try RuntimeUnixSocket.timeout(fd, seconds: 600)
            try await relayWrite(head(request, authorization: connection.authorization) + request.body, fd: fd)
        } catch {
            return unavailable
        }
        var reader = HTTP1ResponseReader()
        do {
            while reader.head == nil {
                let bytes = try await relayRead(fd)
                guard !bytes.isEmpty else { break }
                try reader.feed(bytes)
            }
            guard let head = reader.head else {
                close(fd)
                return unavailable
            }
            if let length = head.contentLength {
                while reader.body.count < length {
                    let bytes = try await relayRead(fd)
                    guard !bytes.isEmpty else { break }
                    try reader.feed(bytes)
                }
                close(fd)
                guard reader.body.count >= length else { return unavailable }
                return .data(head.status, head.contentType, Data(reader.body.prefix(length)))
            }
            let first = reader.body
            let socket = RelaySocket(fd)
            return .stream(
                head.status, head.contentType,
                AsyncStream { continuation in
                    let pump = Task {
                        if !first.isEmpty { continuation.yield(first) }
                        while !Task.isCancelled, let bytes = try? await relayRead(fd), !bytes.isEmpty {
                            continuation.yield(bytes)
                        }
                        continuation.finish()
                        socket.close()
                    }
                    continuation.onTermination = { _ in
                        pump.cancel()
                        socket.shutdown()
                    }
                })
        } catch {
            close(fd)
            return unavailable
        }
    }

    /// The upstream request head, as `forward` writes it.
    static func head(_ request: HTTPRequest, authorization: String) -> Data {
        var components = URLComponents()
        components.queryItems = request.query.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        let target = request.path + (request.query.isEmpty ? "" : "?" + (components.percentEncodedQuery ?? ""))
        let excluded: Set<String> = ["authorization", "content-length", "connection", "host", "te"]
        var head =
            "\(request.method.rawValue) \(target) HTTP/1.1\r\nHost: localhost:45454\r\nConnection: close\r\n"
            + "Authorization: \(authorization)\r\nContent-Length: \(request.body.count)\r\n"
        for (key, value) in request.headers.sorted(by: { $0.key < $1.key }) where !excluded.contains(key) {
            head += "\(key): \(value)\r\n"
        }
        return Data((head + "\r\n").utf8)
    }

    private static func relayWrite(_ bytes: Data, fd: Int32) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(with: Result { try RuntimeUnixSocket.write(bytes, to: fd) })
            }
        }
    }

    private static func relayRead(_ fd: Int32) async throws -> Data {
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

/// A relayed stream's socket: shut down to stop a read in flight, closed
/// once (by the pump, after its last read).
private final class RelaySocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func shutdown() { lock.withLock { if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) } } }
    func close() {
        lock.withLock {
            if fd >= 0 { _ = Darwin.close(fd) }
            fd = -1
        }
    }
}

/// An HTTP/1.1 response head and what followed it, from bytes as they come.
struct HTTP1ResponseReader {
    struct Head: Equatable {
        let status: Int
        let contentType: String
        /// Nil: the body runs to the close.
        let contentLength: Int?
    }

    struct Malformed: Error {}

    private var buffer = Data()
    private(set) var head: Head?
    private(set) var body = Data()
    /// The most a head may hold.
    static let maxHeadBytes = 64 * 1024

    mutating func feed(_ bytes: Data) throws {
        guard head == nil else {
            body.append(bytes)
            return
        }
        buffer.append(bytes)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeadBytes { throw Malformed() }
            return
        }
        let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
            throw Malformed()
        }
        var fields: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["transfer-encoding"] == nil else { throw Malformed() }
        let length = try fields["content-length"].map { value -> Int in
            guard let length = Int(value), length >= 0 else { throw Malformed() }
            return length
        }
        head = Head(
            status: status, contentType: fields["content-type"] ?? "application/octet-stream", contentLength: length)
        body = Data(buffer[end.upperBound...])
        buffer = Data()
    }
}
