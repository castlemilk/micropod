import Foundation
import Yams

/// A single ordered step of a compose up/down plan.
public enum ComposeStep: Sendable, Equatable {
    case network(Micropod_V1_ComposeNetwork)
    case volume(Micropod_V1_ComposeVolume)
    case pull(image: String, force: Bool)
    case build(request: ContainerBuildRequest, tag: String)
    case run(request: ContainerRunRequest)
    case readiness(Micropod_V1_ComposeService)
}

/// A ready-to-execute plan for a compose spec, in dependency order.
public struct ComposePlan: Sendable, Equatable {
    public var steps: [ComposeStep] = []
    /// Names of networks created by the plan (to tear down on `down`).
    public var createdNetworks: [String] = []
    /// Names of volumes created by the plan.
    public var createdVolumes: [String] = []
    /// Compose label value stamped on every run.
    public var composeName: String = ""
}

/// A Compose producer and its progress stream. Exposing the producer task
/// lets callers propagate cancellation to the work that owns the plan.
public struct ComposeExecution: Sendable {
    public let stream: AsyncThrowingStream<String, Error>
    public let task: Task<Void, Never>
}

public protocol ComposeServing: Sendable {
    /// Parses a docker-compose.yml into a proto ComposeSpec.
    func parse(url: URL) async throws -> Micropod_V1_ComposeSpec
    /// Builds an ordered execution plan from a spec (no profiles enabled).
    func plan(spec: Micropod_V1_ComposeSpec) throws -> ComposePlan
    /// Builds an ordered execution plan, including services whose profiles
    /// intersect the enabled set (docker `--profile` semantics).
    func plan(spec: Micropod_V1_ComposeSpec, enabledProfiles: Set<String>) throws -> ComposePlan
    /// Executes a plan (up), streaming step progress. Throws on first failure.
    func up(plan: ComposePlan) -> AsyncThrowingStream<String, Error>
    /// Tears down all containers tagged with the compose name.
    func down(composeName: String) async throws
}

/// Serializes a parsed spec back to docker-compose YAML. Round-trips the
/// fields the parser understands (formatting/comments are not preserved).
public func composeYAML(from spec: Micropod_V1_ComposeSpec) -> String {
    var root: [String: Any] = [:]
    if !spec.name.isEmpty { root["name"] = spec.name }

    if !spec.services.isEmpty {
        var services: [String: Any] = [:]
        for service in spec.services {
            services[service.name] = serviceDict(service)
        }
        root["services"] = services
    }
    if !spec.volumes.isEmpty {
        root["volumes"] = Dictionary(uniqueKeysWithValues: spec.volumes.map { ($0.key, volumeDict($0.value)) })
    }
    if !spec.networks.isEmpty {
        root["networks"] = Dictionary(uniqueKeysWithValues: spec.networks.map { ($0.key, networkDict($0.value)) })
    }
    return (try? Yams.dump(object: root)) ?? ""
}

