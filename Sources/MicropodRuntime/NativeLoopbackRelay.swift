import CPublishedTCP
import Foundation
import Network

/// Accept once on loopback. Each established stream stays with a single I/O owner.
final class NativeLoopbackRelay: @unchecked Sendable {
    private final class Backend: @unchecked Sendable {
        let handle: OpaquePointer

        init(guest: String, gateway: String?, dedicatedDataOwner: Bool) throws {
            let handle = dedicatedDataOwner ? mp_tcp_relay_create_data(guest) : mp_tcp_relay_create(guest)
            guard let handle else { throw NativeLoopbackRelay.posixError() }
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

        init(
            guest: String, gateway: String?, name: String, dataWorkers: Int = 0,
            boundedGuestWindow: Bool = false
        ) throws {
            let backend = try Backend(guest: guest, gateway: gateway, dedicatedDataOwner: dataWorkers > 0)
            if boundedGuestWindow { mp_tcp_relay_bound_guest_window(backend.handle) }
            self.backend = backend
            queue = DispatchQueue(label: "dev.micropod.published-tcp." + name, qos: .userInitiated)
            source = DispatchSource.makeReadSource(
                fileDescriptor: mp_tcp_relay_descriptor(backend.handle), queue: queue)
            source.setEventHandler { mp_tcp_relay_drain(backend.handle, Int32(dataWorkers)) }
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
            mp_tcp_handoff_enqueue(handle, fd, accepted)
        }

        func adoptProfiled(_ fd: Int32, accepted: UInt64) {
            let enqueued = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            mp_tcp_handoff_enqueue_profiled(handle, fd, accepted, enqueued)
        }

        func release(profile: Bool) -> mp_tcp_handoff_stats? {
            owner.queue.sync {
                guard profile else {
                    mp_tcp_release(handle, nil)
                    return nil
                }
                var stats = mp_tcp_stats()
                mp_tcp_release(handle, &stats)
                return stats.handoff
            }
        }
    }

    // The accept queue owns the port and issues every handoff in order.
    private final class Lease {
        let listener: OpaquePointer
        let guestPort: UInt16
        var targets: [Target] = []

        init(listener: OpaquePointer, guestPort: UInt16) {
            self.listener = listener
            self.guestPort = guestPort
        }

        static func nextTarget(_ context: UnsafeMutableRawPointer?) -> Target {
            let lease = Unmanaged<Lease>.fromOpaque(context!).takeUnretainedValue()
            let index = mp_tcp_next_worker(lease.listener, UInt32(lease.targets.count))
            return lease.targets[Int(index)]
        }

        func release(profile: Bool = false) -> (mp_tcp_stats, [mp_tcp_handoff_stats]) {
            // Accept cannot race this function. Each queue drains its previous
            // handoffs before its target closes. Only then can the port be reused.
            let owners = targets.compactMap { $0.release(profile: profile) }
            var stats = mp_tcp_stats()
            mp_tcp_release(listener, &stats)
            return (stats, owners)
        }
    }

    private let accept: Owner
    private let workers: [Owner]
    var dataWorkerCount: Int { workers.count }
    var dataCallbackEvents: Int? {
        workers.isEmpty ? nil : Int(mp_tcp_data_callback_events(Int32(workers.count)))
    }
    var readBytes: Int? {
        guard let first = workers.first else { return Int(mp_tcp_relay_read_bytes(accept.backend.handle)) }
        let bytes = mp_tcp_relay_read_bytes(first.backend.handle)
        return workers.dropFirst().allSatisfy { mp_tcp_relay_read_bytes($0.backend.handle) == bytes } ? Int(bytes) : nil
    }
    private let profile: Bool
    private let guest: String
    private let gateway: String?
    // Owned by the accept queue. A profiled worker checks its own path once after a dial failure.
    private var checkedLocalNetwork = false
    private var localNetworkProbe: NWConnection?
    private var listeners: [UInt16: Lease] = [:]
    private var pending = Set<UInt16>()
    private var stopped = false

    private static func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }

