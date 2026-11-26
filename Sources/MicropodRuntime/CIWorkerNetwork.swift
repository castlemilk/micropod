import Containerization
import Darwin
import Foundation
import MicropodCore
import Virtualization

extension CIWorker {
    public struct NetworkRepair: Codable, Sendable {
        public let instance: UUID
        public let request: UUID?
        public let gateway: String
        public let timestamp: Date
        public let seconds: Double
        public let error: String?
        public let cause: String?
    }

    /// Inspect the Mac's own interface addresses. A default route via Wi-Fi also matches a
    /// route-table lookup for a vanished subnet. It cannot deliver packets to this guest.
    static func hasLocalGateway(_ gateway: String) throws -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { freeifaddrs(interfaces) }
        var address = in_addr()
        guard inet_pton(AF_INET, gateway, &address) == 1 else { return false }
        var next = interfaces
        while let interface = next {
            defer { next = interface.pointee.ifa_next }
            guard interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                let item = interface.pointee.ifa_addr, item.pointee.sa_family == AF_INET
            else { continue }
            let ipv4 = UnsafeRawPointer(item).assumingMemoryBound(to: sockaddr_in.self)
            if ipv4.pointee.sin_addr.s_addr == address.s_addr { return true }
        }
        return false
    }

    enum WorkerLink: Int, Sendable {
        case egress, published

        var device: String { self == .egress ? "eth0" : "eth1" }

        func network(in prepared: SandboxVM.Prepared) -> SandboxNetwork? {
            self == .egress ? prepared.network : prepared.publishedNetwork
        }
    }

    static func attachNIC(
        _ attach: Bool, vm: VZVirtualMachineInstance, network: SandboxNetwork, link: WorkerLink = .egress
    ) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            vm.vmQueue.async {
                do {
                    let devices = vm.vzVirtualMachine.networkDevices
                    guard devices.indices.contains(link.rawValue) else {
                        throw MicropodError.message("Missing CI interface " + link.device)
                    }
                    devices[link.rawValue].attachment = attach ? try network.interface.device().attachment : nil
                    done.resume()
                } catch { done.resume(throwing: error) }
            }
        }
    }

    struct PublishedLinkFailure {
        private var firstMiss: ContinuousClock.Instant?

        mutating func clear() { firstMiss = nil }

        mutating func confirmed(at now: ContinuousClock.Instant) -> Bool {
            guard let firstMiss else {
                self.firstMiss = now
                return false
            }
            return now >= firstMiss + .seconds(6)
        }
    }

    actor NetworkWatch {
        private var publishedFailure = PublishedLinkFailure()
        private var retry = false
        private var delay = 0
        private var nextCheck = ContinuousClock.now
        private var nextFailureProbe = ContinuousClock.now
        private var nextGuestCheck = ContinuousClock.now + .seconds(20)

        func inspect(
            _ prepared: SandboxVM.Prepared, gateway: String, instance: UUID, request: UUID?, link: WorkerLink = .egress,
            failedHandshake: Bool = false, publishedRelay: NativeLoopbackRelay? = nil
        ) async -> NetworkRepair? {
            // A real handshake can detect a broken guest link between idle ARP checks.
            // Coalesce retries across all leases and preserve backoff after a failed repair.
            if failedHandshake && ContinuousClock.now >= nextFailureProbe {
                nextGuestCheck = .now
                nextFailureProbe = .now + .seconds(3)
            }
            guard request != nil || ContinuousClock.now >= nextCheck else { return nil }
            guard let network = link.network(in: prepared) else { return nil }
            nextCheck = .now + .seconds(1)
            // Guest application bytes prove that the published data path is working.
            // Keep checking the host gateway, explicit requests and new handshake failures.
            if publishedRelay?.takeGuestTraffic() == true {
                publishedFailure.clear()
                retry = false
                delay = 0
                if !failedHandshake { nextGuestCheck = .now + .seconds(20) }
            }
            var cause: String
            if request != nil {
                cause = "requested"
            } else if retry {
                cause = "retry"
            } else if (try? CIWorker.hasLocalGateway(gateway)) == false {
                cause = "host-gateway-missing"
            } else if ContinuousClock.now >= nextGuestCheck {
                nextGuestCheck = .now + .seconds(20)
                let ok = try? await CIWorker.guestLink(prepared.container, network: network, link: link, mode: .check)
                guard ok == false else {
                    if ok == true { publishedFailure.clear() }
                    return nil
                }
                cause = "guest-link-unreachable"
            } else {
                return nil
            }
            let start = ContinuousClock.now
            var failure: String?
            do {
                // Under load a single missed ARP reply can coexist with live TCP streams.
                // Recover a missing guest route without taking those streams off the NIC.
                if cause == "guest-link-unreachable", (try? CIWorker.hasLocalGateway(gateway)) == true,
                    (try? await CIWorker.guestLink(
                        prepared.container, network: network, link: link, mode: .restoreRoute)) == true,
                    (try? CIWorker.hasLocalGateway(gateway)) == true
                {
                    cause = "guest-link-restored"
                } else if cause == "guest-link-unreachable", publishedRelay?.takeGuestTraffic() == true,
                    (try? CIWorker.hasLocalGateway(gateway)) == true
                {
                    publishedFailure.clear()
                    // Fresh data arrived during the failed probes. Leave the NIC
                    // attached and recheck soon in case new handshakes still fail.
                    nextGuestCheck = .now + .seconds(3)
                    return nil
                } else if cause == "guest-link-unreachable", link == .published,
                    publishedRelay != nil, (try? CIWorker.hasLocalGateway(gateway)) == true,
                    !publishedFailure.confirmed(at: .now)
                {
                    // Replacing a busy VZ endpoint can interrupt the whole link
                    // for seconds. Require another failed probe after the grace
                    // interval. Incoming application bytes clear the suspicion.
                    nextGuestCheck = .now + .seconds(1)
                    return nil
                } else if cause == "guest-link-unreachable", link == .published,
                    (try? CIWorker.hasLocalGateway(gateway)) == true,
                    (try? await CIWorker.replacePublishedAttachment(prepared, network: network)) == true
                {
                    cause = "published-attachment-restored"
                } else {
                    try await CIWorker.reconnect(prepared, link: link)
                }
            } catch { failure = error.localizedDescription }
            let elapsed = start.duration(to: .now).components
            publishedFailure.clear()
            retry = failure != nil
            delay = retry ? min(max(1, delay * 2), 30) : 0
            nextCheck = .now + .seconds(max(1, delay))
            nextGuestCheck = .now + .seconds(20)
            return NetworkRepair(
                instance: instance, request: request, gateway: gateway, timestamp: Date(),
                seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, error: failure, cause: cause)
        }
    }

    /// The guest's virtio queue can stall while the host bridge and egress
    /// still work. Replace just the dedicated endpoint on the pinned network.
    private static func replacePublishedAttachment(_ prepared: SandboxVM.Prepared, network: SandboxNetwork) async throws
        -> Bool
    {
        try await prepared.container.withVirtualMachineInstance { instance in
            guard let vm = instance as? VZVirtualMachineInstance else {
                throw MicropodError.message("Expected an Apple virtual machine")
            }
            try await attachNIC(true, vm: vm, network: network, link: .published)
        }
        // Require fresh ARP evidence after installing the new attachment.
        return try await guestLink(prepared.container, network: network, link: .published, mode: .restoreRoute)
            && (try hasLocalGateway(network.gateway.description))
    }

    static func reconnect(_ prepared: SandboxVM.Prepared, link: WorkerLink = .egress) async throws {
        guard let network = link.network(in: prepared) else {
            throw MicropodError.message("CI worker has no network")
        }
        try await prepared.container.withVirtualMachineInstance { instance in
            guard let vm = instance as? VZVirtualMachineInstance else {
                throw MicropodError.message("Expected an Apple virtual machine")
            }
            try await attachNIC(false, vm: vm, network: network, link: link)
            do { try network.renewAnchor() } catch {
                try? await attachNIC(true, vm: vm, network: network, link: link)
                throw error
            }
            try await attachNIC(true, vm: vm, network: network, link: link)
        }
        guard try await guestLink(prepared.container, network: network, link: link, mode: .reconnected),
            try hasLocalGateway(network.gateway.description)
        else {
            throw MicropodError.message("The CI gateway did not answer after reconnecting")
        }
    }

    private enum LinkProbe { case check, restoreRoute, reconnected }

    // Linux lowers every macvlan MTU with its parent, but leaves the children
    // at the smaller size when the parent grows. Restore only live broker leases.
    private static let restorePublicationLinks = #"""
        parent=$(cat "/sys/class/net/$2/ifindex")
        target=$4
        gso=$5
        owners=$(nft -n list set netdev mp_publication neighbors 2>/dev/null) || owners=
        repair_publication() {
            info=$(nsenter --net=/proc/self/fd/3 ip -d -o link show dev mppub0 2>/dev/null) || return 0
            case "$info" in *"mppub0@if$parent:"*"macvlan mode private"*) ;; *) return 0 ;; esac
            set --
            if [ -n "$target" ]; then
                case "$info" in *" mtu $target "*) ;; *) set -- mtu "$target" ;; esac
            fi
            if [ -n "$gso" ]; then
                case "$info" in *" gso_ipv4_max_size $gso "*) ;; *) set -- "$@" gso_ipv4_max_size "$gso" ;; esac
            fi
            [ "$#" -gt 0 ] || return 0
            mac=$(printf '%s\n' "$info" | awk '{for (i=1; i<NF; i++) if ($i=="link/ether") {print $(i+1); exit}}')
            [ -n "$mac" ] && [ -n "$owners" ] || return 1
            case "$owners" in *"$mac . "*) ;; *) return 0 ;; esac
            nsenter --net=/proc/self/fd/3 ip link set dev mppub0 "$@" && return 0
            # A publication can retire while its namespace is pinned.
            ! nsenter --net=/proc/self/fd/3 ip -o link show dev mppub0 2>/dev/null | grep -Fq "link/ether $mac "
        }
        for ns in /var/run/netns/cni-*; do
            [ -e "$ns" ] || continue
            if ! repair_publication 3<"$ns"; then [ ! -e "$ns" ] || exit 1; fi
        done
        """#

    private static func guestLink(
        _ container: LinuxContainer, network: SandboxNetwork, link: WorkerLink, mode: LinkProbe
    ) async throws -> Bool {
        // The host-only peer is connected directly and must never become a default route.
        let routeCheck =
            link == .egress
            ? #"ip route show default | grep -Fq "via $1 dev $2""#
            : #"ip -4 route get "$1" | grep -Fq "dev $2 ""#
        let linkUp = network.publicationMTU.map { #"ip link set "$2" mtu \#($0) up"# } ?? #"ip link set "$2" up"#
        let checkMTU = network.publicationMTU.map { #"test "$(cat "/sys/class/net/$2/mtu")" = \#($0)"# + "\n" } ?? ""
        let checkGSO =
            network.publicationGSOBytes.map {
                #"ip -d -o link show dev "$2" | grep -Fq ' gso_ipv4_max_size \#($0) '"# + "\n"
            } ?? ""
        let restoreGSO = network.publicationGSOBytes.map { #"ip link set dev "$2" gso_ipv4_max_size \#($0)"# } ?? ""
        let restore = """
            \(linkUp)
            \(restoreGSO)
            ip -o -4 addr show dev "$2" | grep -Fq " $3 " || ip addr replace "$3" dev "$2"
            \(network.publicationMTU != nil || network.publicationGSOBytes != nil ? restorePublicationLinks : "")
            """
        let routeRestore =
            link == .egress ? routeCheck + #" || ip route replace default via "$1" dev "$2""# : routeCheck
        let probePeer = #"arping -f -q -I "$2" -c 1 -w 1 "$1""#
        let script: String
        switch mode {
        case .check:
            script =
                checkMTU + checkGSO + routeCheck + "\n" + #"ip neigh show to "$1" dev "$2" | grep -qw REACHABLE || "#
                + probePeer
        case .restoreRoute:
            script = [restore, routeRestore, probePeer].joined(separator: "\n")
        case .reconnected:
            script = [
                restore, routeRestore, #"ip neigh del "$1" dev "$2" 2>/dev/null || true"#,
                "for i in 1 2 3; do " + probePeer + " && exit 0; done", "exit 1",
            ].joined(separator: "\n")
        }
        let probe = try await container.exec(UUID().uuidString) { cfg in
            cfg.capabilities = .allCapabilities
            cfg.arguments = [
                "/bin/sh", "-ec", script, "sh", network.gateway.description, link.device,
                network.interface.ipv4Address.description, network.publicationMTU.map { String($0) } ?? "",
                network.publicationGSOBytes.map { String($0) } ?? "",
            ]
        }
        let ok: Bool
        do {
            try await probe.start()
            ok = try await probe.wait().exitCode == 0
        } catch {
            try? await probe.delete()
            throw error
        }
        try await probe.delete()
        return ok
    }
}
