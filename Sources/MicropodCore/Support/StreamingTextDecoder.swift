import Foundation

/// Preserves a UTF-8 scalar split across reads. Invalid sequences are replaced
/// only once they are complete or the source reaches EOF.
public struct StreamingUTF8Decoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(contentsOf: data)
        pending.removeAll(keepingCapacity: true)
        guard !bytes.isEmpty else { return "" }

        var lead = bytes.count - 1
        while lead > 0, bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
        let first = bytes[lead]
        let expected =
            first >= 0xC2 && first <= 0xDF
            ? 2
            : first >= 0xE0 && first <= 0xEF
                ? 3
                : first >= 0xF0 && first <= 0xF4 ? 4 : 1
        if expected > bytes.count - lead {
            pending = Array(bytes[lead...])
            bytes.removeSubrange(lead...)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: false) }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Plain-text terminal rendering with escape parser state carried across reads.
/// CSI, OSC, and single-character escape sequences never reach the renderer.
public struct StreamingANSITextFilter: Sendable {
    private enum State: Sendable { case text, escape, intermediate, csi, osc, oscEscape }
    private var state = State.text

    public init() {}

    public mutating func filter(_ text: String) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            switch state {
            case .text:
                if byte == 0x1B { state = .escape } else { result.append(byte) }
            case .escape:
                if byte == 0x5B {
                    state = .csi
                } else if byte == 0x5D {
                    state = .osc
                } else if byte >= 0x20 && byte <= 0x2F {
                    state = .intermediate
                } else {
                    state = .text
                }
            case .intermediate:
                if byte >= 0x30 && byte <= 0x7E { state = .text }
            case .csi:
                if byte >= 0x40 && byte <= 0x7E { state = .text }
            case .osc:
                if byte == 0x07 { state = .text } else if byte == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
