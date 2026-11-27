import Foundation

/// The client connection preface of HTTP/2 with prior knowledge (RFC 9113
/// §3.4): the 24 bytes `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, sent before any
/// frame. The API's listeners tell HTTP/2 from HTTP/1.1 by it, on the first
/// bytes of a connection only.
///
/// No HTTP/1.1 request starts with it: `PRI` is no method the API serves, and
/// a request line naming `HTTP/2.0` is refused with 505. The only HTTP/1.1
/// requests a partial preface could be the start of begin with `P`: `POST`,
/// `PUT` and `PATCH` differ from it at their second byte, so a classification
/// waits at most one byte for them.
enum HTTP2Preface {
    static let bytes = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    enum Classification: Equatable {
        /// Not the preface: HTTP/1.1 parses it as it always has.
        case mismatch
        /// Every byte so far is the preface's; read more before deciding.
        case partial
        /// The whole preface (and maybe frames after it).
        case match
    }

    static func classify(_ buffer: Data) -> Classification {
        let count = min(buffer.count, bytes.count)
        guard count > 0 else { return .partial }
        for offset in 0..<count
        where buffer[buffer.startIndex + offset] != bytes[bytes.startIndex + offset] {
            return .mismatch
        }
        return count == bytes.count ? .match : .partial
    }
}
