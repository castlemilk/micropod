import ContainerizationOCI
import Foundation
import MicropodCore

/// Builds the `ContainerConfiguration` JSON for the `containerCreate`
/// route from a `ContainerRunRequest`.
///
/// This is a port of the flag→configuration half of Apple's
/// `Utility.containerConfigFromFlags` + `Parser` — the semantics the
/// `container run`/`create` commands apply client-side before calling
/// the apiserver. Everything here was verified against the wire shape
/// emitted by `container inspect` on container 1.3.1.
enum NativeConfigBuilder {
    /// `com.apple.container.resource.role = "builtin"` marks the
    /// built-in ("default") network.
    private static let builtinRoleKey = "com.apple.container.resource.role"
    private static let noNetworkName = "none"
    /// Upper bound on `--publish` descriptors (matches the CLI).
    private static let publishedPortCountLimit = 64

    // MARK: - System config (~/.config/container/config.toml)

    /// The subset of `ContainerSystemConfig` the client needs to build a
    /// container config. Everything else (kernel, vminit, network, build)
    /// resolves server-side.
    struct SystemConfig: Sendable {
        var containerCPUs: Int = 4
        /// Mebibytes.
        var containerMemory: Int64 = 1024
        var dnsDomain: String? = nil
        var registryDomain: String = "docker.io"
    }

