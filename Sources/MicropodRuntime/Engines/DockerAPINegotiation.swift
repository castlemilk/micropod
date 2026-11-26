import Foundation
import MicropodCore

/// The unversioned handshake precedes any mutating request. Concurrent users
/// of the same client share its answer. A failed handshake can be retried.
final class DockerAPINegotiation: @unchecked Sendable {
    private let condition = NSCondition()
    private var loading = false
    private var cached: String?

    static func minor(_ version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "1", !parts[1].isEmpty,
            parts[1].utf8.allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return Int(parts[1])
    }

    func version(_ endpoint: DockerClient.Endpoint, cancellation: SocketBox?) throws -> String {
        let answer: String? = try condition.withLock {
            while loading {
                try cancellation?.checkCancellation()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
            try cancellation?.checkCancellation()
            if let cached { return cached }
            loading = true
            return nil
        }
        if let answer { return answer }
        let result = Result { try negotiate(endpoint, cancellation: cancellation) }
        condition.withLock {
            if case .success(let version) = result { cached = version }
            loading = false
            condition.broadcast()
        }
        return try result.get()
    }

    private func negotiate(_ endpoint: DockerClient.Endpoint, cancellation: SocketBox?) throws -> String {
        let socket = try Socket.connect(endpoint, timeout: .seconds(3), cancellation: cancellation)
        cancellation?.set(socket)
        defer {
            if let cancellation { cancellation.close() } else { socket.close() }
        }
        try cancellation?.checkCancellation()
        let head = DockerClient.head("GET", "/version", query: [:], bodyLength: nil, apiVersion: "")
        try socket.write(Data(head.utf8))
        var reader = HTTPReader(socket: socket)
        let (status, headers) = try reader.readHead()
        if status == 404 {
            // Preserve existing engines that only implement versioned routes.
            return DockerClient.defaultAPIVersion
        }
        let body = try reader.readBody(headers: headers, limit: 1_048_576)
        let response = DockerClient.Response(status: status, body: body)
        guard status == 200 else { throw DockerClient.error(status: status, response.message) }
        guard let info = try response.json() as? [String: Any],
            let upper = (info["ApiVersion"] as? String).flatMap(Self.minor)
        else { throw MicropodError.message("internal: docker: missing or invalid ApiVersion") }
        let minimum = info["MinAPIVersion"] as? String ?? "1.0"
        guard let lower = Self.minor(minimum) else {
            throw MicropodError.message("internal: docker: invalid MinAPIVersion")
        }
        // The implemented operations are qualified for Docker API 1.43–1.47.
        let chosen = min(47, upper)
        guard chosen >= max(43, lower) else {
            throw MicropodError.unsupported("docker API range \(minimum)–1.\(upper) has no overlap with 1.43–1.47")
        }
        return "v1.\(chosen)"
    }

    func invalidate() {
        condition.withLock { cached = nil }
    }
}
