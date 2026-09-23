import Foundation
import MicropodCore
import Network

// MicropodAPI — a local HTTP/1.1 JSON API over the same service layer the
// desktop app and MCP server use. Docker-shaped routes where it makes sense:
//
//   GET  /health
//   GET  /v1/system                      status + disk usage
//   GET  /v1/containers                  list containers
//   POST /v1/containers                  run a container
//   POST /v1/containers/create           create without starting
//   POST /v1/containers/:id/{start,stop,restart,kill}
//   DELETE /v1/containers/:id
//   GET  /v1/containers/:id/logs?tail=N  SSE stream
//   GET  /v1/images                      list images
//   POST /v1/images/pull                 {reference}
//   DELETE /v1/images/:ref
//   GET  /v1/volumes                     list volumes
//   POST /v1/volumes                     create {name,size}
//   DELETE /v1/volumes/:name
//   GET  /v1/networks                    list networks
//   POST /v1/networks                    create {name,internal,subnet}
//   DELETE /v1/networks/:name
//   GET  /v1/stats                       latest resource snapshot
//   POST /v1/compose/up                  {path,profiles}
//   POST /v1/compose/down                {name}
//   POST /v1/exec                        {id,command,workdir,env}
//   POST /v1/system/update               trigger a background app update check (Sparkle)
//   GET  /v1/system/update               last-known updater status
//
// Environment: MICROPOD_API_PORT (default 45454), MICROPOD_CONTAINER_CLI_PATH.

@main
struct MicropodAPI {
    static func main() async {
        // When spawned by the app, die with it — no orphaned apiserver.
        ParentDeathWatch.install()

        let cliPath =
            ProcessInfo.processInfo.environment["MICROPOD_CONTAINER_CLI_PATH"]
            ?? "/usr/local/bin/container"
        let port = UInt16(ProcessInfo.processInfo.environment["MICROPOD_API_PORT"] ?? "45454") ?? 45454

        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: cliPath))
        let api = APIHandlers(
            client: client,
            system: SystemService(client: client),
            containers: ContainerService(client: client),
            images: ImageService(client: client),
            volumes: VolumeService(client: client),
            networks: NetworkService(client: client),
            stats: StatsSampler(client: client),
            logs: LogStreamer(client: client),
            compose: ComposeService(client: client))

        let server = HTTPServer(port: port, handler: api.handle)
        do {
            try await server.run()
            print("Micropod API listening on http://127.0.0.1:\(port) (cli: \(cliPath))")
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        } catch {
            fputs("API failed to start: \(error)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - HTTP plumbing

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

struct HTTPRequest {
    let method: HTTPMethod
    let path: String
    let query: [String: String]
    let body: Data

    func string(_ key: String) -> String { query[key] ?? "" }
}

enum HTTPResponse {
    case json(Int, [String: Any])
    case text(Int, String)
    case stream(Int, String, AsyncStream<Data>)
}

final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    let handler: (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func run() async throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            self.readRequest(connection, buffer: Data())
        }
        listener.start(queue: .global(qos: .userInitiated))
        // Serve until killed.
        try await Task.sleep(for: .seconds(3600 * 24 * 365))
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var newBuffer = buffer
                newBuffer.append(data)
                if let request = HTTPParser.parse(newBuffer) {
                    self.dispatch(request, connection: connection)
                    return
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.readRequest(connection, buffer: newBuffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func dispatch(_ request: HTTPRequest, connection: NWConnection) {
        Task {
            let response = await handler(request)
            switch response {
            case .stream(let status, let contentType, let events):
                // SSE: write the head without Content-Length, then stream
                // each event on the live connection, closing when done.
                let head = Self.streamHead(status: status, contentType: contentType)
                connection.send(
                    content: head,
                    completion: .contentProcessed { _ in
                        Task {
                            for await chunk in events {
                                connection.send(content: chunk, completion: .contentProcessed { _ in })
                            }
                            connection.cancel()
                        }
                    })
            default:
                let data = Self.serialize(response)
                connection.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }
    }

    static func streamHead(status: Int, contentType: String) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonLine(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    static func serialize(_ response: HTTPResponse) -> Data {
        let statusLine: String
        var headers: [(String, String)] = []
        var body: Data = Data()

        switch response {
        case .json(let status, let object):
            statusLine = reasonLine(for: status)
            headers.append(("Content-Type", "application/json"))
            body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        case .text(let status, let text):
            statusLine = reasonLine(for: status)
            headers.append(("Content-Type", "text/plain"))
            body = Data(text.utf8)
        case .stream:
            // Streams are written via streamHead + live chunks; this path is
            // unreachable for well-formed responses.
            return Data()
        }

        var head = "\(statusLine)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reasonLine(for status: Int) -> String {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 500: reason = "Internal Server Error"
        default: reason = "Unknown"
        }
        return "HTTP/1.1 \(status) \(reason)"
    }
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 3, let method = HTTPMethod(rawValue: String(parts[0])) else { return nil }
        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1)
        let path = String(targetParts[0])
        var query: [String: String] = [:]
        if targetParts.count > 1 {
            for pair in targetParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                query[String(kv[0])] = kv.count > 1 ? String(kv[1]).removingPercentEncoding ?? String(kv[1]) : ""
            }
        }

        var contentLength = 0
        var headerDone = false
        var bodyStart = 0
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                headerDone = true
                bodyStart = index + 1
                break
            }
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard headerDone else { return nil }
        let bodyText = lines.dropFirst(bodyStart).joined(separator: "\r\n")
        let body = Data(bodyText.utf8)
        guard body.count >= contentLength else { return nil }
        return HTTPRequest(method: method, path: path, query: query, body: body)
    }
}
