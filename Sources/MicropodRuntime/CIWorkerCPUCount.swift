import Darwin
import Foundation
import MicropodCore
import Virtualization

/// The manifest stores the policy. The supervisor resolves it once for each new VM.
enum CIWorkerCPUCount: Equatable, Codable {
    case fixed(Int)
    case auto

    init(_ setting: String) throws {
        if setting == "auto" {
            self = .auto
        } else if let count = Int(setting), (1...64).contains(count) {
            self = .fixed(count)
        } else {
            throw MicropodError.message("MICROPOD_CI_CPUS must be auto or an integer from 1 to 64")
        }
    }

    // A fixed-size worker keeps its original integer representation on disk.
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let count = try? value.decode(Int.self), (1...64).contains(count) {
            self = .fixed(count)
        } else if (try? value.decode(String.self)) == "auto" {
            self = .auto
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid worker CPU policy")
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .fixed(let count): try value.encode(count)
        case .auto: try value.encode("auto")
        }
    }

    struct Allocation: Codable, Equatable {
        enum Source: String, Codable {
            case fixed, fallback
            case performanceLevel = "hw.perflevel0.physicalcpu"
        }
        let count: Int
        let source: Source
    }

    func resolveForBoot() throws -> Allocation {
        var cores: Int32 = 0
        var size = MemoryLayout.size(ofValue: cores)
        let available =
            self == .auto && sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0
            && size == MemoryLayout.size(ofValue: cores) && cores > 0
        return try resolve(
            fastestCores: available ? Int(cores) : nil, activeCPUs: ProcessInfo.processInfo.activeProcessorCount,
            minimum: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            maximum: VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    func resolve(fastestCores: Int?, activeCPUs: Int, minimum: Int, maximum: Int) throws -> Allocation {
        let lower = max(1, minimum)
        let upper = min(64, maximum)
        guard lower <= upper else { throw MicropodError.message("No supported worker vCPU count on this Mac") }
        switch self {
        case .fixed(let count):
            guard (lower...upper).contains(count) else {
                throw MicropodError.message("This Mac supports \(lower)...\(upper) VM vCPUs, requested \(count)")
            }
            return Allocation(count: count, source: .fixed)
        case .auto:
            let cores = fastestCores.flatMap { $0 > 0 ? $0 : nil }
            let count = min(cores ?? 4, max(1, activeCPUs), upper)
            return Allocation(count: max(lower, count), source: cores == nil ? .fallback : .performanceLevel)
        }
    }
}
