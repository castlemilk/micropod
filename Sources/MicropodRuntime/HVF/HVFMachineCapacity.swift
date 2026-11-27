import Darwin
import Foundation
import MicropodCore

/// The machine's capacity, load and headroom as RigService's
/// `GetMachineCapacity` reports them: the guest engine's
/// `GET /micropod/capacity` (one request, answered from the engine's own
/// counters and its once-a-second sample of the kernel's) plus what this
/// process reads of the Mac in a few system calls.
extension HVFMachineClient {
    /// Why the capacity cannot be read.
    public struct CapacityUnavailable: Error, Sendable, Equatable {
        public let message: String
    }

    /// One guest request. Never boots anything: throws
    /// `CapacityUnavailable` while the machine does not serve, when the
    /// guest does not answer within `timeout`, or when its engine predates
    /// the route.
    public func capacityMessage(timeout: Duration = .seconds(2)) async throws -> Micropod_V1_MachineCapacity {
        guard isServing else {
            throw CapacityUnavailable(message: "the hvf machine is not serving (see `micropod machine status`)")
        }
        let response: DockerClient.Response
        do {
            response = try await docker.request("GET", "/micropod/capacity", timeout: timeout)
        } catch {
            throw CapacityUnavailable(message: "the guest engine did not answer: \(error.localizedDescription)")
        }
        guard response.status == 200 else {
            throw CapacityUnavailable(
                message: response.status == 404 || response.status == 501
                    ? "the machine's engine does not report its capacity (update the machine's payload)"
                    : "the guest engine answered HTTP \(response.status): \(response.message)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let guest = try? decoder.decode(HVFGuestCapacity.self, from: response.body) else {
            throw CapacityUnavailable(message: "the guest engine's capacity report could not be read")
        }
        return Self.capacityMessage(guest: guest, host: HVFHostPressure.read())
    }

    /// The report: the guest's figures, the Mac's, and the guest's headroom
    /// withdrawn when the Mac itself is under memory pressure.
    static func capacityMessage(guest g: HVFGuestCapacity, host: HVFHostPressure) -> Micropod_V1_MachineCapacity {
        func u32(_ value: Int) -> UInt32 { UInt32(clamping: value) }
        func averages(_ line: HVFGuestCapacity.PSILine?) -> Micropod_V1_PressureAverages {
            .with {
                $0.avg10 = line?.avg10 ?? 0
                $0.avg60 = line?.avg60 ?? 0
                $0.avg300 = line?.avg300 ?? 0
            }
        }
        func resource(_ value: HVFGuestCapacity.PSI?) -> Micropod_V1_PressureResource {
            .with {
                $0.some = averages(value?.some)
                $0.full = averages(value?.full)
            }
        }
        func disk(_ value: HVFGuestCapacity.Disk) -> Micropod_V1_MachineDisk {
            .with {
                $0.totalBytes = value.totalBytes
                $0.freeBytes = value.freeBytes
            }
        }
        return .with { m in
            m.sampledUnixMs = g.sampledUnixMs
            m.cpus = u32(g.capacity.cpus)
            m.memoryBytes = g.capacity.memoryBytes
            m.pidMax = g.capacity.pidMax
            m.maxContainers = u32(g.capacity.maxContainers)
            m.familyContainersMax = u32(g.capacity.familyContainersMax)
            m.relayConnectionsMax = u32(g.capacity.relayConnectionsMax)
            m.usage = .with {
                $0.cpuBusyFraction = g.usage.cpuBusyFraction
                $0.cpuBusyCpus = g.usage.cpuBusyCpus
                $0.load1 = g.usage.load1
                $0.load5 = g.usage.load5
                $0.load15 = g.usage.load15
                $0.runnable = u32(g.usage.runnable)
                $0.tasks = u32(g.usage.tasks)
                $0.memoryAvailableBytes = g.usage.memoryAvailableBytes
                $0.memoryUsedBytes = g.usage.memoryUsedBytes
                $0.swapUsedBytes = g.usage.swapUsedBytes
                $0.openFiles = g.usage.openFiles
                $0.conntrackEntries = g.usage.conntrackEntries
                $0.relayConnections = u32(g.usage.relayConnections)
            }
            m.containers = .with {
                $0.total = u32(g.containers.total)
                $0.running = u32(g.containers.running)
                $0.starting = u32(g.containers.starting)
                $0.created = u32(g.containers.created)
                $0.exited = u32(g.containers.exited)
                $0.requestedMilliCpu = g.containers.requestedMilliCpu
                $0.requestedMemoryBytes = g.containers.requestedMemoryBytes
                $0.withoutCpuLimit = u32(g.containers.withoutCpuLimit)
                $0.families = g.containers.families.map { family in
                    .with {
                        $0.name = family.name
                        $0.running = u32(family.running)
                        $0.total = u32(family.total)
                        $0.requestedMilliCpu = family.requestedMilliCpu
                        $0.requestedMemoryBytes = family.requestedMemoryBytes
                    }
                }
            }
            m.engine = .with {
                $0.createsInFlight = u32(g.engine.createsInFlight)
                $0.startsInFlight = u32(g.engine.startsInFlight)
                $0.startP50Ms = u32(g.engine.startP50Ms)
                $0.startP95Ms = u32(g.engine.startP95Ms)
                $0.startsSampled = u32(g.engine.startsSampled)
            }
            m.pressure = .with {
                $0.available = g.pressure.available
                $0.cpu = resource(g.pressure.cpu)
                $0.memory = resource(g.pressure.memory)
                $0.io = resource(g.pressure.io)
            }
            m.osDisk = disk(g.disks.os)
            if let cache = g.disks.cache { m.cacheDisk = disk(cache) }
            m.headroom = .with {
                $0.containers = u32(g.headroom.containers)
                $0.underPressure = g.headroom.underPressure
                $0.reasons = g.headroom.reasons
                $0.limitedBy = g.headroom.limitedBy
                $0.unitCpu = g.headroom.unitCpu
                $0.unitMemoryBytes = g.headroom.unitMemoryBytes
                $0.byCpu = u32(g.headroom.byCpu)
                $0.byMemory = u32(g.headroom.byMemory)
                $0.byTasks = u32(g.headroom.byTasks)
                $0.byContainers = u32(g.headroom.byContainers)
            }
            m.host = .with {
                $0.cpus = u32(host.cpus)
                $0.memoryBytes = host.memoryBytes
                $0.memoryAvailableBytes = host.memoryAvailableBytes
                $0.memoryPressure = host.memoryPressure
                $0.load1 = host.load1
            }
            // The guest cannot see the Mac: memory the guest has free is no
            // use while the Mac is reclaiming to keep it.
            if host.memoryPressure == "warning" || host.memoryPressure == "critical" {
                if !m.headroom.underPressure { m.headroom.limitedBy = "host-memory" }
                m.headroom.underPressure = true
                m.headroom.containers = 0
                m.headroom.reasons.append("the Mac is under memory pressure (\(host.memoryPressure))")
            }
        }
    }
}

/// `GET /micropod/capacity` as the guest engine writes it
/// (guest/runner/docker_capacity_linux.go), decoded from snake case.
struct HVFGuestCapacity: Decodable, Sendable {
    struct Capacity: Decodable, Sendable {
        var cpus: Int
        var memoryBytes: UInt64
        var pidMax: UInt64
        var maxContainers: Int
        var familyContainersMax: Int
        var relayConnectionsMax: Int
    }
    struct Usage: Decodable, Sendable {
        var cpuBusyFraction: Double
        var cpuBusyCpus: Double
        var load1: Double
        var load5: Double
        var load15: Double
        var runnable: Int
        var tasks: Int
        var memoryAvailableBytes: UInt64
        var memoryUsedBytes: UInt64
        var swapUsedBytes: UInt64
        var openFiles: UInt64
        var conntrackEntries: UInt64
        var relayConnections: Int
    }
    struct Family: Decodable, Sendable {
        var name: String
        var running: Int
        var total: Int
        var requestedMilliCpu: Int64
        var requestedMemoryBytes: Int64
    }
    struct Containers: Decodable, Sendable {
        var total: Int
        var running: Int
        var starting: Int
        var created: Int
        var exited: Int
        var requestedMilliCpu: Int64
        var requestedMemoryBytes: Int64
        var withoutCpuLimit: Int
        var families: [Family]
    }
    struct Engine: Decodable, Sendable {
        var createsInFlight: Int
        var startsInFlight: Int
        var startP50Ms: Int
        var startP95Ms: Int
        var startsSampled: Int
    }
    struct PSILine: Decodable, Sendable {
        var avg10: Double
        var avg60: Double
        var avg300: Double
    }
    struct PSI: Decodable, Sendable {
        var some: PSILine
        var full: PSILine
    }
    struct Pressure: Decodable, Sendable {
        var available: Bool
        var cpu: PSI?
        var memory: PSI?
        var io: PSI?
    }
    struct Disk: Decodable, Sendable {
        var totalBytes: UInt64
        var freeBytes: UInt64
    }
    struct Disks: Decodable, Sendable {
        var os: Disk
        var cache: Disk?
    }
    struct Headroom: Decodable, Sendable {
        var containers: Int
        var underPressure: Bool
        var reasons: [String]
        var limitedBy: String
        var unitCpu: Double
        var unitMemoryBytes: UInt64
        var byCpu: Int
        var byMemory: Int
        var byTasks: Int
        var byContainers: Int
    }

