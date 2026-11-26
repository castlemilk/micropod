import Foundation
import MicropodCore

/// The guest's own account of its persistent cache disk (`caches.ext4`,
/// `/dev/vdb` on `/var/lib/micropod/caches`): the `cacheDisk` object of
/// `GET /micropod/caches`. `micropod cache status`, `micropod machine status`
/// and the API's rig health all read it, beside the inventory's top-level
/// `unavailable` (`HVFCacheInspection.sharedCachesOffReason`), which says why
/// shared caches are off for the boot.
///
/// ```json
/// {"cacheDisk": {"state": "mounted", "device": "/dev/vdb", "mounted": true,
///                "sizeBytes": 107374182400, "freeBytes": 96636764160}}
/// ```
public struct HVFCacheDiskState: Codable, Sendable, Equatable {
    /// Guest init's outcome this boot: `mounted`, `unavailable` (the host
    /// attached a disk that is missing or did not mount, so shared caches are
    /// off) or `none` (no cache disk: the stores live on the OS disk). nil
    /// from a guest that predates it.
    public var state: String?
    /// The device node, when it exists in the guest.
    public var device: String?
    /// The guest's mountinfo shows `device` mounted on the cache root.
    public var mounted: Bool
    /// Why the guest could not read its mountinfo (`mounted` is then false).
    public var mountInfoError: String?
    public var sizeBytes: UInt64?
    public var freeBytes: UInt64?

    public init(
        state: String? = nil, device: String? = nil, mounted: Bool, mountInfoError: String? = nil,
        sizeBytes: UInt64? = nil, freeBytes: UInt64? = nil
    ) {
        self.state = state
        self.device = device
        self.mounted = mounted
        self.mountInfoError = mountInfoError
        self.sizeBytes = sizeBytes
        self.freeBytes = freeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case state, device, mounted, mountInfoError, sizeBytes, freeBytes
    }

    public init(from decoder: any Decoder) throws {
        // An engine built before the object sent guest init's word alone
        // ("mounted" or "unavailable"); it had checked "mounted" against the
        // cache root, and said otherwise in `unavailable`.
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            self.init(state: word, mounted: word == "mounted")
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try container.decodeIfPresent(String.self, forKey: .state),
            device: try container.decodeIfPresent(String.self, forKey: .device),
            mounted: try container.decodeIfPresent(Bool.self, forKey: .mounted) ?? false,
            mountInfoError: try container.decodeIfPresent(String.self, forKey: .mountInfoError),
            sizeBytes: try container.decodeIfPresent(UInt64.self, forKey: .sizeBytes),
            freeBytes: try container.decodeIfPresent(UInt64.self, forKey: .freeBytes))
    }

    /// The `CACHE DISK:` line of `cache status` and the `cache disk:` line of
    /// `machine status`, or nil when the guest reports nothing about a disk
    /// and caches are on. Shared caches being off for the boot comes first:
    /// every container then runs uncached.
    public static func summary(_ disk: HVFCacheDiskState?, sharedCachesOff: String?) -> String? {
        if let why = sharedCachesOff {
            return "UNAVAILABLE — shared caches are off this boot, every container runs uncached: \(why)"
        }
        guard let disk else { return nil }
        if disk.mounted {
            var detail = "caches.ext4"
            if let device = disk.device { detail += " on \(device)" }
            if let size = disk.sizeBytes, size > 0, let free = disk.freeBytes {
                detail += ", \(gibibytes(free)) free of \(gibibytes(size))"
            }
            return "mounted (\(detail))"
        }
        if let error = disk.mountInfoError {
            return "unknown — the guest cannot read its mountinfo: \(error)"
        }
        if disk.device != nil || disk.state == "mounted" {
            return "NOT MOUNTED — \(disk.device ?? "the cache disk") is attached, but the guest's mountinfo does not "
                + "show it on the cache root; stores there may be on the OS disk, which "
                + "`machine install --replace-disk` discards"
        }
        switch disk.state {
        case "none", nil: return "none (the stores live on the OS disk)"
        case let other?: return other
        }
    }

    static func gibibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(1 << 30))
    }
}

extension HVFMachineLayout {
    /// Why this root boots without the cache disk machine.json expects
    /// (`cacheDiskBytes`), or nil: `caches.ext4` is there, or none was ever
    /// installed. micropod-vmm then attaches no cache disk, so the guest keeps
    /// its stores on the OS disk.
    public func missingCacheDisk(config: HVFMachineConfig) -> String? {
        guard let bytes = config.cacheDiskBytes, !Self.isRegularFile(cacheDisk) else { return nil }
        let size = HVFCacheDiskState.gibibytes(bytes)
        return "machine.json expects a \(size) cache disk, but \(cacheDisk.path) is missing: the machine boots "
            + "without one, so its dependency caches start empty on the OS disk (which `machine install "
            + "--replace-disk` discards). Put caches.ext4 back, or create an empty one with `micropod machine "
            + "install --cache-disk-size \(max(bytes >> 20, 256))m`"
    }
}

