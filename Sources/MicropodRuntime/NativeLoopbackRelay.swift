import CPublishedTCP
import Foundation
import MicropodCore

/// Accept once on loopback. Each established stream stays with a single I/O owner.
final class NativeLoopbackRelay: @unchecked Sendable {
    private final class Backend: @unchecked Sendable {
        let handle: OpaquePointer

        init(guest: String, gateway: String?) throws {
            guard let handle = mp_tcp_relay_create(guest) else { throw NativeLoopbackRelay.posixError() }
            if let gateway, mp_tcp_relay_scope(handle, gateway) < 0 {
                let error = NativeLoopbackRelay.posixError()
                mp_tcp_relay_destroy(handle)
                throw error
            }
            self.handle = handle
        }

        deinit { mp_tcp_relay_destroy(handle) }
    }

    private final class Owner: @unchecked Sendable {
        let backend: Backend
        let queue: DispatchQueue
        let source: DispatchSourceRead

        init(guest: String, gateway: String?, name: String, dedicatedDataOwner: Bool = false) throws {
            let backend = try Backend(guest: guest, gateway: gateway)
            self.backend = backend
            queue = DispatchQueue(label: "dev.micropod.published-tcp." + name, qos: .userInitiated)
            source = DispatchSource.makeReadSource(
                fileDescriptor: mp_tcp_relay_descriptor(backend.handle), queue: queue)
            source.setEventHandler { mp_tcp_relay_drain(backend.handle, dedicatedDataOwner ? 1 : 0) }
            source.setCancelHandler { withExtendedLifetime(backend) {} }
            source.activate()
        }

        deinit { source.cancel() }
    }

    private final class Target: @unchecked Sendable {
        let owner: Owner
        let handle: OpaquePointer

        init(owner: Owner, parent: OpaquePointer) throws {
            self.owner = owner
            guard let handle = mp_tcp_target(owner.backend.handle, parent) else {
                throw NativeLoopbackRelay.posixError()
            }
            self.handle = handle
        }

        func adopt(_ fd: Int32, accepted: UInt64) {
            owner.queue.async { mp_tcp_adopt(self.handle, fd, accepted) }
        }

        func release() { owner.queue.sync { mp_tcp_release(handle, nil) } }
    }

    // The accept queue owns the port and issues every handoff in order.
    private final class Lease {
        let listener: OpaquePointer
        var targets: [Target] = []
        private var next = 0

        init(listener: OpaquePointer) { self.listener = listener }

        func adopt(_ fd: Int32, accepted: UInt64) {
            targets[next].adopt(fd, accepted: accepted)
            next = (next + 1) % targets.count
        }

        func release() -> mp_tcp_stats {
            // Accept cannot race this function. Each queue drains its previous
            // handoffs before its target closes. Only then can the port be reused.
            for target in targets { target.release() }
            var stats = mp_tcp_stats()
            mp_tcp_release(listener, &stats)
            return stats
        }
    }

    private let accept: Owner
    private let workers: [Owner]
    private let profile: Bool
    private var listeners: [UInt16: Lease] = [:]
    private var stopped = false

    private static func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }

    init(guest: String, gateway: String? = nil, parallel: Bool = true, profile: Bool = false) throws {
        accept = try Owner(guest: guest, gateway: parallel ? nil : gateway, name: "accept")
        workers = try (0..<(parallel ? 2 : 0)).map {
            try Owner(guest: guest, gateway: gateway, name: "io." + String($0), dedicatedDataOwner: true)
        }
        self.profile = profile
    }

    func takePathFailure() -> Bool { mp_tcp_take_path_failure(accept.backend.handle) != 0 }

    func bind(host: UInt16, guest: UInt16) throws -> UInt16 {
        try accept.queue.sync {
            guard !stopped else { throw POSIXError(.ECANCELED) }
            var selected: UInt16 = 0
            guard let listener = mp_tcp_listen(accept.backend.handle, host, guest, &selected, profile ? 1 : 0) else {
                throw Self.posixError()
            }
            let lease = Lease(listener: listener)
            do {
                for owner in workers { lease.targets.append(try Target(owner: owner, parent: listener)) }
            } catch {
                _ = lease.release()
                throw error
            }
            if !workers.isEmpty {
                mp_tcp_set_handoff(
                    listener,
                    { owner, fd, timestamp in
                        Unmanaged<Lease>.fromOpaque(owner!).takeUnretainedValue().adopt(fd, accepted: timestamp)
                    }, Unmanaged.passUnretained(lease).toOpaque())
            }
            listeners[selected] = lease
            return selected
        }
    }

    func release(_ port: UInt16) { accept.queue.sync { releaseOnQueue(port) } }

    func stop() {
        accept.queue.sync {
            stopped = true
            for port in Array(listeners.keys) { releaseOnQueue(port) }
        }
        accept.source.cancel()
        for worker in workers { worker.source.cancel() }
    }

    private func releaseOnQueue(_ port: UInt16) {
        guard let lease = listeners.removeValue(forKey: port) else { return }
        let stats = lease.release()
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
            "route_waits": stats.route_waits, "handshake_timeouts": stats.handshake_timeouts,
            "last_connect_errno": stats.last_connect_error, "recovered": stats.recovered,
            "peak_active": stats.peak_active,
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
