import Foundation
import MicropodCore

/// Wire types and transforms for the `container-apiserver` JSON payloads.
///
/// The apiserver encodes payloads with a default `JSONEncoder`, so `Date`s
/// are `timeIntervalSinceReferenceDate` numbers. The `container` CLI's
/// `--format json` output uses `.iso8601`. We normalize to the CLI shape so
/// the existing `ContainerListEntry` decode path works for both backends.

/// `ContainerListFilters` — sent under the `listFilters` key.
struct APIListFilters: Codable, Sendable {
    var ids: [String] = []
    var status: String? = nil
    var labels: [String: String] = [:]
}

/// `ContainerStopOptions` — sent under the `stopOptions` key.
struct APIStopOptions: Codable, Sendable {
    var timeoutInSeconds: Int32
    var signal: String?
}

/// `ContainerStats` — returned under the `statistics` key. Field names are
/// identical to the CLI's `container stats --format json` element, so we
/// decode straight into the shared DTO.
typealias APIContainerStats = ContainerStatsEntry

/// `SystemHealth` — `ping` reply fields we consume.
public struct APIServerHealth: Sendable, Equatable {
    /// Banner form, e.g. "container-apiserver version 1.3.1 (build: release, commit: a9a62e2)".
    public let apiServerVersion: String
    public let apiServerCommit: String
    public let apiServerBuild: String
    public let apiServerAppName: String
    public let appRoot: String?
    public let installRoot: String?
    public let logRoot: String?

    /// The `major.minor.patch` substring extracted from the banner.
    public var semver: String? {
        var parts: [String] = []
        for ch in apiServerVersion {
            if ch.isNumber || ch == "." {
                parts.append(String(ch))
            } else if !parts.isEmpty {
                break
            } else {
                parts = []
            }
        }
        let candidate = parts.joined()
        return candidate.split(separator: ".").count == 3 ? candidate : nil
    }
}

extension JSONValue {
    /// Object-member convenience accessor for payload walking.
    subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }
}

/// `ContainerSnapshot` element, kept loose: we transform it into the
/// `ManagedContainer` shape that `container list --format json` emits.
enum SnapshotTransform {
    /// Deferred-to-Date timestamp → ISO-8601 string (CLI `--format json`).
    static func isoString(from refSeconds: Double) -> String {
        Date(timeIntervalSinceReferenceDate: refSeconds).formatted(.iso8601)
    }

    /// Converts one apiserver `ContainerSnapshot` object into a
    /// `ManagedContainer` object (`{id, configuration, status: {…}}`).
    /// Returns nil when the input isn't a snapshot-shaped object.
    static func toManaged(_ snapshot: JSONValue) -> JSONValue? {
        guard case .object(let snap) = snapshot,
            case .object(var configuration) = snap["configuration"],
            let status = snap["status"]
        else { return nil }

        // configuration.creationDate: number → ISO string.
        if case .number(let creation) = configuration["creationDate"] {
            configuration["creationDate"] = .string(isoString(from: creation))
        }

        var statusObject: [String: JSONValue] = ["state": status]
        if let networks = snap["networks"] {
            statusObject["networks"] = networks
        }
        if case .number(let started) = snap["startedDate"] {
            statusObject["startedDate"] = .string(isoString(from: started))
        }

        let id = configuration["id"] ?? snap["id"] ?? .null
        return .object([
            "id": id,
            "configuration": .object(configuration),
            "status": .object(statusObject),
        ])
    }

    /// `[ContainerSnapshot]` payload → `[ManagedContainer]` data, ready for
    /// `MicropodJSON.decodeArray(ContainerListEntry.self, …)`.
    static func toManagedArrayData(_ snapshots: Data) throws -> Data {
        let values = try MicropodJSON.decoder.decode([JSONValue].self, from: snapshots)
        let managed = values.map { toManaged($0) ?? $0 }
        return try JSONEncoder().encode(managed)
    }
}

/// Builds the `processConfig` payload for `containerCreateProcess` by
/// patching the container's own `initProcess` object — the same trick the
/// CLI uses, so every untouched field (rlimits, sysctls, supplemental
/// groups, user defaults) round-trips verbatim.
enum ProcessConfigPatch {
    enum PatchError: Error {
        case notObject
        case missingInitProcess
    }

    /// - Parameters:
    ///   - snapshotJSON: the `ManagedContainer`-shaped object for this
    ///     container (from `list`/`get`), containing
    ///     `configuration.initProcess`.
    ///   - executable/arguments: command to run.
    ///   - appendEnvironment: request env appended to the image env, matching
    ///     `container exec` semantics.
    static func patch(
        managedJSON: JSONValue,
        executable: String,
        arguments: [String],
        appendEnvironment: [String] = [],
        workingDirectory: String? = nil,
        terminal: Bool = false,
        user: String? = nil
    ) throws -> JSONValue {
        guard case .object(let managed) = managedJSON,
            case .object(let configuration) = managed["configuration"],
            case .object(var initProcess) = configuration["initProcess"]
        else { throw PatchError.missingInitProcess }

        initProcess["executable"] = .string(executable)
        initProcess["arguments"] = .array(arguments.map { .string($0) })
        initProcess["terminal"] = .bool(terminal)
        if !appendEnvironment.isEmpty {
            // `container exec` appends request env to the image env.
            var merged = appendEnvironment.map { JSONValue.string($0) }
            if case .array(let existing) = initProcess["environment"] {
                merged = existing + merged
            }
            initProcess["environment"] = .array(merged)
        }
        if let workingDirectory {
            initProcess["workingDirectory"] = .string(workingDirectory)
        }
        if let user {
            initProcess["user"] = encodeUser(user)
        }
        return .object(initProcess)
    }

    /// `ProcessConfiguration.User` is a Codable enum: `.id(uid:gid:)` ⇢
    /// `{"id":{"uid":N,"gid":N}}`, `.raw(userString:)` ⇢
    /// `{"raw":{"userString":"…"}}`.
    static func encodeUser(_ user: String) -> JSONValue {
        let parts = user.split(separator: ":")
        if parts.count == 2,
            let uid = UInt32(parts[0]), let gid = UInt32(parts[1])
        {
            return .object([
                "id": .object([
                    "uid": .number(Double(uid)),
                    "gid": .number(Double(gid)),
                ])
            ])
        }
        return .object(["raw": .object(["userString": .string(user)])])
    }
}
