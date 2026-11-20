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

    static func attachNIC(_ attach: Bool, vm: VZVirtualMachineInstance, network: SandboxNetwork) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            vm.vmQueue.async {
                do {
                    let devices = vm.vzVirtualMachine.networkDevices
                    guard devices.count == 1 else { throw MicropodError.message("Expected one CI network interface") }
                    devices[0].attachment = attach ? try network.interface.device().attachment : nil
                    done.resume()
                } catch { done.resume(throwing: error) }
            }
        }
    }

    struct NetworkWatch {
        private var retry = false
        private var delay = 5
        private var nextCheck = ContinuousClock.now
        private var nextGuestCheck = ContinuousClock.now + .seconds(20)

        mutating func inspect(_ prepared: SandboxVM.Prepared, gateway: String, instance: UUID, request: UUID?) async
            -> NetworkRepair?
        {
            guard request != nil || ContinuousClock.now >= nextCheck else { return nil }
            nextCheck = .now + .seconds(5)
            let cause: String
            if request != nil {
                cause = "requested"
            } else if retry {
                cause = "retry"
            } else if (try? CIWorker.hasLocalGateway(gateway)) == false {
                cause = "host-gateway-missing"
            } else if ContinuousClock.now >= nextGuestCheck {
                nextGuestCheck = .now + .seconds(20)
                let ok = try? await CIWorker.guestLink(prepared.container, gateway: gateway, repair: false)
                guard ok == false else { return nil }
                cause = "guest-link-unreachable"
            } else {
                return nil
            }
            let start = ContinuousClock.now
            var failure: String?
            do { try await CIWorker.reconnect(prepared) } catch { failure = error.localizedDescription }
            let elapsed = start.duration(to: .now).components
            retry = failure != nil
            delay = retry ? min(delay * 2, 60) : 5
            nextCheck = .now + .seconds(delay)
            nextGuestCheck = .now + .seconds(20)
            return NetworkRepair(
                instance: instance, request: request, gateway: gateway, timestamp: Date(),
                seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, error: failure, cause: cause)
        }
    }

    static func reconnect(_ prepared: SandboxVM.Prepared) async throws {
        guard let network = prepared.network, let gateway = prepared.gateway else {
            throw MicropodError.message("CI worker has no network")
        }
        try await prepared.container.withVirtualMachineInstance { instance in
            guard let vm = instance as? VZVirtualMachineInstance else {
                throw MicropodError.message("Expected an Apple virtual machine")
            }
            try await attachNIC(false, vm: vm, network: network)
            do { try network.renewAnchor() } catch {
                try? await attachNIC(true, vm: vm, network: network)
                throw error
            }
            try await attachNIC(true, vm: vm, network: network)
        }
        guard try await guestLink(prepared.container, gateway: gateway, repair: true), try hasLocalGateway(gateway)
        else {
            throw MicropodError.message("The CI gateway did not answer after reconnecting")
        }
    }

    private static func guestLink(_ container: LinuxContainer, gateway: String, repair: Bool) async throws -> Bool {
        // ARP tests our own first hop even when the upstream Internet or the public DNS is down.
        let script =
            repair
            ? """
            ip link set eth0 up
            ip route replace default via "$1" dev eth0
            ip neigh del "$1" dev eth0 2>/dev/null || true
            for i in 1 2 3; do
                if arping -q -I eth0 -c 1 -w 2 "$1"; then exit 0; fi
            done
            exit 1
            """
            : """
            ip route show default | grep -Fq "via $1 dev eth0"
            arping -q -I eth0 -c 1 -w 2 "$1"
            """
        let probe = try await container.exec(UUID().uuidString) { cfg in
            cfg.capabilities = .allCapabilities
            cfg.arguments = ["/bin/sh", "-ec", script, "sh", gateway]
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
