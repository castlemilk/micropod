import Darwin
import Foundation

/// Fixed root service and typed actions. There is no path, uid, command line,
/// package URL or administrator credential in the client protocol.
public struct IsolatedRuntimeClient: Sendable {
    public init() {}
    /// The root-owned authority first; the legacy SMAppService job only when
    /// the authority's service cannot be reached at all (not installed, or
    /// still waiting for the legacy helper to release the runtime).
    public func call(_ request: IsolatedRuntimeRequest) async throws -> IsolatedRuntimeStatus {
        var unreachable: Error?
        for service in IsolatedRuntimePolicy.clientServiceNames {
            do { return try await call(request, service: service) } catch let error as RuntimeHelperUnreachable {
                unreachable = error
            }
        }
        throw unreachable ?? RuntimeHelperUnreachable()
    }

    func call(_ request: IsolatedRuntimeRequest, service: String) async throws -> IsolatedRuntimeStatus {
        try Task.checkCancellation()
        let payload = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) let connection = xpc_connection_create_mach_service(
                service, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
            do {
                try RuntimeCodeIdentity.require(connection, identifiers: IsolatedRuntimePolicy.helperPeerIdentifiers)
            } catch {
                xpc_connection_cancel(connection)
                continuation.resume(throwing: error)
                return
            }
            let gate = RuntimeReplyOnce()
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            let message = xpc_dictionary_create_empty()
            payload.withUnsafeBytes { buffer in
                xpc_dictionary_set_data(message, "request", buffer.baseAddress!, buffer.count)
            }
            xpc_connection_send_message_with_reply(connection, message, nil) { reply in
                gate.finish {
                    defer { xpc_connection_cancel(connection) }
                    do {
                        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { throw RuntimeHelperUnreachable() }
                        guard xpc_connection_get_euid(connection) == 0 else {
                            throw MicropodError.message("The runtime helper is not running as root")
                        }
                        var count = 0
                        guard let bytes = xpc_dictionary_get_data(reply, "response", &count), count <= 65536 else {
                            throw MicropodError.message("The runtime helper returned an invalid response")
                        }
                        continuation.resume(
                            returning: try JSONDecoder().decode(
                                IsolatedRuntimeStatus.self, from: Data(bytes: bytes, count: count)))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                gate.finish {
                    xpc_connection_cancel(connection)
                    continuation.resume(
                        throwing: MicropodError.message(
                            "Runtime helper request timed out; check operation status before retrying"))
                }
            }
        }
    }
}

private final class RuntimeReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish(_ body: () -> Void) {
        let first = lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
        if first { body() }
    }
}

/// No root helper answered on a service: it is not installed, not loaded, or
/// exited before replying.
public struct RuntimeHelperUnreachable: LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? {
        "Micropod's runtime helper is not installed or not running; `sudo micropod runtime install-authority` installs it"
    }
}