    var sampledUnixMs: Int64
    var capacity: Capacity
    var usage: Usage
    var containers: Containers
    var engine: Engine
    var pressure: Pressure
    var disks: Disks
    var headroom: Headroom
}

/// The Mac's own load, read without a subprocess: three sysctls, one Mach
/// call and `getloadavg`.
public struct HVFHostPressure: Sendable, Equatable {
    public var cpus: Int
    public var memoryBytes: UInt64
    /// Free, inactive, speculative and purgeable pages.
    public var memoryAvailableBytes: UInt64
    /// normal, warning or critical; empty when the kernel did not say.
    public var memoryPressure: String
    public var load1: Double

    public init(cpus: Int, memoryBytes: UInt64, memoryAvailableBytes: UInt64, memoryPressure: String, load1: Double) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.memoryPressure = memoryPressure
        self.load1 = load1
    }

    /// The kernel's `kern.memorystatus_vm_pressure_level`: 1 normal, 2
    /// warning, 4 critical.
    static func pressureName(level: Int32) -> String {
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return ""
        }
    }

    public static func read() -> HVFHostPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure =
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
            ? pressureName(level: level) : ""
        var available: UInt64 = 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pages =
                UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
                + UInt64(stats.purgeable_count)
            available = pages * UInt64(sysconf(_SC_PAGESIZE))
        }
        var load = [Double](repeating: 0, count: 1)
        let loads = getloadavg(&load, 1)
        return HVFHostPressure(
            cpus: ProcessInfo.processInfo.activeProcessorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory,
            memoryAvailableBytes: available, memoryPressure: pressure, load1: loads == 1 ? load[0] : 0)
    }
}
