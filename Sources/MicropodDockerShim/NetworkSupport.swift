import Foundation

/// Custom-network support the Apple runtime lacks, emulated shim-side.
///
/// Two gaps, one file:
///
/// 1. Subnet allocation — Apple auto-allocated custom networks land on
///    192.168.65.0/24, where L3 between containers and DNS both fail
///    (probed; the same range Docker Desktop's VM uses on dual-runtime
///    boxes). Explicitly-subnetted networks (e.g. 10.66.0.0/24) get working
///    L3. So when a create omits the subnet, the shim deterministically
///    allocates one from 10.x with collision checks instead of leaving it
///    to the runtime.
/// 2. Name DNS — even healthy custom networks serve no container-name
///    records (the default network does). Like dockerd, which bind-mounts a
///    managed /etc/hosts into every container, the shim maintains one hosts
///    file per Apple network and bind-mounts it read-only into member
///    containers. Membership (Docker name + ids + compose service + aliases)
///    refreshes on every EventsHub tick that changes it, so short-lived
///    task containers resolve within a poll interval.
enum DockerNetworkAllocator {
    /// Deterministic /24 candidate from the network name. Stable across
    /// shim restarts so repeated `compose up` converges instead of churning.
    /// 10.10–10.250 dodge the default route, Apple defaults (192.168.64/65)
    /// and Docker Desktop's usual 172.17/192.168.49 ranges.
    static func candidateSubnet(name: String, attempt: Int = 0) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in (name + "#\(attempt)").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let second = 10 + Int(hash % 241)
        let third = Int((hash >> 8) % 256)
        return "10.\(second).\(third).0/24"
    }

    /// True when two IPv4 CIDRs overlap.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        guard let (aBase, aBits) = parseCIDR(a), let (bBase, bBits) = parseCIDR(b) else {
            return false
        }
        let shared = min(aBits, bBits)
        guard shared > 0 else { return false }
        let mask: UInt32 = shared >= 32 ? 0xFFFF_FFFF : (~UInt32(0) << (32 - shared))
        return (aBase & mask) == (bBase & mask)
    }

    /// First candidate that overlaps nothing in `existingSubnets`, or nil
    /// after a bounded number of attempts (caller surfaces a clear error).
    static func allocate(name: String, existingSubnets: [String], attempts: Int = 64) -> String? {
        for attempt in 0..<attempts {
            let candidate = candidateSubnet(name: name, attempt: attempt)
            if !existingSubnets.contains(where: { overlaps($0, candidate) }) {
                return candidate
            }
        }
        return nil
    }

    private static func parseCIDR(_ cidr: String) -> (UInt32, Int)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), bits >= 0, bits <= 32 else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        let base = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        return (base, bits)
    }
}

/// Managed per-network hosts files emulating dockerd's /etc/hosts mounting.
enum HostsFile {
    /// Stable home for the generated files (runtime file provider reads
    /// under $HOME reliably).
    static func root() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".micropod/hosts", isDirectory: true)
    }

    static func path(for network: String) -> URL {
        root().appendingPathComponent(sanitized(network))
    }

    /// One file per Apple network; names are sanitized for the filesystem
    /// (the mapping back is 1:1 for realistic network names).
    static func sanitized(_ network: String) -> String {
        let cleaned = network.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return String(cleaned.prefix(128))
    }

    /// A container member as the renderer needs it. `names` is the full set
    /// of DNS identities: Docker name, ids, compose service, aliases.
    struct Member: Hashable, Sendable {
        var ip: String
        var names: [String]
    }

    /// Rendered file content for one network. Localhost lines first (so a
    /// managed file is a complete /etc/hosts), then one line per member.
    static func render(members: [Member]) -> String {
        var lines = ["127.0.0.1\tlocalhost", "::1\tlocalhost"]
        for member in members.sorted(by: { $0.ip < $1.ip }) {
            let unique = Array(NSOrderedSet(array: member.names)) as? [String] ?? member.names
            let valid = unique.filter { isHostname($0) }
            guard !valid.isEmpty else { continue }
            lines.append("\(member.ip)\t\(valid.joined(separator: " "))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ensure an (initially localhost-only) file exists for each network so
    /// containers created against them can bind it immediately; membership
    /// fills in on the next sync.
    static func ensure(networks: [String]) {
        guard !networks.isEmpty else { return }
        try? FileManager.default.createDirectory(at: root(), withIntermediateDirectories: true)
        for network in networks {
            let url = path(for: network)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? render(members: []).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Rewrite every network file whose membership changed. Returns the
    /// networks touched (for logging). `membersByNetwork` maps Apple network
    /// name → current running members.
    @discardableResult
    static func sync(membersByNetwork: [String: [Member]]) -> [String] {
        try? FileManager.default.createDirectory(at: root(), withIntermediateDirectories: true)
        var touched: [String] = []
        for (network, members) in membersByNetwork {
            let url = path(for: network)
            let content = render(members: members)
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current != content {
                try? content.write(to: url, atomically: true, encoding: .utf8)
                touched.append(network)
            }
        }
        return touched.sorted()
    }

    static func isHostname(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 253,
            let first = name.first, first.isLetter || first.isNumber
        else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
