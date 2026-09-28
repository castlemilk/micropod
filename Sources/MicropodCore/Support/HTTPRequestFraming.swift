import Foundation

/// Binary-safe HTTP/1.1 request framing shared by Micropod's local servers
/// (MicropodAPI and the Docker shim).
///
/// Only the request head (request line + header fields, up to the first
/// CRLFCRLF) is ever decoded as text; the body is raw bytes, sized by
/// `Content-Length` or decoded from `Transfer-Encoding: chunked`. Decoding
/// the whole buffer as UTF-8 is wrong: a Connect envelope's length byte (a
/// 184-byte message starts `00 00 00 00 B8`) or a tar build context is not
/// valid UTF-8, and a parser that "waits for more bytes" on a decode failure
/// never answers.
///
/// Every outcome is explicit: `.incomplete` (read more), `.complete`, or
/// `.invalid` with the status a server should answer before closing — so
/// malformed or oversized input is refused instead of stalling a connection.
public enum HTTPRequestFraming {
    public struct Limits: Sendable, Equatable {
        /// Request line + header fields, excluding the final CRLFCRLF.
        public var maxHeaderBytes: Int
        /// Decoded body size (after chunked framing is removed).
        public var maxBodyBytes: Int

        public init(maxHeaderBytes: Int, maxBodyBytes: Int) {
            self.maxHeaderBytes = maxHeaderBytes
            self.maxBodyBytes = maxBodyBytes
        }

        /// MicropodAPI: JSON / Connect messages only.
        public static let api = Limits(maxHeaderBytes: 64 * 1024, maxBodyBytes: 64 * 1024 * 1024)
        /// Docker shim: build contexts and archive uploads can be large;
        /// registry auth/config headers can be sizeable too.
        public static let dockerShim = Limits(
            maxHeaderBytes: 1024 * 1024, maxBodyBytes: 512 * 1024 * 1024)
    }

    /// How the body is delimited, as declared by the head.
    public enum BodyFraming: Sendable, Equatable {
        case length(Int)
        case chunked
    }

    public struct Head: Sendable, Equatable {
        public var method: String
        /// Raw request target (path + optional `?query`), undecoded.
        public var target: String
        public var version: String
        /// Header fields in wire order, names as sent.
        public var fields: [(name: String, value: String)]
        /// Lowercased names; for repeated fields the last value wins.
        public var headers: [String: String]
        public var bodyFraming: BodyFraming
        /// Offset of the first body byte relative to the buffer start.
        public var bodyOffset: Int

        public static func == (lhs: Head, rhs: Head) -> Bool {
            lhs.method == rhs.method && lhs.target == rhs.target && lhs.version == rhs.version
                && lhs.headers == rhs.headers && lhs.bodyFraming == rhs.bodyFraming
                && lhs.bodyOffset == rhs.bodyOffset
                && lhs.fields.map(\.name) == rhs.fields.map(\.name)
                && lhs.fields.map(\.value) == rhs.fields.map(\.value)
        }
    }

    public enum HeadResult: Sendable, Equatable {
        case incomplete
        case head(Head)
        case invalid(status: Int, reason: String)
    }

    public enum Result: Sendable, Equatable {
        case incomplete
        /// `consumed`: bytes of the buffer this request occupied; anything
        /// after it belongs to the next (pipelined) request.
        case complete(head: Head, body: Data, consumed: Int)
        case invalid(status: Int, reason: String)
    }

    static let crlf = Data("\r\n".utf8)
    static let headTerminator = Data("\r\n\r\n".utf8)
    /// Longest chunk-size line (size + extensions) accepted.
    static let maxChunkLineBytes = 4096

