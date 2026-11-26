import Foundation
import MicropodCore
import XCTest

@testable import MicropodMCP

/// An MCP server wired to a fake API daemon and, for the CLI fallback, to
/// `cli` — by default `/usr/bin/false`.
enum MCPTestServer {
    static func make(
        socketPath: String?, tcpPort: Int = 1, socketTimeoutSeconds: Int = 5, longCallSeconds: Int? = nil,
        cli: URL = URL(fileURLWithPath: "/usr/bin/false")
    ) -> MCPServer {
        let client = ContainerCLIClient(executableURL: cli)
        let api = LocalAPI(
            socketPath: socketPath, baseURL: URL(string: "http://127.0.0.1:\(tcpPort)")!,
            socketTimeoutSeconds: socketTimeoutSeconds, httpTimeout: 5,
            longCallSeconds: longCallSeconds ?? socketTimeoutSeconds)
        return MCPServer(
            client: client,
            system: SystemService(client: client, installedVersion: { _ in nil }),
            containers: ContainerService(client: client),
            images: ImageService(client: client),
            volumes: VolumeService(client: client),
            networks: NetworkService(client: client),
            statsSampler: StatsSampler(client: client),
            logStreamer: LogStreamer(client: client),
            compose: ComposeService(client: client),
            sharedFS: nil,
            api: api)
    }

    struct ToolReply {
        var text: String
        var isError: Bool
    }

    static func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) async throws -> ToolReply {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let handled = await server.handle(line: line)
        let reply = try XCTUnwrap(handled)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any], "\(object)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return ToolReply(
            text: content.compactMap { $0["text"] as? String }.joined(), isError: result["isError"] as? Bool ?? false)
    }

    static func rpc(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any]
    {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 9, "method": method, "params": params]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let handled = await server.handle(line: line)
        let reply = try XCTUnwrap(handled)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }
}
