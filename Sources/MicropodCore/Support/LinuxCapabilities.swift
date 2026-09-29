import Foundation

/// Linux capability names accepted by `RunContainerRequest.cap_add` /
/// `cap_drop` and the privileged launch profile shared by every backend.
///
/// Spelling follows docker: case-insensitive, with or without the `CAP_`
/// prefix, plus the `ALL` wildcard. `normalize` rejects names the kernel
/// does not define so a typo fails the request instead of being silently
/// dropped (or failing late inside the runtime).
public enum LinuxCapabilities {
    /// Every capability defined by Linux 5.9+ (`include/uapi/linux/capability.h`),
    /// without the prefix, in kernel order: CAP_CHOWN = 0 …
    /// CAP_CHECKPOINT_RESTORE = 40.
    public static let ordered: [String] = [
        "CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID", "KILL",
        "SETGID", "SETUID", "SETPCAP", "LINUX_IMMUTABLE", "NET_BIND_SERVICE",
        "NET_BROADCAST", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "IPC_OWNER",
        "SYS_MODULE", "SYS_RAWIO", "SYS_CHROOT", "SYS_PTRACE", "SYS_PACCT",
        "SYS_ADMIN", "SYS_BOOT", "SYS_NICE", "SYS_RESOURCE", "SYS_TIME",
        "SYS_TTY_CONFIG", "MKNOD", "LEASE", "AUDIT_WRITE", "AUDIT_CONTROL",
        "SETFCAP", "MAC_OVERRIDE", "MAC_ADMIN", "SYSLOG", "WAKE_ALARM",
        "BLOCK_SUSPEND", "AUDIT_READ", "PERFMON", "BPF", "CHECKPOINT_RESTORE",
    ]

    public static let known: Set<String> = Set(ordered)

    /// The wildcard granting (or dropping) every capability.
    public static let all = "ALL"

    public struct InvalidName: Error, Equatable, CustomStringConvertible {
        public let name: String
        public var description: String {
            "unknown Linux capability '\(name)' (use a name like NET_ADMIN or CAP_NET_ADMIN, or ALL)"
        }
    }

    /// `privileged` (or `cap_add: ["ALL"]`) together with `cap_drop: ["ALL"]`:
    /// one grants every capability, the other removes every capability.
    public struct Conflict: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// `net_admin` / `CAP_NET_ADMIN` → `CAP_NET_ADMIN`; `all` → `ALL`.
    /// Duplicates collapse (first occurrence wins the position). Names are
    /// matched exactly — surrounding whitespace (spaces, tabs, newlines) is
    /// an invalid name, as in the proto's `buf.validate` pattern the Go
    /// server enforces.
    public static func normalize(_ names: [String]) throws -> [String] {
        var result: [String] = []
        for raw in names {
            let upper = raw.uppercased()
            let normalized: String
            if upper == all {
                normalized = all
            } else {
                let bare = upper.hasPrefix("CAP_") ? String(upper.dropFirst(4)) : upper
                guard known.contains(bare) else { throw InvalidName(name: raw) }
                normalized = "CAP_\(bare)"
            }
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

    /// The bare, uppercased name (`cap_net_raw` → `NET_RAW`, `all` → `ALL`).
    static func bareName(_ name: String) -> String {
        let upper = name.uppercased()
        return upper.hasPrefix("CAP_") ? String(upper.dropFirst(4)) : upper
    }

    /// Rejects the contradictory combinations: `cap_drop: ["ALL"]` with
    /// `privileged` or with `cap_add: ["ALL"]`. The runtime applies drops
    /// before adds, so the request would silently run with every capability.
    public static func validateCombination(capAdd: [String], capDrop: [String], privileged: Bool) throws {
        guard capDrop.contains(where: { bareName($0) == all }) else { return }
        if privileged {
            throw Conflict(
                description:
                    "cap_drop ALL cannot be combined with privileged (privileged grants every capability); "
                    + "drop specific capabilities instead")
        }
        if capAdd.contains(where: { bareName($0) == all }) {
            throw Conflict(description: "cap_drop ALL cannot be combined with cap_add ALL")
        }
    }
}

extension ContainerRunRequest {
    /// Capabilities the runtime is asked to add.
    ///
    /// The runtime applies `cap_drop` first and `cap_add` second, so an `ALL`
    /// add — explicit, or implied by `privileged` — would silently re-grant
    /// every dropped capability. With drops present, `ALL` is expanded to
    /// every capability except the dropped ones, so `cap_drop` really does
    /// apply on top (docker's `--cap-add ALL --cap-drop X` result). Without
    /// drops `ALL` is passed through unchanged. (`cap_drop: ["ALL"]` with an
    /// `ALL` add is refused by the API front doors; Docker-compat surfaces
    /// keep Docker's answer: every capability.)
    public var effectiveCapAdd: [String] {
        let wantsAll = privileged || capAdd.contains { LinuxCapabilities.bareName($0) == LinuxCapabilities.all }
        guard wantsAll else { return capAdd }
        let dropped = Set(capDrop.map(LinuxCapabilities.bareName))
        if dropped.isEmpty || dropped.contains(LinuxCapabilities.all) { return [LinuxCapabilities.all] }
        return LinuxCapabilities.ordered.filter { !dropped.contains($0) }.map { "CAP_\($0)" }
    }
}

extension ContainerRunRequest {
    /// Applies the Connect `RunContainerRequest` security/translation fields
    /// (`cap_add`, `cap_drop`, `rosetta`, `privileged`). Capability names are
    /// validated and normalised to `CAP_*`; an unknown name throws
    /// ``LinuxCapabilities/InvalidName``; `cap_drop: ["ALL"]` with
    /// `privileged` or `cap_add: ["ALL"]` throws ``LinuxCapabilities/Conflict``.
    /// `rosetta: false` is the same as unset — it never disables the native
    /// backend's automatic Rosetta for amd64 images.
    public mutating func applySecurityOptions(from proto: Micropod_V1_RunContainerRequest) throws {
        capAdd = try LinuxCapabilities.normalize(proto.capAdd)
        capDrop = try LinuxCapabilities.normalize(proto.capDrop)
        rosetta = proto.hasRosetta && proto.rosetta
        privileged = proto.hasPrivileged && proto.privileged
        try LinuxCapabilities.validateCombination(capAdd: capAdd, capDrop: capDrop, privileged: privileged)
    }
}

/// Optional `RunContainerRequest` capabilities this build honours, reported
/// in `PingResponse.features` so clients can detect them (an older server
/// silently drops unknown proto3 fields). Mirrored by the Go apiserver.
public enum APIFeatures {
    public static let supported = ["cap_add", "cap_drop", "rosetta", "privileged", "runtime"]
}