    init(
        guest: String, gateway: String? = nil, dataWorkers: Int = 2, boundedGuestWindow: Bool = false,
        profile: Bool = false
    ) throws {
        guard dataWorkers == 0 || CIWorkerPortRelay.parallelWorkers.contains(dataWorkers) else {
            throw POSIXError(.EINVAL)
        }
        accept = try Owner(guest: guest, gateway: dataWorkers > 0 ? nil : gateway, name: "accept")
        workers = try (0..<dataWorkers).map {
            try Owner(
                guest: guest, gateway: gateway, name: "io." + String($0), dataWorkers: dataWorkers,
                boundedGuestWindow: boundedGuestWindow)
        }
        self.profile = profile
        self.guest = guest
        self.gateway = gateway
    }

    func takePathFailure() -> Bool {
        guard mp_tcp_take_path_failure(accept.backend.handle) != 0 else { return false }
        if profile, let gateway {
            accept.queue.async { self.checkLocalNetwork(gateway: gateway) }
        }
        return true
    }

    static func localNetworkOutcome(_ state: NWConnection.State, reason: NWPath.UnsatisfiedReason?) -> String? {
        switch state {
        case .waiting where reason == .localNetworkDenied: return "local-network-denied"
        case .ready: return "ready"
        case .failed(let error): return "failed(\(error))"
        default: return nil
        }
    }