private func serviceDict(_ service: Micropod_V1_ComposeService) -> [String: Any] {
    var dict: [String: Any] = [:]
    if !service.image.isEmpty { dict["image"] = service.image }
    if !service.buildContext.isEmpty {
        var build: [String: Any] = ["context": service.buildContext]
        if !service.buildDockerfile.isEmpty { build["dockerfile"] = service.buildDockerfile }
        if !service.buildArgs.isEmpty { build["args"] = service.buildArgs }
        if !service.buildTarget.isEmpty { build["target"] = service.buildTarget }
        if !service.buildPlatform.isEmpty { build["platform"] = service.buildPlatform }
        if service.buildNoCache { build["no_cache"] = true }
        dict["build"] = build
    }
    if !service.dependsOn.isEmpty {
        if service.dependsOnConditions.isEmpty {
            dict["depends_on"] = service.dependsOn
        } else {
            var deps: [String: Any] = [:]
            for dep in service.dependsOn {
                deps[dep] = ["condition": service.dependsOnConditions[dep] ?? "service_started"]
            }
            dict["depends_on"] = deps
        }
    }
    if !service.ports.isEmpty {
        dict["ports"] = service.ports.map { port in
            let host = port.hostPort > 0 ? "\(port.hostPort):" : ""
            let proto = port.protocol.isEmpty || port.protocol == "tcp" ? "" : "/\(port.protocol)"
            return "\(host)\(port.containerPort)\(proto)"
        }
    }
    if !service.environment.isEmpty { dict["environment"] = service.environment }
    if !service.volumes.isEmpty { dict["volumes"] = service.volumes }
    if !service.commands.isEmpty {
        dict["command"] = service.commands.count == 1 ? service.commands[0] : service.commands
    }
    if !service.workingDir.isEmpty { dict["working_dir"] = service.workingDir }
    if !service.restart.isEmpty && service.restart != "no" { dict["restart"] = service.restart }
    if service.cpus > 0 { dict["cpus"] = service.cpus }
    if !service.memory.isEmpty { dict["mem_limit"] = service.memory }
    if !service.healthcheckCommand.isEmpty {
        var hc: [String: Any] = ["test": ["CMD", service.healthcheckCommand]]
        if service.healthcheckIntervalSeconds > 0 { hc["interval"] = "\(service.healthcheckIntervalSeconds)s" }
        if service.healthcheckTimeoutSeconds > 0 { hc["timeout"] = "\(service.healthcheckTimeoutSeconds)s" }
        if service.healthcheckRetries > 0 { hc["retries"] = service.healthcheckRetries }
        if service.healthcheckStartPeriodSeconds > 0 {
            hc["start_period"] = "\(service.healthcheckStartPeriodSeconds)s"
        }
        dict["healthcheck"] = hc
    }
    if !service.networks.isEmpty { dict["networks"] = service.networks }
    if !service.containerName.isEmpty && service.containerName != service.name {
        dict["container_name"] = service.containerName
    }
    if !service.entrypoint.isEmpty { dict["entrypoint"] = service.entrypoint }
    if !service.user.isEmpty { dict["user"] = service.user }
    if !service.labels.isEmpty { dict["labels"] = service.labels }
    if !service.dns.isEmpty { dict["dns"] = service.dns }
    if !service.dnsSearch.isEmpty { dict["dns_search"] = service.dnsSearch }
    if !service.capAdd.isEmpty { dict["cap_add"] = service.capAdd }
    if !service.capDrop.isEmpty { dict["cap_drop"] = service.capDrop }
    if !service.ulimits.isEmpty { dict["ulimits"] = service.ulimits }
    if !service.tmpfs.isEmpty { dict["tmpfs"] = service.tmpfs }
    if !service.envFile.isEmpty { dict["env_file"] = service.envFile }
    if !service.shmSize.isEmpty { dict["shm_size"] = service.shmSize }
    if service.readOnly { dict["read_only"] = true }
    if service.init_p { dict["init"] = true }
    if service.tty { dict["tty"] = true }
    if service.stdinOpen { dict["stdin_open"] = true }
    if !service.profiles.isEmpty { dict["profiles"] = service.profiles }
    if !service.pullPolicy.isEmpty && service.pullPolicy != "missing" { dict["pull_policy"] = service.pullPolicy }
    if service.stopGracePeriodSeconds > 0 { dict["stop_grace_period"] = "\(service.stopGracePeriodSeconds)s" }
    return dict
}

private func volumeDict(_ volume: Micropod_V1_ComposeVolume) -> [String: Any] {
    var dict: [String: Any] = [:]
    if volume.external {
        dict["external"] = volume.externalName.isEmpty ? true : ["name": volume.externalName]
    }
    if !volume.driver.isEmpty { dict["driver"] = volume.driver }
    if !volume.driverOpts.isEmpty {
        dict["driver_opts"] = Dictionary(
            uniqueKeysWithValues: volume.driverOpts.compactMap { opt in
                let parts = opt.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            })
    }
    if !volume.labels.isEmpty { dict["labels"] = volume.labels }
    return dict
}

private func networkDict(_ network: Micropod_V1_ComposeNetwork) -> [String: Any] {
    var dict: [String: Any] = [:]
    if network.internal { dict["internal"] = true }
    if network.external {
        dict["external"] = network.externalName.isEmpty ? true : ["name": network.externalName]
    }
    if !network.driver.isEmpty { dict["driver"] = network.driver }
    if !network.driverOpts.isEmpty { dict["driver_opts"] = network.driverOpts }
    if !network.labels.isEmpty { dict["labels"] = network.labels }
    if !network.subnet.isEmpty || !network.subnetV6.isEmpty {
        var config: [String: Any] = [:]
        if !network.subnet.isEmpty { config["subnet"] = network.subnet }
        if !network.subnetV6.isEmpty { config["subnet_v6"] = network.subnetV6 }
        dict["ipam"] = ["config": [config]]
    }
    return dict
}

