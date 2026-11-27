import Foundation
import MicropodCore

/// What the MCP tools need of `LocalAPI` beyond the transport.
extension LocalAPI {
    // MARK: Paths

    /// `raw` as one percent-encoded path segment. Ids come from the model:
    /// whitespace, control characters, `/`, `?` or `#` would rewrite the
    /// request line or the route, so such an id is refused, not encoded.
    static func pathSegment(_ raw: String, name: String) throws -> String {
        let refused = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/?#\\"))
        guard !raw.isEmpty, raw != ".", raw != "..", !raw.unicodeScalars.contains(where: refused.contains) else {
            throw MCPArgumentError(
                message: "\(name) \(String(reflecting: raw)) is not a valid id: it must be non-empty and contain "
                    + "no whitespace, control characters, '/', '\\', '?' or '#'")
        }
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    /// `ListRuntimes` → one line per engine.
    static func describe(_ response: Micropod_V1_ListRuntimesResponse) -> String {
        response.runtimes.map { r in
            let marker = r.default ? "*" : " "
            let available = r.available ? "available" : "unavailable: \(r.reason)"
            let enabled = r.enabled ? "enabled" : "disabled"
            return "\(marker) \(r.name)\t\(r.kind)\t\(available)\t\(enabled)\t\(r.endpoint)"
        }.joined(separator: "\n")
    }
}
