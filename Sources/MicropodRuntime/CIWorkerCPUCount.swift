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
        let fastest = self == .auto ? Self.positiveInteger("hw.perflevel0.physicalcpu") : nil
        return try resolve(
            fastestCores: fastest, activeCPUs: ProcessInfo.processInfo.activeProcessorCount,
            minimum: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            maximum: VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    private static func positiveInteger(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        guard sysctlbyname(key, &value, &size, nil, 0) == 0,
            size == MemoryLayout.size(ofValue: value), value > 0
        else { return nil }
        return Int(value)
    }

    private static func stringValue(_ key: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 256)
        var size = bytes.count
        let status = bytes.withUnsafeMutableBytes { sysctlbyname(key, $0.baseAddress, &size, nil, 0) }
        guard status == 0, (2...bytes.count).contains(size), bytes[size - 1] == 0 else { return nil }
        return String(bytes: bytes.prefix(size - 1), encoding: .utf8)
    }

    struct TopologyPlan: Encodable {
        struct Level: Encodable {
            let index: Int
            let name: String?
            let physicalCPUs: Int?
            let cpusPerL2: Int?
        }
        let policy: CIWorkerCPUCount
        let allocation: Allocation
        let activeCPUs: Int
        let vmMinimumCPUs: Int
        let vmMaximumCPUs: Int
        let reportedLevelCount: Int?
        let levels: [Level]
    }

    func topologyPlan() throws -> TopologyPlan {
        try topologyPlan(
            integer: Self.positiveInteger, string: Self.stringValue,
            activeCPUs: ProcessInfo.processInfo.activeProcessorCount,
            minimum: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            maximum: VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    }

    func topologyPlan(
        integer: (String) -> Int?, string: (String) -> String?, activeCPUs: Int, minimum: Int, maximum: Int
    ) throws -> TopologyPlan {
        let count = integer("hw.nperflevels")
        let fastest = integer("hw.perflevel0.physicalcpu")
        // A readable first tier can still inform the existing allocation when enumeration is unavailable.
        let indexes = count.flatMap { (1...Int(UInt16.max)).contains($0) ? $0 : nil } ?? (fastest == nil ? 0 : 1)
        let levels = (0..<indexes).map { index in
            let prefix = "hw.perflevel\(index)."
            return TopologyPlan.Level(
                index: index, name: string(prefix + "name"),
                physicalCPUs: index == 0 ? fastest : integer(prefix + "physicalcpu"),
                cpusPerL2: integer(prefix + "cpusperl2"))
        }
        return try TopologyPlan(
            policy: self,
            allocation: resolve(fastestCores: fastest, activeCPUs: activeCPUs, minimum: minimum, maximum: maximum),
            activeCPUs: activeCPUs, vmMinimumCPUs: minimum, vmMaximumCPUs: maximum,
            reportedLevelCount: count, levels: levels)
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
