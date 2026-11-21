import CPublishedTCP
import Foundation
import MicropodCore

/// One readiness queue serves every published TCP lease on this worker.
final class NativeLoopbackRelay: @unchecked Sendable {
    private final class Backend: @unchecked Sendable {
        let handle: OpaquePointer

        init(guest: String) throws {
            guard let handle = mp_tcp_relay_create(guest) else { throw Self.posixError() }
            self.handle = handle
        }

        static func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }

        deinit { mp_tcp_relay_destroy(handle) }
    }

    private let backend: Backend
    private let queue = DispatchQueue(label: "dev.micropod.published-tcp", qos: .userInitiated)
    private let source: DispatchSourceRead
    private let profile: Bool
    // Touched only on queue, including synchronous revocation.
    private var listeners: [UInt16: OpaquePointer] = [:]
    private var stopped = false

    init(guest: String, profile: Bool = false) throws {
        let backend = try Backend(guest: guest)
        self.backend = backend
        self.profile = profile
        source = DispatchSource.makeReadSource(fileDescriptor: mp_tcp_relay_descriptor(backend.handle), queue: queue)
        source.setEventHandler { mp_tcp_relay_drain(backend.handle) }
        // The descriptor must stay open until libdispatch removes its watch.
        source.setCancelHandler { withExtendedLifetime(backend) {} }
        source.activate()
    }

    func bind(host: UInt16, guest: UInt16) throws -> UInt16 {
        try queue.sync {
            guard !stopped else { throw POSIXError(.ECANCELED) }
            var selected: UInt16 = 0
            guard let listener = mp_tcp_listen(backend.handle, host, guest, &selected, profile ? 1 : 0) else {
                throw Backend.posixError()
            }
            listeners[selected] = listener
            return selected
        }
    }

    func release(_ port: UInt16) {
        queue.sync { releaseOnQueue(port) }
    }

    func stop() {
        queue.sync {
            stopped = true
            for port in Array(listeners.keys) { releaseOnQueue(port) }
        }
        source.cancel()
    }

    private func releaseOnQueue(_ port: UInt16) {
        guard let listener = listeners.removeValue(forKey: port) else { return }
        var stats = mp_tcp_stats()
        mp_tcp_release(listener, &stats)
        guard profile else {
            if stats.connect_retries > 0 {
                SecretSource.stderrLog(
                    "published TCP port \(port) retried \(stats.connect_retries) guest handshakes, recovered \(stats.recovered)"
                )
            }
            return
        }
        func buckets<T>(_ tuple: T) -> [UInt64] {
            withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: UInt64.self)) }
        }
        let event: [String: Any] = [
            "port": port, "accepted": stats.accepted, "connected": stats.connected,
            "connect_errors": stats.connect_errors, "connect_retries": stats.connect_retries,
            "recovered": stats.recovered, "peak_active": stats.peak_active,
            "upload_bytes": stats.upload_bytes, "download_bytes": stats.download_bytes,
            "reads": stats.reads, "writes": stats.writes, "blocked_writes": stats.blocked_writes,
            "bulk_directions": stats.bulk_directions,
            "accept_to_connect_us": buckets(stats.connect_us),
            "connect_to_first_guest_byte_us": buckets(stats.first_byte_us),
            "connect_to_first_request_write_us": buckets(stats.first_request_write_us),
            "first_request_write_to_guest_byte_us": buckets(stats.request_to_first_guest_byte_us),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
            SecretSource.stderrLog("published TCP profile " + String(decoding: data, as: UTF8.self))
        }
    }

    deinit { stop() }
}
