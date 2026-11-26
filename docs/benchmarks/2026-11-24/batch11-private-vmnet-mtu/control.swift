import Foundation
import vmnet

struct Observation: Encodable {
    let mode: String
    let request: String?
    let acceptedRequest: UInt32?
    let configCreated: Bool
    let outcome: String
}

@main
enum ConfigProbe {
    static func main() throws {
        var observations: [Observation] = []
        let cases: [(vmnet.operating_modes_t, String?)] = [
            (.VMNET_HOST_MODE, nil), (.VMNET_HOST_MODE, "1500"), (.VMNET_HOST_MODE, "9000"),
            (.VMNET_HOST_MODE, "9001"), (.VMNET_SHARED_MODE, "9000")]
        for (mode, request) in cases {
            var status = vmnet_return_t.VMNET_FAILURE
            guard let config = vmnet_network_configuration_create(mode, &status), status == .VMNET_SUCCESS else {
                throw NSError(domain: "vmnet configuration", code: Int(status.rawValue))
            }
            defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(config)).release() }
            var accepted: UInt32?
            var outcome = "stock configuration, no setter"
            do {
                accepted = try PublishedMTUBenchmark.apply(request, to: config, mode: mode)
                if accepted != nil { outcome = "vmnet setter returned VMNET_SUCCESS" }
            } catch {
                outcome = "rejected: " + error.localizedDescription
            }
            observations.append(Observation(mode: mode == .VMNET_HOST_MODE ? "host" : "shared",
                                            request: request, acceptedRequest: accepted,
                                            configCreated: true, outcome: outcome))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(observations))
        print("")
    }
}
