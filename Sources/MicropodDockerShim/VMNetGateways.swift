import Darwin
import Foundation
import MicropodCore

/// The runtime's networks as the host sees them: each vmnet network's
/// gateway is the host-side address its guests reach the host at (the
/// default network is 192.168.65.1 today, 192.168.64.1 on older runtimes;
/// custom networks get their own). Resolved from `container network list`
/// — never hardcoded — and refreshed as networks come and go.
actor VMNetGateways {
    struct Network: Equatable, Sendable {
        let id: String
        let gateway: String
        /// IPv4 network address and prefix length of `ipv4Subnet`.
        let subnet: IPv4Subnet?
        let isDefault: Bool
    }

    private let list: @Sendable () async throws -> [Micropod_V1_Network]
    private(set) var networks: [Network] = []
    private let peerIndex = PeerIndex()

    init(list: @escaping @Sendable () async throws -> [Micropod_V1_Network]) {
        self.list = list
    }

    /// Re-reads the runtime's networks. A failed read keeps the last good
    /// answer (the runtime may be restarting).
    @discardableResult
    func refresh() async -> [Network] {
        guard let fresh = try? await list() else { return networks }
        networks = fresh.compactMap { network in
            let gateway = network.ipv4Gateway.trimmingCharacters(in: .whitespaces)
            guard IPv4Subnet.parseAddress(gateway) != nil else { return nil }
            return Network(
                id: network.id, gateway: gateway, subnet: IPv4Subnet(cidr: network.ipv4Subnet),
                isDefault: network.builtin || network.id == "default")
        }
        peerIndex.update(networks)
        return networks
    }

    var defaultGateway: String? {
        networks.first(where: \.isDefault)?.gateway
    }

    /// The gateway a container attached to `network` (nil: the default
    /// network) reaches the host at; falls back to the default network's.
    func gateway(forNetwork network: String?) -> String? {
        if let network, let match = networks.first(where: { $0.id == network }) {
            return match.gateway
        }
        return defaultGateway
    }

    /// Synchronous peer filter for a listener bound to `gateway` (called on
    /// the accept thread): only guests inside that gateway's network(s).
    nonisolated func peerFilter(forGateway gateway: String) -> @Sendable (String) -> Bool {
        let index = peerIndex
        return { peer in index.allows(peer: peer, gateway: gateway) }
    }

    /// Lock-protected copy of the subnets for the accept threads.
    final class PeerIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var subnetsByGateway: [String: [IPv4Subnet]] = [:]

        func update(_ networks: [Network]) {
            var map: [String: [IPv4Subnet]] = [:]
            for network in networks {
                if let subnet = network.subnet { map[network.gateway, default: []].append(subnet) }
            }
            lock.lock()
            subnetsByGateway = map
            lock.unlock()
        }

        func allows(peer: String, gateway: String) -> Bool {
            lock.lock()
            let subnets = subnetsByGateway[gateway] ?? []
            lock.unlock()
            return subnets.contains { $0.contains(peer) }
        }
    }
}

/// IPv4 CIDR arithmetic for the gateway peer filter.
struct IPv4Subnet: Equatable, Sendable {
    let network: UInt32
    let prefix: Int

    init?(cidr: String) {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let address = Self.parseAddress(String(parts[0])),
            let prefix = Int(parts[1]), (0...32).contains(prefix)
        else { return nil }
        self.prefix = prefix
        self.network = address & Self.mask(prefix)
    }

    func contains(_ address: String) -> Bool {
        guard let value = Self.parseAddress(address) else { return false }
        return value & Self.mask(prefix) == network
    }

    static func mask(_ prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
    }

    static func parseAddress(_ text: String) -> UInt32? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }
}

/// IPv4 addresses currently assigned to this host's interfaces. A vmnet
/// gateway only exists (and can only be bound) while its bridge interface
/// is up — i.e. while a guest is attached to that network.
enum HostInterfaces {
    static func ipv4Addresses() -> Set<String> {
        var result = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var inAddr = sin.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &inAddr, &text, socklen_t(INET_ADDRSTRLEN))
                }
                result.insert(String(cString: text))
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
}