    /// Minimal TOML reader for the flat `[section] key = value` layout of
    /// `~/.config/container/config.toml`. Only the keys above are read;
    /// unknown keys/sections are ignored.
    static func loadSystemConfig() -> SystemConfig {
        var config = SystemConfig()
        let path = ("~/.config/container/config.toml" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return config }
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let comment = line.firstIndex(of: "#") {
                line = String(line[line.startIndex..<comment]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            switch (section, key) {
            case ("container", "cpus"):
                if let n = Int(value) { config.containerCPUs = n }
            case ("container", "memory"):
                if let mib = try? memoryToMiB(value) { config.containerMemory = mib }
            case ("dns", "domain"):
                config.dnsDomain = value.isEmpty ? nil : value
            case ("registry", "domain"):
                if !value.isEmpty { config.registryDomain = value }
            default:
                continue
            }
        }
        return config
    }

    // MARK: - Memory parsing ("512M", "1g", "4096mb", …)

    /// `Measurement.parse` equivalent for the CLI's memory grammar.
    /// Units are a single letter b/k/m/g/t/p optionally followed by "b"
    /// or "ib" — all *binary* (k=KiB, m=MiB, …); bare numbers are bytes.
    static func memoryToMiB(_ raw: String) throws -> Int64 {
        Int64(try memoryToBytes(raw) / (1024 * 1024))
    }

    /// Memory string → bytes (used for `--memory` and `--shm-size`).
    static func memoryToBytes(_ raw: String) throws -> UInt64 {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = "0123456789."
        let split = lower.firstIndex { !digits.contains($0) } ?? lower.endIndex
        let numStr = String(lower[..<split]).trimmingCharacters(in: .whitespaces)
        var unit = String(lower[split...]).trimmingCharacters(in: .whitespaces)
        guard let n = Double(numStr), !numStr.isEmpty else {
            throw MicropodError.message("invalid memory value '\(raw)'")
        }
        // Unit = first char; the rest must be "", "b", or "ib".
        let symbol = unit.first ?? "b"
        unit = String(unit.dropFirst())
        guard unit.isEmpty || unit == "b" || unit == "ib" else {
            throw MicropodError.message("invalid memory unit in '\(raw)'")
        }
        let factor: Double =
            switch symbol {
            case "b": 1
            case "k": 1024
            case "m": 1024 * 1024
            case "g": 1024 * 1024 * 1024
            case "t": 1024 * 1024 * 1024 * 1024
            case "p": 1024 * 1024 * 1024 * 1024 * 1024
            default: throw MicropodError.message("invalid memory unit '\(symbol)' in '\(raw)'")
            }
        return UInt64(n * factor)
    }

    // MARK: - Process configuration (Parser.process semantics)

    /// Builds `initProcess` from the image config + request flags.
    static func initProcess(
        request: ContainerRunRequest,
        imageConfig: ImageConfig?
    ) throws -> JSONValue {
        // Env: image env (only K=V entries) + env files + request env,
        // deduped keeping the last occurrence of each key.
        var combined: [String] = (imageConfig?.env ?? []).filter { $0.contains("=") }
        for file in request.envFiles {
            combined.append(contentsOf: try parseEnvFile(path: file))
        }
        combined.append(contentsOf: resolveEnvList(request.env))
        var seen: [String: String] = [:]
        for entry in combined {
            let key = String(entry.split(separator: "=", maxSplits: 1).first ?? Substring(entry))
            seen[key] = entry
        }
        let envvars = combined.compactMap { entry -> String? in
            let key = String(entry.split(separator: "=", maxSplits: 1).first ?? Substring(entry))
            return seen[key] == entry ? entry : nil
        }

        let workingDir = request.workdir ?? imageConfig?.workingDir.flatMap { $0.isEmpty ? nil : $0 } ?? "/"

        // Command resolution: --entrypoint overrides; explicit arguments
        // override image Cmd; image Entrypoint prepends.
        var argv: [String] = []
        var entrypointOverridden = false
        if let entrypoint = request.entrypoint, !entrypoint.isEmpty {
            argv = [entrypoint]
            entrypointOverridden = true
        } else if let entrypoint = imageConfig?.entrypoint, !entrypoint.isEmpty, entrypoint != [""] {
            argv = entrypoint
        }
        if !request.arguments.isEmpty {
            argv.append(contentsOf: request.arguments)
        } else if let cmd = imageConfig?.cmd, !entrypointOverridden, !cmd.isEmpty {
            argv.append(contentsOf: cmd)
        }
        guard let executable = argv.first else {
            throw MicropodError.message("command/entrypoint not specified for container process")
        }

        let user = try encodeRunUser(request.user, imageUser: imageConfig?.user)
        let rlimits = try parseRlimits(request.ulimits)

        let process: [String: JSONValue] = [
            "executable": .string(executable),
            "arguments": .array(argv.dropFirst().map { .string($0) }),
            "environment": .array(envvars.map { .string($0) }),
            "workingDirectory": .string(workingDir),
            "terminal": .bool(request.tty),
            "user": user.value,
            "supplementalGroups": .array(user.groups.map { .number(Double($0)) }),
            "rlimits": .array(rlimits),
        ]
        return .object(process)
    }

    /// `--env` entries: bare `NAME` inherits the host environment when
    /// set (and is dropped otherwise); `NAME=` sets an explicit empty.
    private static func resolveEnvList(_ envs: [String]) -> [String] {
        let host = ProcessInfo.processInfo.environment
        return envs.compactMap { env in
            if env.contains("=") { return env }
            guard let value = host[env] else { return nil }
            return "\(env)=\(value)"
        }
    }

    /// Moby-style env-file parsing: `K=V` lines, `#` comments, optional
    /// `export ` prefix, single/double-quoted values.
    private static func parseEnvFile(path: String) throws -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
            let content = String(data: data, encoding: .utf8)
        else {
            throw MicropodError.message("failed to read envfile at \(path)")
        }
        var result: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            let parts = line.split(separator: "=", maxSplits: 1)
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if parts.count == 1 {
                // Bare name: inherit from host env if present.
                if let value = ProcessInfo.processInfo.environment[key] {
                    result.append("\(key)=\(value)")
                }
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
                (value.hasPrefix("\"") && value.hasSuffix("\""))
                    || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            result.append("\(key)=\(value)")
        }
        return result
    }

    /// `ProcessConfiguration.User` encoding. Request `--user` becomes
    /// `{raw: {userString}}`; the image's `User` field passes through as
    /// raw when nonempty, else `{id: {uid: 0, gid: 0}}`.
    private static func encodeRunUser(_ user: String?, imageUser: String?) throws
        -> (value: JSONValue, groups: [UInt32])
    {
        if let user, !user.isEmpty {
            // "uid:gid" with only gid → supplemental group (Parser.user).
            if let gidPart = user.split(separator: ":").last,
                user.hasPrefix(":"), let gid = UInt32(gidPart)
            {
                return (.object(["id": .object(["uid": .number(0), "gid": .number(0)])]), [gid])
            }
            return (.object(["raw": .object(["userString": .string(user)])]), [])
        }
        if let imageUser, !imageUser.isEmpty {
            return (.object(["raw": .object(["userString": .string(imageUser)])]), [])
        }
        return (.object(["id": .object(["uid": .number(0), "gid": .number(0)])]), [])
    }