/// Parse + orchestration for docker-compose.yml files on the `container`
/// runtime (which has no native compose support).
public actor ComposeService: @preconcurrency ComposeServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    // MARK: - Parse

    public func parse(url: URL) async throws -> Micropod_V1_ComposeSpec {
        let data = try Data(contentsOf: url)
        guard let yaml = try Yams.load(yaml: String(data: data, encoding: .utf8) ?? "") as? [String: Any] else {
            throw MicropodError.message("Compose file is not a YAML mapping")
        }
        let baseURL = url.deletingLastPathComponent()
        let env = loadEnvironment(from: baseURL)

        var spec = Micropod_V1_ComposeSpec()
        spec.path = url.path
        spec.name = interpolate((yaml["name"] as? String) ?? url.deletingPathExtension().lastPathComponent, env: env)

        if let services = yaml["services"] as? [String: Any] {
            for (name, raw) in services.sorted(by: { $0.key < $1.key }) {
                guard let raw = raw as? [String: Any] else { continue }
                spec.services.append(parseService(name: name, raw: raw, baseURL: baseURL, env: env))
            }
        }

        if let volumes = yaml["volumes"] as? [String: Any] {
            for (name, raw) in volumes {
                var volume = Micropod_V1_ComposeVolume()
                volume.name = name
                if let raw = raw as? [String: Any] {
                    if let external = raw["external"] as? Bool {
                        volume.external = external
                    } else if let external = raw["external"] as? [String: Any] {
                        volume.external = true
                        volume.externalName = (external["name"] as? String) ?? name
                    }
                    volume.driver = (raw["driver"] as? String) ?? ""
                    if let opts = raw["driver_opts"] as? [String: Any] {
                        volume.driverOpts = opts.map { "\($0.key)=\($0.value)" }
                    }
                    if let labels = raw["labels"] as? [String: Any] {
                        volume.labels = labels.map { "\($0.key)=\($0.value)" }
                    }
                }
                spec.volumes[name] = volume
            }
        }

        if let networks = yaml["networks"] as? [String: Any] {
            for (name, raw) in networks {
                var network = Micropod_V1_ComposeNetwork()
                network.name = name
                if let raw = raw as? [String: Any] {
                    network.internal = (raw["internal"] as? Bool) ?? false
                    if let external = raw["external"] as? Bool {
                        network.external = external
                    } else if let external = raw["external"] as? [String: Any] {
                        network.external = true
                        network.externalName = (external["name"] as? String) ?? name
                    }
                    network.driver = (raw["driver"] as? String) ?? ""
                    if let opts = raw["driver_opts"] as? [String: Any] {
                        network.driverOpts = opts.map { "\($0.key)=\($0.value)" }
                    }
                    if let labels = raw["labels"] as? [String: Any] {
                        network.labels = labels.map { "\($0.key)=\($0.value)" }
                    }
                    if let ipam = raw["ipam"] as? [String: Any], let configs = ipam["config"] as? [Any],
                        let first = configs.first as? [String: Any]
                    {
                        network.subnet = (first["subnet"] as? String) ?? ""
                        network.subnetV6 = (first["subnet_v6"] as? String) ?? ""
                    }
                }
                spec.networks[name] = network
            }
        }
        return spec
    }

    /// Loads interpolation variables: process environment first, then `.env`.
    private func loadEnvironment(from baseURL: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let envURL = baseURL.appendingPathComponent(".env")
        if let contents = try? String(contentsOf: envURL, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    env[String(parts[0])] = String(parts[1])
                }
            }
        }
        return env
    }

    /// `${VAR}`, `${VAR:-default}`, `${VAR-default}` and `$VAR` interpolation.
    static func interpolate(_ value: String, env: [String: String]) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "$" {
                let next = value.index(after: index)
                if next < value.endIndex, value[next] == "{" {
                    if let close = value[next...].firstIndex(of: "}") {
                        let expression = String(value[value.index(after: next)..<close])
                        index = value.index(after: close)
                        result += resolveExpression(expression, env: env)
                        continue
                    }
                }
                if next < value.endIndex, value[next].isLetter || value[next] == "_" {
                    var end = next
                    while end < value.endIndex, value[end].isLetter || value[end].isNumber || value[end] == "_" {
                        end = value.index(after: end)
                    }
                    let key = String(value[next..<end])
                    index = end
                    result += env[key] ?? ""
                    continue
                }
            }
            result.append(value[index])
            index = value.index(after: index)
        }
        return result
    }

    private static func resolveExpression(_ expression: String, env: [String: String]) -> String {
        for separator in [":-", "-"] {
            if let range = expression.range(of: separator) {
                let key = String(expression[..<range.lowerBound])
                let defaultValue = String(expression[range.upperBound...])
                if let value = env[key], !value.isEmpty || separator == "-" {
                    return value
                }
                return defaultValue
            }
        }
        return env[expression] ?? ""
    }

    private func interpolate(_ value: String, env: [String: String]) -> String {
        Self.interpolate(value, env: env)
    }

    private func parseService(name: String, raw: [String: Any], baseURL: URL, env: [String: String])
        -> Micropod_V1_ComposeService
    {
        var service = Micropod_V1_ComposeService()
        service.name = name
        service.image = interpolate((raw["image"] as? String) ?? "", env: env)
        service.containerName = interpolate((raw["container_name"] as? String) ?? name, env: env)
        service.workingDir = (raw["working_dir"] as? String) ?? ""
        service.restart = (raw["restart"] as? String) ?? "no"
        service.user = interpolate((raw["user"] as? String) ?? "", env: env)
        service.entrypoint = interpolate(stringList(raw["entrypoint"]).joined(separator: " "), env: env)
        service.shmSize = (raw["shm_size"] as? String) ?? ""
        service.readOnly = (raw["read_only"] as? Bool) ?? false
        service.init_p = (raw["init"] as? Bool) ?? false
        service.tty = (raw["tty"] as? Bool) ?? false
        service.stdinOpen = (raw["stdin_open"] as? Bool) ?? false
        service.privileged = (raw["privileged"] as? Bool) ?? false
        service.extraHosts = stringList(raw["extra_hosts"])
        service.stopSignal = (raw["stop_signal"] as? String) ?? ""
        if let grace = raw["stop_grace_period"] {
            service.stopGracePeriodSeconds = parseDurationSeconds(grace)
        }
        service.dns = stringList(raw["dns"])
        service.dnsSearch = stringList(raw["dns_search"])
        service.capAdd = stringList(raw["cap_add"])
        service.capDrop = stringList(raw["cap_drop"])
        service.tmpfs = stringList(raw["tmpfs"])
        service.labels = parseLabels(raw["labels"])
        service.ulimits = parseUlimits(raw["ulimits"])
        service.profiles = stringList(raw["profiles"])
        service.pullPolicy = (raw["pull_policy"] as? String) ?? ""

        if let build = raw["build"] {
            switch build {
            case let path as String:
                service.buildContext = interpolate(path, env: env)
            case let dict as [String: Any]:
                service.buildContext = interpolate((dict["context"] as? String) ?? "", env: env)
                service.buildDockerfile = (dict["dockerfile"] as? String) ?? ""
                service.buildTarget = (dict["target"] as? String) ?? ""
                service.buildPlatform = (dict["platform"] as? String) ?? ""
                if let noCache = dict["no_cache"] as? Bool {
                    service.buildNoCache = noCache
                }
                if let args = dict["args"] as? [String: Any] {
                    service.buildArgs = args.map { "\($0.key)=\(interpolate("\($0.value)", env: env))" }
                }
            default: break
            }
        }

        if let dependsOn = raw["depends_on"] {
            switch dependsOn {
            case let list as [String]:
                service.dependsOn = list
            case let dict as [String: Any]:
                // Swift Dictionaries lose YAML declaration order; sort for determinism.
                service.dependsOn = dict.keys.sorted()
                for (dependency, spec) in dict {
                    if let spec = spec as? [String: Any], let condition = spec["condition"] as? String {
                        service.dependsOnConditions[dependency] = condition
                    }
                }
            default: break
            }
        }

        if let ports = raw["ports"] as? [Any] {
            service.ports = ports.compactMap { parsePort($0) }
        }

        if let envFile = raw["env_file"] {
            let files = stringList(envFile)
            for file in files {
                let resolved = resolvePath(interpolate(file, env: env), relativeTo: specPath(from: baseURL))
                guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else { continue }
                for line in contents.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0])
                        let value = interpolate(String(parts[1]), env: env)
                        // env_file entries come first; `environment` overrides.
                        if !service.environment.contains(where: { $0.hasPrefix("\(key)=") }) {
                            service.environment.append("\(key)=\(value)")
                        }
                    }
                }
            }
        }

        if let environment = raw["environment"] {
            switch environment {
            case let dict as [String: Any]:
                for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                    let interpolated = interpolate("\(value)", env: env)
                    service.environment.append("\(key)=\(interpolated)")
                }
            case let list as [String]:
                service.environment = list.map { interpolate($0, env: env) }
            default: break
            }
        }

        if let volumes = raw["volumes"] as? [Any] {
            for volume in volumes {
                if let dict = volume as? [String: Any] {
                    // Long syntax.
                    let type = (dict["type"] as? String) ?? "volume"
                    let source = interpolate((dict["source"] as? String) ?? "", env: env)
                    let target = (dict["target"] as? String) ?? ""
                    let readOnly = (dict["read_only"] as? Bool) ?? false
                    switch type {
                    case "tmpfs":
                        service.tmpfs.append(target)
                    case "bind":
                        let resolved =
                            source.hasPrefix("/") ? source : resolvePath(source, relativeTo: specPath(from: baseURL))
                        service.volumes.append("\(resolved):\(target)\(readOnly ? ":ro" : "")")
                    default:
                        service.volumes.append("\(source):\(target)\(readOnly ? ":ro" : "")")
                    }
                } else {
                    service.volumes.append(interpolate("\(volume)", env: env))
                }
            }
        }

        if let command = raw["command"] {
            switch command {
            case let s as String: service.commands = [interpolate(s, env: env)]
            case let list as [Any]: service.commands = list.map { interpolate("\($0)", env: env) }
            default: break
            }
        }

        if let cpus = raw["cpus"] as? Double {
            service.cpus = cpus
        }
        if let memLimit = raw["mem_limit"] as? String {
            service.memory = memLimit
        }
        // compose v3: deploy.resources.limits (cpus may be a string like "0.25")
        if let deploy = raw["deploy"] as? [String: Any],
            let resources = deploy["resources"] as? [String: Any],
            let limits = resources["limits"] as? [String: Any]
        {
            if service.cpus == 0 {
                if let cpus = limits["cpus"] as? Double {
                    service.cpus = cpus
                } else if let cpus = limits["cpus"] as? String, let parsed = Double(cpus) {
                    service.cpus = parsed
                }
            }
            if service.memory.isEmpty, let memory = limits["memory"] as? String {
                service.memory = memory
            }
        }

        if let healthcheck = raw["healthcheck"] as? [String: Any] {
            if (healthcheck["disable"] as? Bool) == true {
                service.healthcheckCommand = ""
            } else if let test = healthcheck["test"] {
                let parts = stringList(test)
                // "CMD", "CMD-SHELL" prefixes tell the probe to run inside the container.
                service.healthcheckCommand = parts.dropFirst().joined(separator: " ")
            }
            if let interval = healthcheck["interval"] {
                service.healthcheckIntervalSeconds = parseDurationSeconds(interval)
            }
            if let timeout = healthcheck["timeout"] {
                service.healthcheckTimeoutSeconds = parseDurationSeconds(timeout)
            }
            if let retries = healthcheck["retries"] as? Int {
                service.healthcheckRetries = Int32(retries)
            }
            if let startPeriod = healthcheck["start_period"] {
                service.healthcheckStartPeriodSeconds = parseDurationSeconds(startPeriod)
            }
        }

        if let networks = raw["networks"] {
            switch networks {
            case let list as [Any]:
                service.networks = list.map { "\($0)" }
            case let dict as [String: Any]:
                service.networks = Array(dict.keys)
            default: break
            }
        }
        return service
    }

    private func specPath(from baseURL: URL) -> String {
        baseURL.appendingPathComponent("docker-compose.yml").path
    }

    private func parsePort(_ raw: Any) -> Micropod_V1_PortMapping? {
        // Long syntax: {target, published, protocol, host_ip, mode}
        if let dict = raw as? [String: Any] {
            guard let containerPort = dict["target"] as? Int else { return nil }
            var mapping = Micropod_V1_PortMapping()
            mapping.containerPort = UInt32(containerPort)
            if let published = dict["published"] as? Int {
                mapping.hostPort = UInt32(published)
            }
            mapping.protocol = (dict["protocol"] as? String) ?? "tcp"
            if let hostIP = dict["host_ip"] as? String {
                mapping.hostIp = hostIP
            }
            return mapping
        }
        let text = "\(raw)"
        // Short forms: "8080:80", "127.0.0.1:8080:80", "8080:80/udp"
        let protocolSplit = text.split(separator: "/", maxSplits: 1)
        let protocolName = protocolSplit.count > 1 ? String(protocolSplit[1]) : "tcp"
        let parts = protocolSplit[0].split(separator: ":")
        guard parts.count >= 2, let containerPort = Int(parts[parts.count - 1]) else { return nil }
        let hostPort = parts.count >= 2 ? Int(parts[parts.count - 2]) : nil
        var mapping = Micropod_V1_PortMapping()
        mapping.containerPort = UInt32(containerPort)
        if let hostPort { mapping.hostPort = UInt32(hostPort) }
        mapping.protocol = protocolName
        if parts.count == 3 {
            mapping.hostIp = String(parts[0])
        }
        return mapping
    }

    private func parseLabels(_ raw: Any?) -> [String] {
        guard let raw else { return [] }
        if let dict = raw as? [String: Any] {
            return dict.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        }
        if let list = raw as? [Any] {
            return list.map { "\($0)" }
        }
        return []
    }

    private func parseUlimits(_ raw: Any?) -> [String] {
        guard let raw else { return [] }
        if let dict = raw as? [String: Any] {
            return dict.map { key, value in
                if let spec = value as? [String: Any] {
                    if let hard = spec["hard"] {
                        return "\(key)=\(spec["soft"] ?? ""):\(hard)"
                    }
                    return "\(key)=\(spec["soft"] ?? "")"
                }
                return "\(key)=\(value)"
            }
        }
        if let list = raw as? [Any] {
            return list.map { "\($0)" }
        }
        return []
    }

    private func parseDurationSeconds(_ raw: Any) -> Int32 {
        if let number = raw as? Int { return Int32(number) }
        guard let text = raw as? String else { return 0 }
        var total = 0
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if current.isEmpty == false {
                let value = Int(current) ?? 0
                switch character {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                case "d": total += value * 86400
                default: break
                }
                current = ""
            }
        }
        if current.isEmpty == false {
            total += Int(current) ?? 0
        }
        return Int32(total)
    }

    private func stringList(_ raw: Any?) -> [String] {
        guard let raw else { return [] }
        if let string = raw as? String { return [string] }
        if let list = raw as? [Any] { return list.map { "\($0)" } }
        return []
    }

    // MARK: - Plan

    public nonisolated func plan(spec: Micropod_V1_ComposeSpec) throws -> ComposePlan {
        try plan(spec: spec, enabledProfiles: [])
    }

    public nonisolated func plan(spec: Micropod_V1_ComposeSpec, enabledProfiles: Set<String>) throws
        -> ComposePlan
    {
        var plan = ComposePlan()
        plan.composeName = spec.name

        for (_, network) in spec.networks.sorted(by: { $0.key < $1.key }) where !network.external {
            plan.steps.append(.network(network))
            plan.createdNetworks.append(network.name)
        }
        for (_, volume) in spec.volumes.sorted(by: { $0.key < $1.key }) where !volume.external {
            plan.steps.append(.volume(volume))
            plan.createdVolumes.append(volume.name)
        }

        // Docker profile semantics: profiled services only run when an enabled
        // profile matches; unprofiled services always run.
        let activeServices = spec.services.filter { service in
            service.profiles.isEmpty || service.profiles.contains(where: enabledProfiles.contains)
        }
        let ordered = try orderedServices(activeServices)
        let healthRequired = requiredHealthyServices(activeServices)
        for service in ordered {
            if service.image.isEmpty, !service.buildContext.isEmpty {
                let tag = "\(spec.name)-\(service.name):latest"
                let buildRequest = ContainerBuildRequest(
                    contextDirectory: resolvePath(service.buildContext, relativeTo: spec.path),
                    dockerfile: service.buildDockerfile.isEmpty ? nil : service.buildDockerfile,
                    tags: [tag],
                    buildArgs: service.buildArgs,
                    target: service.buildTarget.isEmpty ? nil : service.buildTarget,
                    platform: service.buildPlatform.isEmpty ? nil : service.buildPlatform,
                    noCache: service.buildNoCache
                )
                plan.steps.append(.build(request: buildRequest, tag: tag))
            } else if !service.image.isEmpty {
                plan.steps.append(.pull(image: service.image, force: service.pullPolicy == "always"))
            }

            let runRequest = makeRunRequest(spec: spec, service: service)
            plan.steps.append(.run(request: runRequest))

            // Docker semantics: a readiness probe runs only when another
            // service depends on this one with condition service_healthy.
            if !service.healthcheckCommand.isEmpty, healthRequired.contains(service.name) {
                plan.steps.append(.readiness(service))
            }
        }
        return plan
    }

    /// Names of services that some other service depends on with
    /// `condition: service_healthy`.
    private nonisolated func requiredHealthyServices(_ services: [Micropod_V1_ComposeService]) -> Set<String> {
        var required: Set<String> = []
        for service in services {
            for (dependency, condition) in service.dependsOnConditions where condition == "service_healthy" {
                required.insert(dependency)
            }
        }
        return required
    }

    private nonisolated func orderedServices(_ services: [Micropod_V1_ComposeService]) throws
        -> [Micropod_V1_ComposeService]
    {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var result: [Micropod_V1_ComposeService] = []
        var visited: [String: Bool] = [:]  // false = in progress (cycle)

        func visit(_ name: String) throws {
            guard let service = byName[name] else { return }
            switch visited[name] {
            case true: return
            case false: throw MicropodError.message("Compose dependency cycle involving '\(name)'")
            default: break
            }
            visited[name] = false
            for dependency in service.dependsOn {
                try visit(dependency)
            }
            visited[name] = true
            result.append(service)
        }

        for service in services {
            try visit(service.name)
        }
        return result
    }

    private nonisolated func makeRunRequest(spec: Micropod_V1_ComposeSpec, service: Micropod_V1_ComposeService)
        -> ContainerRunRequest
    {
        var labels =
            [LabelSpec(key: "com.skunkworq.micropod.compose", value: spec.name)]
            + service.labels.map { label in
                let parts = label.split(separator: "=", maxSplits: 1)
                return LabelSpec(
                    key: String(parts[0]),
                    value: parts.count > 1 ? String(parts[1]) : "")
            }
        if service.stopGracePeriodSeconds > 0 {
            labels.append(
                LabelSpec(key: "com.skunkworq.micropod.stop-grace", value: String(service.stopGracePeriodSeconds)))
        }

        var request = ContainerRunRequest(
            image: service.image.isEmpty ? "\(spec.name)-\(service.name):latest" : service.image,
            name: service.containerName,
            detach: true,
            cpus: service.cpus > 0 ? service.cpus : nil,
            memory: service.memory.isEmpty ? nil : service.memory,
            env: service.environment,
            envFiles: service.envFile.map { resolvePath($0, relativeTo: spec.path) },
            publishedPorts: service.ports.map {
                PortSpec(
                    hostPort: Int($0.hostPort), containerPort: Int($0.containerPort),
                    transportProtocol: $0.`protocol`, hostIP: $0.hostIp.isEmpty ? nil : $0.hostIp)
            },
            volumes: service.volumes.map { resolveVolume($0, spec: spec) },
            tmpfs: service.tmpfs,
            labels: labels,
            interactive: service.stdinOpen,
            tty: service.tty,
            useInit: service.init_p,
            readOnly: service.readOnly,
            user: service.user.isEmpty ? nil : service.user,
            shmSize: service.shmSize.isEmpty ? nil : service.shmSize,
            dns: service.dns,
            dnsSearch: service.dnsSearch,
            capAdd: service.capAdd,
            capDrop: service.capDrop,
            ulimits: service.ulimits,
            networks: service.networks.map { resolveNetworkName($0, spec: spec) },
            arguments: service.commands
        )
        if !service.workingDir.isEmpty { request.workdir = service.workingDir }
        if !service.entrypoint.isEmpty { request.entrypoint = service.entrypoint }
        return request
    }

    /// Maps a service network key to the runtime network name, honoring
    /// `external: {name: …}` overrides.
    private nonisolated func resolveNetworkName(_ key: String, spec: Micropod_V1_ComposeSpec) -> String {
        guard let network = spec.networks[key], network.external, !network.externalName.isEmpty else {
            return key
        }
        return network.externalName
    }

    private nonisolated func resolveVolume(_ volume: String, spec: Micropod_V1_ComposeSpec) -> String {
        let parts = volume.split(separator: ":", maxSplits: 2)
        guard parts.count == 2 else { return volume }
        let source = String(parts[0])
        let destination = String(parts[1])
        let isNamed = spec.volumes[source] != nil
        let isAbsolute = source.hasPrefix("/")
        if isNamed || isAbsolute {
            return volume
        }
        // Relative host path → resolve against the compose file's directory.
        let base = (spec.path as NSString).deletingLastPathComponent
        return "\(base)/\(source):\(destination)"
    }

    private nonisolated func resolvePath(_ path: String, relativeTo specPath: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        let base = (specPath as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(path)
    }

    // MARK: - Execute

    public func up(plan: ComposePlan) -> AsyncThrowingStream<String, Error> {
        startUp(plan: plan).stream
    }

    public nonisolated func startUp(plan: ComposePlan) -> ComposeExecution {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task {
            await self.execute(plan: plan, continuation: continuation)
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return ComposeExecution(stream: stream, task: task)
    }

    private func execute(
        plan: ComposePlan,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            for step in plan.steps {
                if Task.isCancelled { throw CancellationError() }
                switch step {
                case .network(let network):
                    guard !network.external else { continue }
                    _ = try await client.run(
                        ContainerCommandFactory.createNetwork(
                            network.name,
                            internal: network.internal,
                            subnet: network.subnet.isEmpty ? nil : network.subnet,
                            subnetV6: network.subnetV6.isEmpty ? nil : network.subnetV6,
                            driver: network.driver.isEmpty ? nil : network.driver,
                            options: network.driverOpts,
                            labels: network.labels),
                        timeout: .seconds(30))
                    continuation.yield("Network \(network.name) created")

                case .volume(let volume):
                    guard !volume.external else { continue }
                    // driver_opts.size maps to the runtime's --size.
                    var options = volume.driverOpts
                    var size: String?
                    if let index = options.firstIndex(where: { $0.hasPrefix("size=") }) {
                        size = String(options[index].dropFirst("size=".count))
                        options.remove(at: index)
                    }
                    _ = try await client.run(
                        ContainerCommandFactory.createVolume(
                            volume.name, size: size, labels: volume.labels, options: options),
                        timeout: .seconds(30))
                    continuation.yield("Volume \(volume.name) created")

                case .pull(let image, let force):
                    if !force, try await imagePresentLocally(image) {
                        continuation.yield("Image \(image) already present")
                        continue
                    }
                    continuation.yield("Pulling \(image)…")
                    let command = ContainerCommandFactory.pullImage(image)
                    for try await _ in client.stream(command) {}
                    try Task.checkCancellation()
                    continuation.yield("Pulled \(image)")

                case .build(let request, let tag):
                    continuation.yield("Building \(tag)…")
                    let command = ContainerCommandFactory.build(request)
                    for try await _ in client.stream(command) {}
                    try Task.checkCancellation()
                    continuation.yield("Built \(tag)")

                case .run(let request):
                    let output = try await client.run(
                        ContainerCommandFactory.run(request), timeout: .seconds(120))
                    let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield("Started \(request.name ?? id)")

                case .readiness(let service):
                    continuation.yield("Waiting for \(service.containerName) to be ready…")
                    try await waitForReadiness(service: service)
                    continuation.yield("\(service.containerName) is ready")
                }
            }
            try Task.checkCancellation()
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Real readiness probe: run the healthcheck command via `exec` until it
    /// exits 0 — never treat "has an IP" or "is running" as ready. Honors the
    /// compose healthcheck timing (interval/timeout/retries/start_period).
    private func waitForReadiness(service: Micropod_V1_ComposeService) async throws {
        let command = service.healthcheckCommand
        let interval =
            service.healthcheckIntervalSeconds > 0
            ? Int(service.healthcheckIntervalSeconds) : 2
        let retries =
            service.healthcheckRetries > 0
            ? Int(service.healthcheckRetries) : 30
        let attemptTimeout =
            service.healthcheckTimeoutSeconds > 0
            ? min(Int(service.healthcheckTimeoutSeconds), 20) : 20
        let startPeriod = Int(service.healthcheckStartPeriodSeconds)

        if startPeriod > 0 {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(for: .seconds(startPeriod))
        }

        for _ in 0..<retries {
            if Task.isCancelled { throw CancellationError() }
            // Real probe: the healthcheck command must exit 0 inside the container.
            let execRequest = ContainerExecRequest(
                containerID: service.containerName,
                arguments: ["/bin/sh", "-c", command])
            if (try? await client.run(ContainerCommandFactory.exec(execRequest), timeout: .seconds(attemptTimeout)))
                != nil
            {
                return
            }
            try await Task.sleep(for: .seconds(interval))
        }
        throw MicropodError.message(
            "\(service.containerName) did not become ready after \(retries) probes (\(command))")
    }

    /// Whether the image reference exists in the local store (docker's
    /// default `pull_policy: missing` behavior).
    private func imagePresentLocally(_ reference: String) async throws -> Bool {
        let output = try await client.run(ContainerCommandFactory.listImages(verbose: false), timeout: .seconds(30))
        let entries = try MicropodJSON.decodeArray(
            ImageListEntry.self, from: Data(output.utf8), context: "image presence")
        return entries.contains { $0.configuration.name == reference }
    }

    public func down(composeName: String) async throws {
        // Find containers stamped with the compose label.
        let output = try await client.run(ContainerCommandFactory.listContainers(all: true), timeout: .seconds(30))
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: Data(output.utf8), context: "compose down")
        for entry in entries {
            guard entry.configuration.labels?["com.skunkworq.micropod.compose"] == composeName else { continue }
            let id = entry.id
            // Honor the per-service stop_grace_period stamped at up time.
            let grace = Int(entry.configuration.labels?["com.skunkworq.micropod.stop-grace"] ?? "") ?? 10
            _ = try? await client.run(
                ContainerCommandFactory.stopContainer(id, timeout: grace), timeout: .seconds(60))
            _ = try? await client.run(ContainerCommandFactory.deleteContainer(id, force: true), timeout: .seconds(30))
        }
        // Prune networks/volumes the plan may have created (best-effort).
        _ = try? await client.run(ContainerCommandFactory.pruneNetworks(), timeout: .seconds(30))
        _ = try? await client.run(ContainerCommandFactory.pruneVolumes(), timeout: .seconds(30))
    }
}
