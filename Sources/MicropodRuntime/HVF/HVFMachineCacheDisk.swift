import Foundation
import MicropodCore

/// The guest's own account of its persistent cache disk (`caches.ext4`,
/// `/dev/vdb` on `/var/lib/micropod/caches`): the `cacheDisk` object of
/// `GET /micropod/caches`.
///
/// ```json
/// {"cacheDisk": {"device": "/dev/vdb", "mounted": true, "sizeBytes": 107374182400, "freeBytes": 96636764160}}
/// ```
public struct HVFCacheDiskState: Codable, Sendable, Equatable {
    public var device: String?
    public var mounted: Bool
    public var sizeBytes: UInt64?
    public var freeBytes: UInt64?

    public init(device: String? = nil, mounted: Bool, sizeBytes: UInt64? = nil, freeBytes: UInt64? = nil) {
        self.device = device
        self.mounted = mounted
        self.sizeBytes = sizeBytes
        self.freeBytes = freeBytes
    }
}

/// Whether the guest mounted the cache disk. That `caches.ext4` exists on
/// the host is no evidence: guest init that fails to mount it carries on
/// with caches on the root disk, which the next `--replace-disk` discards.
/// Only the guest's report counts; without one (machine stopped, guest
/// silent, a tool bundle that predates the report) the disk is `unknown`,
/// and unknown is not mounted.
public struct HVFCacheDiskObservation: Sendable, Equatable {
    /// What the guest reported; nil when unknown.
    public var state: HVFCacheDiskState?
    /// Why the state is unknown.
    public var unknownReason: String?
    /// The host has `caches.ext4`, so micropod-vmm attaches it.
    public var configured: Bool

    public init(state: HVFCacheDiskState?, unknownReason: String? = nil, configured: Bool) {
        self.state = state
        self.unknownReason = state == nil ? unknownReason ?? "unknown" : nil
        self.configured = configured
    }

    /// Rig health's `cacheDiskPresent`.
    public var mounted: Bool { state?.mounted == true }

    /// For JSON health payloads.
    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "mounted": mounted, "configured": configured, "source": state == nil ? "unknown" : "guest",
        ]
        if let reason = unknownReason { object["reason"] = reason }
        if let device = state?.device { object["device"] = device }
        if let size = state?.sizeBytes { object["sizeBytes"] = size }
        if let free = state?.freeBytes { object["freeBytes"] = free }
        return object
    }
}

extension HVFMachineClient {
    /// Asks the running guest whether it mounted the cache disk (`GET
    /// /micropod/caches?stats=0`). Never boots the machine and never throws:
    /// every failure is an `unknown` observation.
    public func cacheDiskObservation(timeout: Duration = .seconds(3)) async -> HVFCacheDiskObservation {
        let configured = HVFMachineLayout.isRegularFile(layout.cacheDisk)
        func unknown(_ reason: String) -> HVFCacheDiskObservation {
            HVFCacheDiskObservation(state: nil, unknownReason: reason, configured: configured)
        }
        guard isServing else { return unknown("the hvf machine is not running") }
        let response: DockerClient.Response
        do {
            response = try await docker.request("GET", "/micropod/caches", query: ["stats": "0"], timeout: timeout)
        } catch {
            return unknown("the guest cache inventory did not answer: \(error.localizedDescription)")
        }
        guard response.status == 200 else {
            return unknown("the guest cache inventory answered HTTP \(response.status)")
        }
        struct Inventory: Decodable { let cacheDisk: HVFCacheDiskState? }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: response.body) else {
            return unknown("the guest cache inventory is not valid JSON")
        }
        guard let disk = inventory.cacheDisk else {
            return unknown("the guest engine does not report cacheDisk (a tool bundle that predates it)")
        }
        return HVFCacheDiskObservation(state: disk, configured: configured)
    }
}