    private static let ulimitNames: [String: String] = [
        "core": "RLIMIT_CORE", "cpu": "RLIMIT_CPU", "data": "RLIMIT_DATA",
        "fsize": "RLIMIT_FSIZE", "locks": "RLIMIT_LOCKS", "memlock": "RLIMIT_MEMLOCK",
        "msgqueue": "RLIMIT_MSGQUEUE", "nice": "RLIMIT_NICE", "nofile": "RLIMIT_NOFILE",
        "nproc": "RLIMIT_NPROC", "rss": "RLIMIT_RSS", "rtprio": "RLIMIT_RTPRIO",
        "rttime": "RLIMIT_RTTIME", "sigpending": "RLIMIT_SIGPENDING", "stack": "RLIMIT_STACK",
    ]

    /// `<type>=<soft>[:<hard>]`, `unlimited` → UInt64.max.
    private static func parseRlimits(_ raw: [String]) throws -> [JSONValue] {
        var result: [JSONValue] = []
        var seen: Set<String> = []
        for spec in raw {
            let parts = spec.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                let limit = ulimitNames[String(parts[0]).lowercased()]
            else {
                throw MicropodError.message("invalid ulimit '\(spec)'")
            }
            guard !seen.contains(limit) else {
                throw MicropodError.message("duplicate ulimit type '\(parts[0])'")
            }
            seen.insert(limit)
            let values = parts[1].split(separator: ":", maxSplits: 1)
            func parseValue(_ s: Substring) throws -> UInt64 {
                if s == "unlimited" { return UInt64.max }
                guard let n = UInt64(s) else {
                    throw MicropodError.message("invalid ulimit value '\(s)'")
                }
                return n
            }
            let soft = try parseValue(values[0])
            let hard = values.count == 2 ? try parseValue(values[1]) : soft
            result.append(
                .object([
                    "limit": .string(limit),
                    "soft": .number(Double(soft)),
                    "hard": .number(Double(hard)),
                ]))
        }
        return result
    }

    // MARK: - Mounts (Parser.tmpfsMounts + Parser.volume semantics)

    enum ParsedMount {
        case tmpfs(destination: String, options: [String])
        case virtiofs(source: String, destination: String, options: [String])
        /// Named volume — resolved via `volumeCreate`/`volumeInspect`.
        case volume(name: String, destination: String, options: [String])
    }