    /// Parses the head only. `.incomplete` until CRLFCRLF arrives (or the
    /// header limit is exceeded).
    public static func parseHead(_ buffer: Data, limits: Limits) -> HeadResult {
        let start = buffer.startIndex
        // Search at most maxHeaderBytes + terminator so a flood of header
        // bytes costs O(limit), not O(buffer).
        let searchEnd = buffer.index(
            start, offsetBy: min(buffer.count, limits.maxHeaderBytes + headTerminator.count))
        guard let terminator = buffer.range(of: headTerminator, in: start..<searchEnd) else {
            if buffer.count > limits.maxHeaderBytes {
                return .invalid(status: 431, reason: "request header fields too large")
            }
            return .incomplete
        }
        let headBytes = buffer[start..<terminator.lowerBound]
        if headBytes.count > limits.maxHeaderBytes {
            return .invalid(status: 431, reason: "request header fields too large")
        }
        // Header text is ASCII by spec. Prefer UTF-8 (so a raw UTF-8 path
        // survives), fall back to Latin-1, which maps every byte — the head
        // never fails to decode.
        guard
            let text = String(data: headBytes, encoding: .utf8)
                ?? String(data: headBytes, encoding: .isoLatin1)
        else {
            return .invalid(status: 400, reason: "undecodable request head")
        }
        var lines = text.components(separatedBy: "\r\n")
        // RFC 9112 §2.2: ignore at least one empty line before the request line.
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        guard let requestLine = lines.first else {
            return .invalid(status: 400, reason: "missing request line")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            return .invalid(status: 400, reason: "malformed request line")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            return .invalid(status: 400, reason: "malformed method")
        }
        guard version.hasPrefix("HTTP/1.") else {
            return .invalid(status: 505, reason: "unsupported HTTP version \(version)")
        }

        var fields: [(name: String, value: String)] = []
        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, reason: "malformed header field")
            }
            let name = String(line[line.startIndex..<colon])
            // No whitespace between field name and colon (RFC 9112 §5.1):
            // a smuggling vector, refuse it. Obsolete line folding too.
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                return .invalid(status: 400, reason: "malformed header field name")
            }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(
                in: CharacterSet(charactersIn: " \t"))
            let key = name.lowercased()
            fields.append((name, value))
            headers[key] = value
            if key == "content-length" { contentLengths.append(value) }
        }

        let framing: BodyFraming
        if let transferEncoding = headers["transfer-encoding"] {
            let codings = transferEncoding.lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // Only `chunked` is supported, and it must be the final coding.
            guard codings.last == "chunked", codings.allSatisfy({ $0 == "chunked" || $0 == "identity" })
            else {
                return .invalid(status: 501, reason: "unsupported transfer-encoding \(transferEncoding)")
            }
            framing = .chunked
        } else if !contentLengths.isEmpty {
            // Repeated / list-valued Content-Length must all agree.
            let values = Set(
                contentLengths.flatMap { $0.split(separator: ",") }.map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
            guard values.count == 1, let raw = values.first, !raw.isEmpty,
                raw.allSatisfy({ $0.isASCII && $0.isNumber }), raw.count <= 18, let length = Int(raw)
            else {
                return .invalid(status: 400, reason: "invalid content-length")
            }
            if length > limits.maxBodyBytes {
                return .invalid(status: 413, reason: "request body exceeds \(limits.maxBodyBytes) bytes")
            }
            framing = .length(length)
        } else {
            framing = .length(0)
        }

        return .head(
            Head(
                method: method, target: target, version: version, fields: fields, headers: headers,
                bodyFraming: framing,
                bodyOffset: buffer.distance(from: start, to: terminator.upperBound)))
    }

    /// Parses one complete request from the front of `buffer`.
    public static func parse(_ buffer: Data, limits: Limits) -> Result {
        let head: Head
        switch parseHead(buffer, limits: limits) {
        case .incomplete: return .incomplete
        case .invalid(let status, let reason): return .invalid(status: status, reason: reason)
        case .head(let parsed): head = parsed
        }
        let bodyStart = buffer.index(buffer.startIndex, offsetBy: head.bodyOffset)
        switch head.bodyFraming {
        case .length(let length):
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else {
                return .incomplete
            }
            let end = buffer.index(bodyStart, offsetBy: length)
            return .complete(
                head: head, body: Data(buffer[bodyStart..<end]), consumed: head.bodyOffset + length)
        case .chunked:
            switch decodeChunked(buffer, from: bodyStart, maxBodyBytes: limits.maxBodyBytes) {
            case .incomplete: return .incomplete
            case .invalid(let status, let reason): return .invalid(status: status, reason: reason)
            case .complete(let body, let end):
                return .complete(
                    head: head, body: body, consumed: buffer.distance(from: buffer.startIndex, to: end))
            }
        }
    }

    public enum ChunkedResult: Sendable, Equatable {
        case incomplete
        case complete(body: Data, end: Data.Index)
        case invalid(status: Int, reason: String)
    }

    /// Decodes `Transfer-Encoding: chunked` framing starting at `start`:
    /// `size[;ext]CRLF data CRLF` … `0CRLF [trailer CRLF]* CRLF`.
    public static func decodeChunked(
        _ buffer: Data, from start: Data.Index, maxBodyBytes: Int
    ) -> ChunkedResult {
        var body = Data()
        var cursor = start
        while true {
            let lineSearchEnd = buffer.index(
                cursor,
                offsetBy: min(buffer.distance(from: cursor, to: buffer.endIndex), maxChunkLineBytes + 2))
            guard let lineEnd = buffer.range(of: crlf, in: cursor..<lineSearchEnd) else {
                if buffer.distance(from: cursor, to: buffer.endIndex) > maxChunkLineBytes {
                    return .invalid(status: 400, reason: "chunk size line too long")
                }
                return .incomplete
            }
            let line = buffer[cursor..<lineEnd.lowerBound]
            let sizeBytes = line.prefix { $0 != UInt8(ascii: ";") }
            let hex = sizeBytes.filter { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }
            guard !hex.isEmpty, hex.count <= 15, hex.allSatisfy(Self.isHexDigit),
                let size = Int(String(decoding: hex, as: UTF8.self), radix: 16)
            else {
                return .invalid(status: 400, reason: "malformed chunk size")
            }
            cursor = lineEnd.upperBound
            if size == 0 {
                // Trailer section: header lines until an empty line.
                var trailerBytes = 0
                while true {
                    guard let trailerEnd = buffer.range(of: crlf, in: cursor..<buffer.endIndex) else {
                        if buffer.distance(from: cursor, to: buffer.endIndex) + trailerBytes
                            > maxChunkLineBytes * 16
                        {
                            return .invalid(status: 431, reason: "chunked trailers too large")
                        }
                        return .incomplete
                    }
                    let trailerLength = buffer.distance(from: cursor, to: trailerEnd.lowerBound)
                    cursor = trailerEnd.upperBound
                    if trailerLength == 0 { return .complete(body: body, end: cursor) }
                    trailerBytes += trailerLength + 2
                    if trailerBytes > maxChunkLineBytes * 16 {
                        return .invalid(status: 431, reason: "chunked trailers too large")
                    }
                }
            }
            if body.count + size > maxBodyBytes {
                return .invalid(status: 413, reason: "request body exceeds \(maxBodyBytes) bytes")
            }
            let available = buffer.distance(from: cursor, to: buffer.endIndex)
            guard available >= size + 2 else {
                return .incomplete
            }
            let dataEnd = buffer.index(cursor, offsetBy: size)
            guard buffer[dataEnd] == UInt8(ascii: "\r"), buffer[buffer.index(after: dataEnd)] == UInt8(ascii: "\n")
            else {
                return .invalid(status: 400, reason: "chunk data not followed by CRLF")
            }
            body.append(buffer[cursor..<dataEnd])
            cursor = buffer.index(dataEnd, offsetBy: 2)
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// Standard reason phrase for the statuses this module produces.
    public static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 400: return "Bad Request"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 505: return "HTTP Version Not Supported"
        default: return "Error"
        }
    }

    /// A complete `Connection: close` error response (JSON body).
    public static func errorResponse(status: Int, reason: String) -> Data {
        let body =
            (try? JSONSerialization.data(withJSONObject: ["error": reason, "message": reason]))
            ?? Data()
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
