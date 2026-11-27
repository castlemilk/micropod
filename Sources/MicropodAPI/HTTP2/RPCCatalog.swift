import Foundation

/// How an RPC streams, as proto/ declares it.
enum RPCKind: Sendable, Equatable {
    case unary, serverStream, clientStream, bidiStream
}

/// Every service and method proto/micropod/v1 declares
/// (`RPCCatalog.generated.swift`, from `scripts/gen_rpc_catalog.py`): what a
/// gRPC call may name, and whether it streams. A gRPC request carries no
/// hint of its own (Connect clients send `application/connect+…` for
/// streams); the catalog is that hint.
enum RPCCatalog {
    /// `/micropod.v1.ContainerService/ListContainers` → its service and method.
    static func route(_ path: String) -> (service: String, method: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    static func kind(service: String, method: String) -> RPCKind? { services[service]?[method] }
}
