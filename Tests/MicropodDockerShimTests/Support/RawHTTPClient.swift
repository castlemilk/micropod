import Foundation

@testable import MicropodDockerShim

/// Minimal blocking TCP client for exercising the shim over raw sockets —
/// needed because URLSession cannot observe hijack framing, interim 100
/// responses, or connection-close semantics.
final class RawHTTPClient {
    let port: UInt16
    private var fd: Int32 = -1

    init(port: UInt16) {
        self.port = port
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private func connect() throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = POSIXError.Code(rawValue: errno) ?? .ECONNREFUSED
            Darwin.close(fd)
            fd = -1
            throw POSIXError(code)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    func writeRaw(_ data: Data) throws {
        if fd < 0 { try connect() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO) }
                sent += n
            }
        }
    }

    /// Reads until EOF or timeout; returns everything received.
    func readUntilClose(timeout: TimeInterval = 10) throws -> Data {
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let ready = poll(&pollFD, 1, 200)
            if ready > 0 {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { return received }
                received.append(contentsOf: buffer[0..<n])
            }
        }
        return received
    }

    /// Reads at least `minBytes` without waiting for close (hijack mode).
    func readAtLeast(_ minBytes: Int, timeout: TimeInterval = 10) throws -> Data {
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while received.count < minBytes && Date() < deadline {
            let ready = poll(&pollFD, 1, 200)
            if ready > 0 {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                received.append(contentsOf: buffer[0..<n])
            }
        }
        return received
    }

    /// Accumulates reads until `condition` is satisfied, EOF, or timeout.
    @discardableResult
    func readUntil(
        timeout: TimeInterval = 10, _ condition: (Data) -> Bool
    ) throws -> Data {
        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let ready = poll(&pollFD, 1, 200)
            if ready > 0 {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                received.append(contentsOf: buffer[0..<n])
                if condition(received) { break }
            }
        }
        return received
    }

    func request(
        _ method: String, _ path: String, body: Data? = nil,
        headers: [(String, String)] = [], timeout: TimeInterval = 15
    ) throws -> Response {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        try connect()
        var raw = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        for (key, value) in headers { raw += "\(key): \(value)\r\n" }
        if let body {
            raw += "Content-Length: \(body.count)\r\n"
        }
        raw += "\r\n"
        try writeRaw(Data(raw.utf8))
        if let body { try writeRaw(body) }
        let all = try readUntilClose(timeout: timeout)
        return try Self.parseResponse(all)
    }

    static func parseResponse(_ data: Data) throws -> Response {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw XCTFailure("no header terminator in \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw XCTFailure("empty response") }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw XCTFailure("bad status line: \(statusLine)")
        }
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        lines.removeAll()
        return Response(status: status, headers: headers, body: Data(data[headEnd.upperBound...]))
    }

    func connectForHijack() throws {
        if fd >= 0 { close() }
        try connect()
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

struct XCTFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Decodes one stdcopy frame ([type][0][0][lenBE32][payload]) from the front
/// of `data`; returns nil when incomplete.
func decodeFrame(_ data: Data) -> (type: UInt8, payload: Data, consumed: Int)? {
    guard data.count >= 8 else { return nil }
    let type = data[data.startIndex]
    let length =
        Int(data[data.startIndex + 4]) << 24 | Int(data[data.startIndex + 5]) << 16
        | Int(data[data.startIndex + 6]) << 8 | Int(data[data.startIndex + 7])
    guard data.count >= 8 + length else { return nil }
    let payloadStart = data.startIndex + 8
    let payload = data[payloadStart..<data.index(payloadStart, offsetBy: length)]
    return (type, Data(payload), 8 + length)
}