    static func parseMounts(request: ContainerRunRequest) throws -> [ParsedMount] {
        var result: [ParsedMount] = []
        result.reserveCapacity(request.tmpfs.count + request.volumes.count)
        var seenDestinations: Set<String> = []
        for spec in request.tmpfs {
            let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let destination = String(parts[0])
            guard !destination.isEmpty, destination.hasPrefix("/") else {
                throw MicropodError.message("tmpfs mount destination '\(destination)' must be an absolute path")
            }
            guard seenDestinations.insert(destination).inserted else {
                throw MicropodError.message("duplicate tmpfs mount destination '\(destination)'")
            }
            let options = parts.count == 2 ? parts[1].split(separator: ",").map(String.init) : []
            result.append(.tmpfs(destination: destination, options: options))
        }
        for raw in request.volumes {
            var vol = raw
            while vol.hasPrefix(":") { vol = String(vol.dropFirst()) }
            let parts = vol.split(separator: ":", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                // Anonymous volume — generated name like the CLI's.
                result.append(
                    .volume(
                        name: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                        destination: String(parts[0]), options: []))
            case 2, 3:
                let src = String(parts[0])
                let dst = String(parts[1])
                let options = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
                guard src.contains("/") || src == "." || src == ".." else {
                    result.append(.volume(name: src, destination: dst, options: options))
                    continue
                }
                let absolute = URL(fileURLWithPath: src).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: absolute) else {
                    throw MicropodError.message("path '\(src)' does not exist")
                }
                result.append(.virtiofs(source: absolute, destination: dst, options: options))
            default:
                throw MicropodError.message("invalid volume format '\(raw)'")
            }
        }
        return result
    }

    static func filesystemObject(
        type: String, typeFields: [String: JSONValue], source: String,
        destination: String, options: [String]
    ) -> JSONValue {
        .object([
            "type": .object([type: .object(typeFields)]),
            "source": .string(source),
            "destination": .string(destination),
            "options": .array(options.map { .string($0) }),
        ])
    }

    // MARK: - Networks (getAttachmentConfigurations semantics)

    static func attachments(
        request: ContainerRunRequest,
        containerID: String,
        builtinNetworkID: String?,
        dnsDomain: String?,
        existingNetworks: Set<String>
    ) throws -> [JSONValue] {
        if request.networks.contains(noNetworkName) {
            guard request.networks.count == 1 else {
                throw MicropodError.message("no other networks may be created along with network \(noNetworkName)")
            }
            return []
        }
        // FQDN for the first interface when a dns domain is configured.
        let fqdn: String? =
            if !containerID.contains("."), let dnsDomain {
                "\(containerID).\(dnsDomain)."
            } else if containerID.contains(".") {
                "\(containerID)."
            } else {
                nil
            }

        func attachment(network: String, hostname: String) throws -> JSONValue {
            guard existingNetworks.contains(network) else {
                throw MicropodError.message("network \(network) not found")
            }
            return .object([
                "network": .string(network),
                "options": .object([
                    "hostname": .string(hostname),
                    "mtu": .number(1280),
                ]),
            ])
        }

        if request.networks.isEmpty {
            guard let builtinNetworkID else {
                throw MicropodError.message("builtin network is not present")
            }
            return try [attachment(network: builtinNetworkID, hostname: fqdn ?? containerID)]
        }
        return try request.networks.enumerated().map { index, name in
            try attachment(network: name, hostname: index == 0 ? (fqdn ?? containerID) : containerID)
        }
    }

    // MARK: - Ports / labels / misc

    static func publishedPorts(_ specs: [PortSpec]) throws -> [JSONValue] {
        guard specs.count <= publishedPortCountLimit else {
            throw MicropodError.message("cannot exceed more than \(publishedPortCountLimit) port publish descriptors")
        }
        var hostPorts: Set<Int> = []
        var result: [JSONValue] = []
        for spec in specs {
            guard !hostPorts.contains(spec.hostPort) else {
                throw MicropodError.message("host ports for different publish port specs may not overlap")
            }
            hostPorts.insert(spec.hostPort)
            result.append(
                .object([
                    "containerPort": .number(Double(spec.containerPort)),
                    "count": .number(1),
                    "hostAddress": .string(spec.hostIP ?? "0.0.0.0"),
                    "hostPort": .number(Double(spec.hostPort)),
                    "proto": .string(spec.transportProtocol),
                ]))
        }
        return result
    }

    /// Extract a `.string` payload from an optional JSONValue.
    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let s) = value else { return nil }
        return s
    }

    /// `Parser.labels`: `key=value`, bare key → "", `key=` → "".
    static func labels(_ specs: [LabelSpec]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for spec in specs {
            result[spec.key] = .string(spec.value)
        }
        return result
    }

    /// `Parser.capabilities`: uppercase and normalize to `CAP_*`
    /// (`ALL` passes through verbatim).
    static func normalizeCapabilities(_ caps: [String]) -> [JSONValue] {
        caps.map { cap in
            let upper = cap.uppercased()
            if upper == "ALL" || upper.hasPrefix("CAP_") {
                return .string(upper)
            }
            return .string("CAP_\(upper)")
        }
    }

    // MARK: - Platform

    /// Host CPU architecture in OCI spelling.
    static var hostArchitecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "amd64"
        #endif
    }

    /// `--platform` string → OCI `Platform` JSON. Nil input means the
    /// host arch + linux (matching `Platform.current`).
    static func ociPlatform(_ raw: String?) throws -> JSONValue {
        guard let raw, !raw.isEmpty else {
            return .object([
                "os": .string("linux"),
                "architecture": .string(hostArchitecture),
            ])
        }
        let parts = raw.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.count <= 3 else {
            throw MicropodError.message("invalid platform '\(raw)' (expected os/arch[/variant])")
        }
        var fields: [String: JSONValue] = [
            "os": .string(parts[0].lowercased()),
            "architecture": .string(normalizeArch(parts[1])),
        ]
        if parts.count == 3 {
            fields["variant"] = .string(parts[2])
        }
        return .object(fields)
    }

    /// `Platform.normalizeArch` equivalent (internal upstream).
    static func normalizeArch(_ raw: String) -> String {
        switch raw {
        case "aarch64", "arm64": return "arm64"
        case "x86_64", "x86-64", "amd64": return "amd64"
        case "arm", "armhf", "armel": return "arm"
        default: return raw
        }
    }

    /// `SystemPlatform` JSON for `getDefaultKernel`. Apple's
    /// `SystemPlatform.current` is linux/<host arch> (the *guest* kernel
    /// platform) — the apiserver also derives the init-image platform
    /// from it, so darwin here breaks the initfs lookup.
    static func systemPlatform() -> JSONValue {
        .object([
            "os": .string("linux"),
            "architecture": .string(hostArchitecture),
        ])
    }
}
