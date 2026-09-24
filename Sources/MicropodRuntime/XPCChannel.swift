import Foundation
import MicropodCore

/// Minimal XPC client for `com.apple.container.apiserver`.
///
/// This is a deliberately small re-implementation of the client half of
/// Apple's `ContainerXPC` module (Apache-2.0, apple/container). We port it
/// rather than link the `container` package for two reasons:
///
///   1. Dependency hygiene — `apple/container` pulls in Yams 6, which
///      conflicts with Micropod's Yams 5 pin, plus ArgumentParser and the
///      full command tree. The wire protocol is string routes + JSON
///      payloads; the client half is ~200 lines.
///   2. Stability — we only implement the routes we consume, gated at
///      runtime by the `ping` handshake.
///
/// The protocol (as of `container` 1.3.1): messages are `xpc_dictionary`s.
/// The route lives under `com.apple.container.xpc.route`; errors come back
/// under `com.apple.container.xpc.error` as JSON `{"code","message"}`.
/// File descriptors ride as XPC fd objects / fd arrays.
public struct XPCMessage: Sendable {
    static let routeKey = "com.apple.container.xpc.route"
    static let errorKey = "com.apple.container.xpc.error"

    private nonisolated(unsafe) let object: xpc_object_t
    private let lock = NSLock()
    private let isErr: Bool

    public var underlying: xpc_object_t {
        lock.withLock { object }
    }
    public var isErrorType: Bool { isErr }

    public init(object: xpc_object_t) {
        self.object = object
        self.isErr = xpc_get_type(object) == XPC_TYPE_ERROR
    }

    public init(route: String) {
        self.object = xpc_dictionary_create_empty()
        self.isErr = false
        xpc_dictionary_set_string(object, Self.routeKey, route)
    }
}

extension XPCMessage {
    /// Throws the server-decoded error payload, if present.
    public func error() throws {
        guard let data = data(key: Self.errorKey) else { return }
        struct WireError: Codable {
            let code: String
            let message: String
        }
        guard let item = try? JSONDecoder().decode(WireError.self, from: data) else {
            throw MicropodError.message("malformed error payload from container-apiserver")
        }
        throw MicropodError.message("\(item.code): \(item.message)")
    }

    public func errorKeyDescription() -> String? {
        guard isErr,
            let description = lock.withLock({
                xpc_dictionary_get_string(object, XPC_ERROR_KEY_DESCRIPTION)
            })
        else { return nil }
        return String(cString: description)
    }

    public func data(key: String) -> Data? {
        var length = 0
        guard
            let bytes = lock.withLock({
                xpc_dictionary_get_data(object, key, &length)
            })
        else { return nil }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
            count: length,
            deallocator: .none
        )
    }

    public func set(key: String, value: Data) {
        value.withUnsafeBytes { ptr in
            guard let addr = ptr.baseAddress else { return }
            lock.withLock {
                xpc_dictionary_set_data(object, key, addr, value.count)
            }
        }
    }

    public func string(key: String) -> String? {
        lock.withLock { xpc_dictionary_get_string(object, key) }.map { String(cString: $0) }
    }

    public func set(key: String, value: String) {
        lock.withLock { xpc_dictionary_set_string(object, key, value) }
    }

    public func bool(key: String) -> Bool {
        lock.withLock { xpc_dictionary_get_bool(object, key) }
    }

    public func set(key: String, value: Bool) {
        lock.withLock { xpc_dictionary_set_bool(object, key, value) }
    }

    public func uint64(key: String) -> UInt64 {
        lock.withLock { xpc_dictionary_get_uint64(object, key) }
    }

    public func set(key: String, value: UInt64) {
        lock.withLock { xpc_dictionary_set_uint64(object, key, value) }
    }

    public func int64(key: String) -> Int64 {
        lock.withLock { xpc_dictionary_get_int64(object, key) }
    }

    public func set(key: String, value: Int64) {
        lock.withLock { xpc_dictionary_set_int64(object, key, value) }
    }

    /// Receives an fd array (e.g. container log handles: [stdout, stderr]).
    public func fileHandles(key: String) -> [FileHandle]? {
        guard
            let fds = lock.withLock({
                xpc_dictionary_get_value(object, key)
            })
        else { return nil }
        let fd1 = xpc_array_dup_fd(fds, 0)
        let fd2 = xpc_array_dup_fd(fds, 1)
        guard fd1 >= 0, fd2 >= 0 else { return nil }
        return [
            FileHandle(fileDescriptor: fd1, closeOnDealloc: true),
            FileHandle(fileDescriptor: fd2, closeOnDealloc: true),
        ]
    }

    /// Receives a single fd (e.g. the vsock connection from `containerDial`).
    public func fileHandle(key: String) -> FileHandle? {
        guard
            let fd = lock.withLock({
                xpc_dictionary_get_value(object, key)
            })
        else { return nil }
        let dup = xpc_fd_dup(fd)
        guard dup >= 0 else { return nil }
        return FileHandle(fileDescriptor: dup, closeOnDealloc: true)
    }

    /// Sends a file descriptor. `xpc_fd_create` takes ownership of the
    /// descriptor, so we hand it a dup — the caller's FileHandle is untouched.
    public func set(key: String, value: FileHandle) throws {
        let dupFd = dup(value.fileDescriptor)
        guard dupFd >= 0, let xpcFd = xpc_fd_create(dupFd) else {
            if dupFd >= 0 { close(dupFd) }
            throw MicropodError.message("xpc_fd_create failed for fd \(value.fileDescriptor)")
        }
        lock.withLock {
            xpc_dictionary_set_value(object, key, xpcFd)
        }
    }
}

/// A persistent XPC connection to a launchd-registered mach service.
/// Requests are `send`-and-reply; each call is one XPC round trip.
public final class XPCConnection: Sendable {
    /// Service-registration timeout. Once apiserver is running, replies are
    /// milliseconds; launchd activation of a cold service can take seconds.
    public static let registrationTimeout: Duration = .seconds(60)

    private nonisolated(unsafe) let connection: xpc_connection_t
    private let service: String

    public init(service: String, queue: DispatchQueue? = nil) {
        self.service = service
        let connection = xpc_connection_create_mach_service(service, queue, 0)
        self.connection = connection
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, queue)
        xpc_connection_activate(connection)
    }

    deinit {
        xpc_connection_cancel(connection)
    }

    /// Sends a message and awaits the service's reply. Applies
    /// `responseTimeout` via a racing sleep task — the XPC reply itself is
    /// not cancellable, so a timed-out send may still complete server-side.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        try await withThrowingTaskGroup(of: XPCMessage.self, returning: XPCMessage.self) { group in
            if let responseTimeout {
                group.addTask {
                    try await Task.sleep(for: responseTimeout)
                    let route = message.string(key: XPCMessage.routeKey) ?? "?"
                    throw MicropodError.message("XPC timeout for \(self.service)/\(route)")
                }
            }
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                        do {
                            cont.resume(returning: try self.parseReply(reply))
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
            let response = try await group.next()
            group.cancelAll()
            try? await group.waitForAll()
            guard let response else {
                throw MicropodError.message("no XPC response from \(self.service)")
            }
            return response
        }
    }

    private func parseReply(_ reply: xpc_object_t) throws -> XPCMessage {
        let message = XPCMessage(object: reply)
        if message.isErrorType {
            let description = message.errorKeyDescription() ?? "unknown"
            throw MicropodError.message("XPC transport error from \(service): \(description)")
        }
        try message.error()
        return message
    }
}