    private func checkLocalNetwork(gateway: String) {
        guard !stopped, !checkedLocalNetwork else { return }
        checkedLocalNetwork = true
        // A connected UDP path evaluates local network privacy in the relay process.
        // It uses the private gateway source address and sends no application datagrams.
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(gateway), port: .any)
        let probe = NWConnection(host: .init(guest), port: 9, using: parameters)
        localNetworkProbe = probe
        probe.stateUpdateHandler = { [weak self] state in
            guard let self, let probe = self.localNetworkProbe,
                let outcome = Self.localNetworkOutcome(state, reason: probe.currentPath?.unsatisfiedReason)
            else { return }
            self.finishLocalNetworkProbe(outcome)
        }
        probe.start(queue: accept.queue)
        accept.queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self, let probe = self.localNetworkProbe else { return }
            self.finishLocalNetworkProbe(
                Self.localNetworkOutcome(probe.state, reason: probe.currentPath?.unsatisfiedReason) ?? "unresolved")
        }
    }

    private func finishLocalNetworkProbe(_ outcome: String) {
        localNetworkProbe?.cancel()
        localNetworkProbe = nil
        SecretSource.stderrLog("published TCP local network diagnostic guest=\(guest) udp_path=\(outcome)")
    }

    func takeGuestTraffic() -> Bool {
        var received = mp_tcp_take_guest_data(accept.backend.handle) != 0
        for worker in workers {
            if mp_tcp_take_guest_data(worker.backend.handle) != 0 { received = true }
        }
        return received
    }

    func bind(host: UInt16, guest: UInt16) throws -> UInt16 {
        try accept.queue.sync {
            guard !stopped else { throw POSIXError(.ECANCELED) }
            var selected: UInt16 = 0
            guard let listener = mp_tcp_listen(accept.backend.handle, host, guest, &selected, profile ? 1 : 0) else {
                throw Self.posixError()
            }
            let lease = Lease(listener: listener, guestPort: guest)
            do {
                for owner in workers { lease.targets.append(try Target(owner: owner, parent: listener)) }
            } catch {
                _ = lease.release()
                throw error
            }
            if !workers.isEmpty {
                let handler: mp_tcp_handoff
                if profile {
                    handler = { owner, fd, accepted in Lease.nextTarget(owner).adoptProfiled(fd, accepted: accepted) }
                } else {
                    handler = { owner, fd, accepted in Lease.nextTarget(owner).adopt(fd, accepted: accepted) }
                }
                mp_tcp_set_handoff(listener, handler, Unmanaged.passUnretained(lease).toOpaque())
            }
            listeners[selected] = lease
            return selected
        }
    }

    // Register an intent before the guest can send a bind request. A fence
    // on a second control connection must also see a delayed bind in flight.
    func prepare(guest port: UInt16) -> Bool {
        accept.queue.sync {
            !stopped && !listeners.values.contains { $0.guestPort == port } && pending.insert(port).inserted
        }
    }

    func finishPreparation(guest port: UInt16) { accept.queue.sync { _ = pending.remove(port) } }

    // The accept queue retires the targets before it answers this fence.
    func hasReleased(guest port: UInt16) -> Bool {
        accept.queue.sync { !pending.contains(port) && !listeners.values.contains { $0.guestPort == port } }
    }

    func release(_ port: UInt16) { accept.queue.sync { releaseOnQueue(port) } }

    func stop() {
        accept.queue.sync {
            stopped = true
            localNetworkProbe?.cancel()
            localNetworkProbe = nil
            for port in Array(listeners.keys) { releaseOnQueue(port) }
        }
        accept.source.cancel()
        for worker in workers { worker.source.cancel() }
    }

    private func releaseOnQueue(_ port: UInt16) {
        guard let lease = listeners.removeValue(forKey: port) else { return }
        let (stats, owners) = lease.release(profile: profile)
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
        func handoffBuckets(_ sample: mp_tcp_handoff_stats) -> [String: [UInt64]] {
            [
                "accept_to_enqueue_us": buckets(sample.accept_to_enqueue_us),
                "enqueue_to_adopt_us": buckets(sample.enqueue_to_adopt_us),
                "accept_to_adopt_us": buckets(sample.accept_to_adopt_us),
            ]
        }
        let guestReadSupply: [String: Any] = [
            "read_cap_bytes": readBytes as Any, "bytes": stats.guest_read_bytes,
            "le_128_kib": stats.guest_reads_by_size.0, "gt_128_lt_256_kib": stats.guest_reads_by_size.1,
            "eq_256_kib": stats.guest_reads_by_size.2, "gt_256_kib": stats.guest_reads_by_size.3,
            "full_cap_reads": stats.guest_full_cap_reads,
            "full_cap_with_ready_hint_above_cap": stats.guest_full_cap_ready_above_cap,
            "flat_bulk_full_cap_with_ready_hint_above_cap": stats.guest_flat_bulk_full_cap_ready_above_cap,
            "sparse_flat_bulk_full_cap_with_ready_hint_above_cap": stats
                .guest_sparse_flat_bulk_full_cap_ready_above_cap,
        ]
        var event: [String: Any] = [
            "port": port, "accepted": stats.accepted, "connected": stats.connected,
            "connect_errors": stats.connect_errors, "connect_retries": stats.connect_retries,
            "route_waits": stats.route_waits, "handshake_timeouts": stats.handshake_timeouts,
            "last_connect_errno": stats.last_connect_error, "recovered": stats.recovered,
            "setup_closes": stats.setup_closes, "closes_before_response": stats.closes_before_response,
            "idle_guest_closes": stats.idle_guest_closes,
            "stream_errors": stats.stream_errors, "resets_forwarded": stats.resets_forwarded,
            "peak_active": stats.peak_active,
            "upload_bytes": stats.upload_bytes, "download_bytes": stats.download_bytes,
            "reads": stats.reads, "writes": stats.writes, "blocked_writes": stats.blocked_writes,
            "pending_allocations": stats.pending_allocations, "pending_copy_bytes": stats.pending_copy_bytes,
            "bulk_directions": stats.bulk_directions, "guest_read_supply": guestReadSupply,
            "handoff": handoffBuckets(stats.handoff),
            // Array indices match the data owner indices used at accept.
            "handoff_by_worker": owners.map(handoffBuckets),
            "accept_to_connect_us": buckets(stats.connect_us),
            "connect_to_first_guest_byte_us": buckets(stats.first_byte_us),
            "connect_to_first_request_write_us": buckets(stats.first_request_write_us),
            "first_request_write_to_guest_byte_us": buckets(stats.request_to_first_guest_byte_us),
        ]
        if let stage = stats.first_dial_stage {
            event["first_dial_stage"] = String(cString: stage)
            event["first_dial_errno"] = stats.first_dial_errno
        }
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
            SecretSource.stderrLog("published TCP profile " + String(decoding: data, as: UTF8.self))
        }
    }

    deinit { stop() }
}