/// Keeps one shim TCP listener per vmnet gateway that is currently present
/// on the host, next to the loopback listener. Never `INADDR_ANY`: the shim
/// is an unauthenticated Docker API (privileged containers, host binds), so
/// it must not be reachable from the LAN.
///
/// A gateway can only be bound while its bridge interface exists (a guest is
/// attached), so this polls the interface list (cheap `getifaddrs`) and
/// re-reads the runtime's networks when the address set changes or every
/// `networkRefresh`. Listeners for networks that were deleted are closed.
final class GatewayListeners: @unchecked Sendable {
    private let server: ShimHTTPServer
    private let port: UInt16
    private let gateways: VMNetGateways
    /// Always bound in addition to discovered gateways when present on the
    /// host (`MICROPOD_SHIM_BRIDGE`).
    private let pinned: String?
    private let interfaces: @Sendable () -> Set<String>
    /// Never bound here: loopback has its own listener, and a wildcard would
    /// reopen the LAN exposure. (Tests clear it to bind 127.0.0.1.)
    private let excluded: Set<String>
    private let lock = NSLock()
    private var listeners: [String: ShimHTTPServer.TCPListener] = [:]

    init(
        server: ShimHTTPServer, port: UInt16, gateways: VMNetGateways, pinned: String? = nil,
        interfaces: @escaping @Sendable () -> Set<String> = { HostInterfaces.ipv4Addresses() },
        excluded: Set<String> = ["127.0.0.1", "0.0.0.0"]
    ) {
        self.excluded = excluded
        self.server = server
        self.port = port
        self.gateways = gateways
        self.pinned = pinned
        self.interfaces = interfaces
    }

    var boundAddresses: Set<String> {
        lock.withLock { Set(listeners.keys) }
    }

    /// One reconciliation pass; returns the addresses bound afterwards.
    @discardableResult
    func reconcile(refreshNetworks: Bool) async -> Set<String> {
        let networks = refreshNetworks ? await gateways.refresh() : await gateways.networks
        let known = Set(networks.map(\.gateway)).union(pinned.map { [$0] } ?? [])
        let present = interfaces()
        let desired = known.intersection(present).subtracting(excluded)

        let (stale, missing) = lock.withLock {
            let stale = listeners.filter { !known.contains($0.key) }
            for key in stale.keys { listeners.removeValue(forKey: key) }
            return (stale, desired.subtracting(listeners.keys))
        }
        for (address, listener) in stale {
            listener.close()
            fputs("[shim] network for gateway \(address) is gone; closed its listener\n", stderr)
        }
        for address in missing.sorted() {
            // A discovered gateway admits only guests on its network(s); an
            // explicit MICROPOD_SHIM_BRIDGE outside every runtime network is
            // the operator's call.
            let isNetworkGateway = networks.contains { $0.gateway == address }
            var filter: @Sendable (String) -> Bool = { _ in true }
            if isNetworkGateway { filter = gateways.peerFilter(forGateway: address) }
            do {
                let listener = try server.listenTCP(host: address, port: port, peerAllowed: filter)
                lock.withLock { listeners[address] = listener }
                fputs("[shim]   bridge      : \(address):\(port) (in-VM docker clients)\n", stderr)
            } catch {
                fputs("[shim] could not bind \(address):\(port): \(error)\n", stderr)
            }
        }
        return boundAddresses
    }

    /// Follows interface and network changes until the process exits.
    func run(
        pollInterval: Duration = .milliseconds(500), networkRefresh: Duration = .seconds(30)
    ) async {
        var lastInterfaces = interfaces()
        var lastRefresh = ContinuousClock.now
        await reconcile(refreshNetworks: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            let current = interfaces()
            let due = ContinuousClock.now - lastRefresh >= networkRefresh
            guard current != lastInterfaces || due else { continue }
            lastInterfaces = current
            lastRefresh = ContinuousClock.now
            await reconcile(refreshNetworks: true)
        }
    }
}
