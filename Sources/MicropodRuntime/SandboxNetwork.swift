import Containerization
import ContainerizationExtras
import Foundation
import MicropodCore
import vmnet

/// One sandbox's vmnet network (macOS 26 `vmnet_network_create`, no
/// vm.networking entitlement): vmnet picks a free /24 under 192.168/16, so
/// parallel runs never contend for addresses, and sandboxes can't reach
/// each other. The guest gets `.2`, the host side (gateway) is `.1`.
///
/// Owned here rather than through Containerization's `VmnetNetwork`, which
/// never releases its `vmnet_network_ref` — the type imports as an opaque
/// pointer, so ARC can't — and every network then holds its subnet
/// reservation until the process exits. Harmless for a one-shot CLI run;
/// a long-lived API process ran out after ~20 networked sandboxes
/// (`VMNET_FAILURE`). Released on deinit: keep this alive until the VM has
/// stopped, or the guest dies mid-teardown.
final class SandboxNetwork: @unchecked Sendable {
    let interface: VmnetNetwork.Interface
    let gateway: IPv4Address
    private let reference: vmnet_network_ref

    init(mode: vmnet.operating_modes_t) throws {
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let config = vmnet_network_configuration_create(mode, &status) else {
            throw MicropodError.message("vmnet network configuration failed (status \(status.rawValue))")
        }
        defer { Self.release(config) }
        vmnet_network_configuration_disable_dhcp(config)
        guard let reference = vmnet_network_create(config, &status), status == .VMNET_SUCCESS else {
            throw MicropodError.message("vmnet network creation failed (status \(status.rawValue))")
        }
        self.reference = reference

        var subnet = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(reference, &subnet, &mask)
        let lower = UInt32(bigEndian: subnet.s_addr) & UInt32(bigEndian: mask.s_addr)
        let prefix = UInt8(UInt32(bigEndian: mask.s_addr).nonzeroBitCount)
        guard let v4Prefix = Prefix.ipv4(prefix) else {
            Self.release(reference)
            throw MicropodError.message("vmnet gave an unusable subnet mask /\(prefix)")
        }
        gateway = IPv4Address(lower + 1)

        // NAT66: the guest's v6 address and gateway mirror the v4 layout.
        var v6: (address: CIDRv6, gateway: IPv6Address)?
        var prefix6 = in6_addr()
        var length6: UInt8 = 0
        vmnet_network_get_ipv6_prefix(reference, &prefix6, &length6)
        if length6 > 0, let p6 = Prefix.ipv6(length6),
            let base = try? IPv6Address(withUnsafeBytes(of: prefix6) { Array($0) })
        {
            let network = base.value & p6.prefixMask128
            v6 = try? (address: CIDRv6(IPv6Address(network | 2), prefix: p6), gateway: IPv6Address(network | 1))
        }
        do {
            interface = VmnetNetwork.Interface(
                reference: reference,
                ipv4Address: try CIDRv4(IPv4Address(lower + 2), prefix: v4Prefix),
                ipv4Gateway: gateway,
                ipv6Address: v6?.address,
                ipv6Gateway: v6?.gateway)
        } catch {
            Self.release(reference)
            throw error
        }
    }

    deinit { Self.release(reference) }

    /// `CFRelease` for vmnet's CF-style objects (Swift hides `CFRelease`).
    private static func release(_ object: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(object)).release()
    }
}