/// Whether the guest mounted the cache disk. That `caches.ext4` exists on
/// the host is no evidence: only the guest's report counts. Without one
/// (machine stopped, guest silent, a tool bundle that predates the report)
/// the disk is `unknown`, and unknown is not mounted.
public struct HVFCacheDiskObservation: Sendable, Equatable, Encodable {
    /// What the guest reported; nil when unknown.
    public var state: HVFCacheDiskState?
    /// Why shared caches are off this boot (the inventory's `unavailable`);
    /// nil while they work, or when the guest did not answer.
    public var sharedCachesOffReason: String?
    /// Why the state is unknown.
    public var unknownReason: String?
    /// The host has `caches.ext4`, so micropod-vmm attaches it.
    public var configured: Bool
    /// machine.json expects a cache disk that is gone
    /// (`HVFMachineLayout.missingCacheDisk`); nil otherwise.
    public var missingReason: String?

    public init(
        state: HVFCacheDiskState?, sharedCachesOffReason: String? = nil, unknownReason: String? = nil,
        configured: Bool, missingReason: String? = nil
    ) {
        self.state = state
        self.sharedCachesOffReason = state == nil ? nil : sharedCachesOffReason
        self.unknownReason = state == nil ? unknownReason ?? "unknown" : nil
        self.configured = configured
        self.missingReason = configured ? nil : missingReason
    }

    /// Rig health's `cacheDiskPresent`.
    public var mounted: Bool { state?.mounted == true }

    /// "on", "off" (the guest said why) or "unknown".
    public var sharedCaches: String {
        state == nil ? "unknown" : sharedCachesOffReason == nil ? "on" : "off"
    }

    /// One line for `machine status`.
    public var summary: String {
        if let missingReason { return "MISSING — \(missingReason)" }
        if state != nil || sharedCachesOffReason != nil,
            let line = HVFCacheDiskState.summary(state, sharedCachesOff: sharedCachesOffReason)
        {
            return line
        }
        let reason = unknownReason ?? "unknown"
        return configured
            ? "caches.ext4 is attached at boot; whether the guest mounted it is unknown (\(reason))"
            : "none (no caches.ext4)"
    }

    private enum CodingKeys: String, CodingKey {
        case mounted, configured, source, reason, state, device, mountInfoError, sizeBytes, freeBytes
        case sharedCaches, unavailable, summary
        case missing
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mounted, forKey: .mounted)
        try container.encode(configured, forKey: .configured)
        try container.encodeIfPresent(missingReason, forKey: .missing)
        try container.encode(state == nil ? "unknown" : "guest", forKey: .source)
        try container.encodeIfPresent(unknownReason, forKey: .reason)
        try container.encodeIfPresent(state?.state, forKey: .state)
        try container.encodeIfPresent(state?.device, forKey: .device)
        try container.encodeIfPresent(state?.mountInfoError, forKey: .mountInfoError)
        try container.encodeIfPresent(state?.sizeBytes, forKey: .sizeBytes)
        try container.encodeIfPresent(state?.freeBytes, forKey: .freeBytes)
        try container.encode(sharedCaches, forKey: .sharedCaches)
        try container.encodeIfPresent(sharedCachesOffReason, forKey: .unavailable)
        try container.encode(summary, forKey: .summary)
    }

    /// For JSON health payloads: the same keys as the encoded value.
    public var jsonObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["mounted": mounted, "configured": configured] }
        return object
    }
}

extension HVFMachineClient {
    /// Asks the running guest about its cache disk and whether shared caches
    /// are on (`GET /micropod/caches?stats=0`). Never boots the machine and
    /// never throws: every failure is an `unknown` observation.
    public func cacheDiskObservation(timeout: Duration = .seconds(3)) async -> HVFCacheDiskObservation {
        let configured = HVFMachineLayout.isRegularFile(layout.cacheDisk)
        let missing = (try? HVFMachineConfig.load(from: layout.config)).flatMap { layout.missingCacheDisk(config: $0) }
        func unknown(_ reason: String) -> HVFCacheDiskObservation {
            HVFCacheDiskObservation(state: nil, unknownReason: reason, configured: configured, missingReason: missing)
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
        // Only the two fields: the rest of the inventory may change shape
        // without making the disk unknown.
        struct Inventory: Decodable {
            let cacheDisk: HVFCacheDiskState?
            let unavailable: String?
        }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: response.body) else {
            return unknown("the guest cache inventory is not valid JSON")
        }
        guard let disk = inventory.cacheDisk else {
            return unknown("the guest engine does not report cacheDisk (a tool bundle that predates it)")
        }
        let off = inventory.unavailable?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HVFCacheDiskObservation(
            state: disk, sharedCachesOffReason: off?.isEmpty == false ? off : nil, configured: configured,
            missingReason: missing)
    }
}
