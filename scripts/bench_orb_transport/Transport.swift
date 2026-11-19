import Foundation

// Benchmark driver for the production DockerClient. The "micropod" comparison
// runs the complete CLI separately. This driver measures only its HTTP transport.
@main
struct Transport {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 || args.count == 5 else { throw CocoaError(.coderInvalidValue) }
        let client = DockerClient(endpoint: try DockerClient.Endpoint.parse(args[0]))
        let name = args[2]
        switch args[1] {
        case "run":
            guard args.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let nonce = args[3]
            let body: [String: Any] = [
                "Image": args[4], "Cmd": ["sh", "-c", "echo out-\(nonce); echo err-\(nonce) >&2; exit 23"],
                "Labels": ["micropod.bench": nonce],
                "HostConfig": ["NanoCpus": 1000000000, "Memory": 64 << 20, "NetworkMode": "none"] as [String: Any],
            ]
            try client.check(try await client.request("POST", "/containers/create", query: ["name": name], json: body))
            try client.check(try await client.request("POST", "/containers/\(name)/start"))
        case "rm":
            try client.check(try await client.request("DELETE", "/containers/\(name)", query: ["force": "1"]))
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }
}
