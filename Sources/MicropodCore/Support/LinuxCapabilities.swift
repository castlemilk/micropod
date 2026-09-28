import Foundation

/// Linux capability names accepted by `RunContainerRequest.cap_add` /
/// `cap_drop` and the privileged launch profile shared by every backend.
///
/// Spelling follows docker: case-insensitive, with or without the `CAP_`
/// prefix, plus the `ALL` wildcard. `normalize` rejects names the kernel
/// does not define so a typo fails the request instead of being silently
/// dropped (or failing late inside the runtime).
public enum LinuxCapabilities {
    /// Every capability defined by Linux 5.9+ (`include/uapi/linux/capability.h`,
    /// CAP_CHOWN = 0 … CAP_CHECKPOINT_RESTORE = 40), without the prefix.
    public static let known: Set<String> = [
        "CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID", "KILL",
        "SETGID", "SETUID", "SETPCAP", "LINUX_IMMUTABLE", "NET_BIND_SERVICE",
        "NET_BROADCAST", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "IPC_OWNER",
        "SYS_MODULE", "SYS_RAWIO", "SYS_CHROOT", "SYS_PTRACE", "SYS_PACCT",
        "SYS_ADMIN", "SYS_BOOT", "SYS_NICE", "SYS_RESOURCE", "SYS_TIME",
        "SYS_TTY_CONFIG", "MKNOD", "LEASE", "AUDIT_WRITE", "AUDIT_CONTROL",
        "SETFCAP", "MAC_OVERRIDE", "MAC_ADMIN", "SYSLOG", "WAKE_ALARM",
        "BLOCK_SUSPEND", "AUDIT_READ", "PERFMON", "BPF", "CHECKPOINT_RESTORE",
    ]

    /// The wildcard granting (or dropping) every capability.
    public static let all = "ALL"

    public struct InvalidName: Error, Equatable, CustomStringConvertible {
        public let name: String
        public var description: String {
            "unknown Linux capability '\(name)' (use a name like NET_ADMIN or CAP_NET_ADMIN, or ALL)"
        }
    }

    /// `net_admin` / `CAP_NET_ADMIN` → `CAP_NET_ADMIN`; `all` → `ALL`.
    /// Duplicates collapse (first occurrence wins the position).
    public static func normalize(_ names: [String]) throws -> [String] {
        var result: [String] = []
        for raw in names {
            let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
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
}

extension ContainerRunRequest {
    /// Capabilities the runtime is asked to add: `privileged` subsumes any
    /// explicit list with `ALL`.
    public var effectiveCapAdd: [String] {
        privileged ? [LinuxCapabilities.all] : capAdd
    }
}

extension ContainerRunRequest {
    /// Applies the Connect `RunContainerRequest` security/translation fields
    /// (`cap_add`, `cap_drop`, `rosetta`, `privileged`). Capability names are
    /// validated and normalised to `CAP_*`; an unknown name throws
    /// ``LinuxCapabilities/InvalidName``. `rosetta: false` is the same as
    /// unset — it never disables the native backend's automatic Rosetta for
    /// amd64 images.
    public mutating func applySecurityOptions(from proto: Micropod_V1_RunContainerRequest) throws {
        capAdd = try LinuxCapabilities.normalize(proto.capAdd)
        capDrop = try LinuxCapabilities.normalize(proto.capDrop)
        rosetta = proto.hasRosetta && proto.rosetta
        privileged = proto.hasPrivileged && proto.privileged
    }
}
