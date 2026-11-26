// Compile only into the private benchmark build alongside published-mtu.patch.
import Foundation
import vmnet

enum PublishedMTUBenchmark {
    /// Nil keeps the stock configuration. Call only for the worker's second, host-only publication NIC.
    @discardableResult
    static func apply(_ requested: String?, to configuration: OpaquePointer,
                      mode: vmnet.operating_modes_t) throws -> UInt32? {
        guard let requested else { return nil }
        guard mode == .VMNET_HOST_MODE, ["1500", "9000"].contains(requested),
              let mtu = UInt32(requested) else {
            throw NSError(domain: "MicropodPublishedMTUBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected 1500 or 9000 on a host-only publication network"])
        }
        let status = vmnet_network_configuration_set_mtu(configuration, mtu)
        guard status == .VMNET_SUCCESS else {
            throw NSError(domain: "MicropodPublishedMTUBenchmark", code: Int(status.rawValue),
                          userInfo: [NSLocalizedDescriptionKey: "vmnet rejected requested publication MTU \(mtu)"])
        }
        // Returns the accepted request. Negotiated and routed MTUs are measured on the live path.
        return mtu
    }
}
