import Foundation
import MicropodCore
import MicropodRuntime

/// Route + JSON-projection layer over the MicropodCore services.
/// Responses use stable JSON keys that mirror the curated proto models.
struct APIHandlers {
    let client: ContainerCLIClient
    let system: SystemService
    let containers: any ContainerServing
    let images: ImageService
    let volumes: VolumeService
    let networks: NetworkService
    let stats: any StatsSampling
    let logs: any LogStreaming
    let compose: ComposeService
    /// Native apiserver client when the native backend is active —
    /// powers the vsock bridge endpoint.
    let api: APIServerClient?
    /// Which runtime backend resolved at startup (native XPC vs CLI).
    var backend: RuntimeBackendKind = .cli
    /// Apiserver identity from the resolve-time ping, when known.
    var runtimeHealth: APIServerHealth?
    let metrics = APIMetrics()
    let appControl = AppControlClient()
    var k8s: K8sService {
        K8sService(client: client)
    }
    var usage: UsageService {
        UsageService(containers: containers, images: images, volumes: volumes)
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let started = Date()
        let resp = await handleInner(request)
        let elapsed = Date().timeIntervalSince(started)
        metrics.record(
            route: request.path.isEmpty ? "/" : request.path,
            method: request.method.rawValue,
            status: Self.status(of: resp),
            duration: elapsed
        )
        return resp
    }

    private static func status(of resp: HTTPResponse) -> Int {
        switch resp {
        case .json(let code, _): return code
        case .text(let code, _): return code
        case .data(let code, _, _): return code
        case .stream(let code, _, _): return code
        case .bridge(let code, _): return code
        }
    }

    private func handleInner(_ request: HTTPRequest) async -> HTTPResponse {
        // /metrics — Prometheus text format, always 200
        if request.path == "/metrics" {
            return .text(200, metrics.render())
        }

        let path = request.path
        let method = request.method
        let segments = path.split(separator: "/").map(String.init)

        // CORS preflight — the Allow-* headers are attached by dispatch.
        if method == .options {
            return .data(204, "text/plain", Data())
        }

        // /health
        if path == "/health" || path == "/" {
            return HTTPResponse.json(200, ["status": "ok"])
        }

        // Connect-protocol mount — proto-JSON over POST. The daemon API is
        // grouped into per-domain services (micropod.v1.ContainerService, …);
        // the pre-split micropod.v1.MicropodService prefix is kept as an
        // alias so v0.8 SDK clients keep working — method names are unique
        // across services, so dispatch never needs the service segment.
        if segments.count == 3, segments[0] == "api",
            segments[1].hasPrefix("micropod.v1."), method == .post,
            let resp = await connectRPC(method: segments[2], body: request.body)
        {
            return resp
        }

        guard segments.first == "v1" else { return .json(404, ["error": "not found"]) }
        let resource = segments.count > 1 ? segments[1] : ""

        do {
            switch (resource, method) {
            // MARK: System
            case ("usage", .get):
                let report = try await usage.report()
                return .json(
                    200,
                    [
                        "images": report.images.map { entry -> [String: Any] in
                            [
                                "id": entry.image.id,
                                "names": entry.image.names,
                                "sizeBytes": entry.image.sizeBytes,
                                "createdAt": entry.image.createdAt,
                                "usedByContainerIDs": entry.usedByContainerIDs,
                                "inUse": entry.inUse,
                            ]
                        },
                        "volumes": report.volumes.map { entry -> [String: Any] in
                            [
                                "id": entry.volume.id,
                                "sizeBytes": entry.volume.sizeBytes,
                                "createdAt": entry.volume.createdAt,
                                "usedByContainerIDs": entry.usedByContainerIDs,
                                "inUse": entry.inUse,
                            ]
                        },
                        "reclaimableImageBytes": report.reclaimableImageBytes,
                        "reclaimableVolumeBytes": report.reclaimableVolumeBytes,
                        "stoppedContainerCount": report.stoppedContainerCount,
                    ])
            // MARK: App updates (Sparkle lives in the app process; the
            // control socket reaches it). 503 when the app isn't running.
            case ("system", .post) where segments.count == 3 && segments[2] == "update":
                guard appControl.isReachable else {
                    return .json(503, ["error": "Micropod app is not running (no control socket)"])
                }
                let report = try await appControl.checkForUpdates()
                return .json(202, report)

            case ("system", .post)
            where segments.count == 4 && segments[2] == "update"
                && segments[3] == "apply":
                guard appControl.isReachable else {
                    return .json(503, ["error": "Micropod app is not running (no control socket)"])
                }
                do {
                    let report = try await appControl.applyUpdate()
                    return .json(202, report)
                } catch AppControlError.callFailed(let message) {
                    return .json(409, ["error": message])
                }

            case ("system", .get) where segments.count == 3 && segments[2] == "update":
                guard appControl.isReachable else {
                    return .json(503, ["error": "Micropod app is not running (no control socket)"])
                }
                let report = try await appControl.updateStatus()
                return .json(200, report)

            case ("system", .get):
                let status = try await system.status()
                let usage = try await system.diskUsage()
                var body: [String: Any] = [
                    "status": status.status,
                    "cliVersion": status.cliVersion,
                    "apiServerVersion": status.apiServerVersion,
                    "appRoot": status.appRoot,
                    "backend": backend.rawValue,
                    "diskUsage": projection(usage),
                ]
                if let runtimeHealth {
                    body["runtimeVersion"] = runtimeHealth.semver ?? runtimeHealth.apiServerVersion
                    body["runtimeCommit"] = runtimeHealth.apiServerCommit
                }
                return .json(200, body)

            // MARK: Containers
            case ("containers", .get) where segments.count == 2:
                let list = try await containers.list()
                return .json(200, ["containers": list.map(projection)])

            case ("containers", .post) where segments.count == 2:
                let id = try await containers.run(try runRequest(from: request.body))
                return .json(201, ["id": id])

            case ("containers", .post) where segments.count == 3 && segments[2] == "create":
                let id = try await containers.create(try runRequest(from: request.body))
                return .json(201, ["id": id])

            case ("containers", .post)
            where segments.count == 4 && ["start", "stop", "restart", "kill"].contains(segments[3]):
                let id = segments[2]
                switch segments[3] {
                case "start": try await containers.start(id)
                case "stop": try await containers.stop(id)
                case "restart": try await containers.restart(id)
                default: try await containers.kill(id)
                }
                return .json(200, ["id": id, "action": segments[3]])

            case ("containers", .delete) where segments.count == 3:
                let id = segments[2]
                try await containers.delete(id, force: request.query["force"] == "true")
                return .json(200, ["deleted": id])

            // GET /v1/containers/:id/vsock/:port — raw duplex byte stream to
            // a guest vsock port. After the 200 head the connection is a
            // net.Conn-equivalent; run gRPC (vminitd on :1024) over it.
            case ("containers", .get)
            where segments.count == 5 && segments[3] == "vsock":
                guard let api else {
                    return .json(
                        501, ["error": "vsock bridge requires the native runtime backend"])
                }
                let id = segments[2]
                guard let port = UInt32(segments[4]) else {
                    return .json(400, ["error": "invalid vsock port '\(segments[4])'"])
                }
                let vsock = try await api.dial(id: id, port: port)
                return .bridge(200) { connection in
                    await VsockBridge.attach(connection: connection, vsock: vsock)
                }

            case ("containers", .get) where segments.count == 4 && segments[3] == "logs":
                let id = segments[2]
                let tail = Int(request.string("tail")) ?? 100
                let stream = logs.stream(id: id, tail: tail, boot: request.string("boot") == "true")
                return .stream(
                    200, "text/event-stream",
                    AsyncStream { continuation in
                        Task {
                            do {
                                for try await line in stream {
                                    let payload =
                                        "data: " + (line.text.replacingOccurrences(of: "\n", with: "\\n")) + "\n\n"
                                    continuation.yield(Data(payload.utf8))
                                }
                            } catch {}
                            continuation.finish()
                        }
                    })

            // MARK: Images
            case ("images", .get) where segments.count == 2:
                let list = try await images.list()
                return .json(200, ["images": list.map(projection)])

            case ("images", .post) where segments.count == 3 && segments[2] == "pull":
                let payload = try decodeBody(request.body)
                let reference = payload["reference"] as? String ?? ""
                guard !reference.isEmpty else { return .json(400, ["error": "reference is required"]) }
                var lastLine = ""
                for try await event in images.pull(reference, platform: nil) {
                    lastLine = event.line
                }
                return .json(200, ["pulled": reference, "lastLine": lastLine])

            case ("images", .delete) where segments.count == 3:
                let reference = segments[2].removingPercentEncoding ?? segments[2]
                try await images.delete(reference, force: request.query["force"] == "true")
                return .json(200, ["deleted": reference])

            // MARK: Volumes
            case ("volumes", .get) where segments.count == 2:
                let list = try await volumes.list()
                return .json(200, ["volumes": list.map(projection)])

            case ("volumes", .post) where segments.count == 2:
                let payload = try decodeBody(request.body)
                let name = payload["name"] as? String ?? ""
                guard !name.isEmpty else { return .json(400, ["error": "name is required"]) }
                try await volumes.create(name: name, size: payload["size"] as? String)
                return .json(201, ["name": name])

            case ("volumes", .delete) where segments.count == 3:
                let name = segments[2].removingPercentEncoding ?? segments[2]
                try await volumes.delete(name)
                return .json(200, ["deleted": name])

            // MARK: Volume policy (native backend mount handling)
            case ("config", .get) where segments.count == 3 && segments[2] == "volumes":
                return .json(200, Self.policyBody(VolumePolicyStore.load()))

            case ("config", .put) where segments.count == 3 && segments[2] == "volumes":
                guard let policy = try? JSONDecoder().decode(VolumePolicy.self, from: request.body)
                else {
                    return .json(
                        400,
                        [
                            "error":
                                "invalid policy — expected {cloneMode: labels|goldens|all, "
                                + "goldenVolumes: [name], jobsOnly: bool, sync: full|fsync|nosync, "
                                + "cache: on|off|auto}"
                        ])
                }
                try VolumePolicyStore.save(policy)
                return .json(200, Self.policyBody(policy))

            // MARK: Networks
            case ("networks", .get) where segments.count == 2:
                let list = try await networks.list()
                return .json(200, ["networks": list.map(projection)])

            case ("networks", .post) where segments.count == 2:
                let payload = try decodeBody(request.body)
                let name = payload["name"] as? String ?? ""
                guard !name.isEmpty else { return .json(400, ["error": "name is required"]) }
                try await networks.create(
                    name: name, internal: (payload["internal"] as? Bool) ?? false,
                    subnet: payload["subnet"] as? String)
                return .json(201, ["name": name])

            case ("networks", .delete) where segments.count == 3:
                let name = segments[2].removingPercentEncoding ?? segments[2]
                try await networks.delete(name)
                return .json(200, ["deleted": name])

            // MARK: Stats
            case ("stats", .get):
                let snapshot = try await stats.snapshot()
                return .json(200, ["containers": snapshot.containers.map(projection), "sampledAt": snapshot.sampledAt])

            // MARK: Compose
            case ("compose", .post) where segments.count == 3 && segments[2] == "up":
                let payload = try decodeBody(request.body)
                let path = payload["path"] as? String ?? ""
                guard !path.isEmpty else { return .json(400, ["error": "path is required"]) }
                let url = URL(fileURLWithPath: path)
                let spec = try await compose.parse(url: url)
                let profiles = Set(
                    (payload["profiles"] as? String ?? "").split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty })
                let plan = try compose.plan(spec: spec, enabledProfiles: profiles)
                var progress: [String] = []
                for try await line in compose.up(plan: plan) {
                    progress.append(line)
                }
                return .json(200, ["name": spec.name, "progress": progress])

            case ("compose", .post) where segments.count == 3 && segments[2] == "down":
                let payload = try decodeBody(request.body)
                let name = payload["name"] as? String ?? ""
                guard !name.isEmpty else { return .json(400, ["error": "name is required"]) }
                try await compose.down(composeName: name)
                return .json(200, ["toreDown": name])

            // MARK: Kubernetes (opt-in engine)
            case ("k8s", .get) where segments.count == 2:
                let config = k8s.loadConfig() ?? .defaults
                let s = try await k8s.status(name: config.clusterName)
                return .json(
                    200,
                    [
                        "enabled": k8s.isEnabled, "exists": s.exists, "running": s.running,
                        "address": s.address ?? "", "nodeReady": s.nodeReady,
                        "kubeconfigPath": s.kubeconfigPath,
                    ])

            case ("k8s", .get) where segments.count == 3 && segments[2] == "config":
                return .json(200, k8sConfigDict(k8s.loadConfig() ?? .defaults))

            case ("k8s", .post) where segments.count == 3 && segments[2] == "config":
                let payload = try decodeBody(request.body)
                var config = k8s.loadConfig() ?? .defaults
                if let v = payload["enabled"] as? Bool { config.enabled = v }
                if let v = payload["image"] as? String { config.image = v }
                if let v = payload["memory"] as? String { config.memory = v }
                if let v = payload["cpus"] as? Double { config.cpus = v }
                if let v = payload["metalLB"] as? Bool { config.metalLB = v }
                if let v = payload["ingress"] as? Bool { config.ingress = v }
                if let v = payload["lbPool"] as? String { config.lbPool = v }
                if let v = payload["clusterName"] as? String { config.clusterName = v }
                try k8s.saveConfig(config)
                return .json(200, k8sConfigDict(config))

            case ("k8s", .post) where segments.count == 3 && segments[2] == "up":
                guard k8s.isEnabled else {
                    return .json(
                        412,
                        [
                            "error":
                                "k8s engine is not enabled — POST /v1/k8s/config {enabled:true} or `micropod k8s enable`"
                        ])
                }
                let payload = try decodeBody(request.body)
                var config = k8s.loadConfig() ?? .defaults
                if let v = payload["image"] as? String { config.image = v }
                if let v = payload["memory"] as? String { config.memory = v }
                if let v = payload["cpus"] as? Double { config.cpus = v }
                if let v = payload["metalLB"] as? Bool { config.metalLB = v }
                if let v = payload["ingress"] as? Bool { config.ingress = v }
                if let v = payload["lbPool"] as? String { config.lbPool = v }
                if let v = payload["clusterName"] as? String { config.clusterName = v }
                final class Lines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = Lines()
                let s = try await k8s.up(config) { progress.items.append($0) }
                return .json(
                    200,
                    [
                        "progress": progress.items, "address": s.address ?? "",
                        "nodeReady": s.nodeReady, "kubeconfigPath": s.kubeconfigPath,
                    ])

            case ("k8s", .post) where segments.count == 3 && segments[2] == "down":
                guard k8s.isEnabled else {
                    return .json(412, ["error": "k8s engine is not enabled"])
                }
                let config = k8s.loadConfig() ?? .defaults
                try await k8s.down(config)
                return .json(200, ["removed": config.clusterName])

            case ("k8s", .get) where segments.count == 3 && segments[2] == "kubeconfig":
                guard let contents = try? String(contentsOf: k8s.kubeconfigURL, encoding: .utf8)
                else {
                    return .json(404, ["error": "no kubeconfig — POST /v1/k8s/up first"])
                }
                return .json(200, ["path": k8s.kubeconfigURL.path, "contents": contents])

            case ("k8s", .get) where segments.count == 3 && segments[2] == "images":
                let refs = try await k8s.listImages()
                return .json(200, ["refs": refs])

            case ("k8s", .post) where segments.count == 3 && segments[2] == "images":
                guard k8s.isEnabled else {
                    return .json(412, ["error": "k8s engine is not enabled"])
                }
                let payload = try decodeBody(request.body)
                let ref = payload["ref"] as? String
                let archive =
                    (payload["archive"] as? String).flatMap { Data(base64Encoded: $0) }
                guard ref != nil || archive != nil else {
                    return .json(
                        400,
                        [
                            "error":
                                "POST /v1/k8s/images needs {\"ref\": \"image:tag\"} or {\"archive\": \"<base64 tar>\"}"
                        ])
                }
                final class LoadLines: @unchecked Sendable {
                    var items: [String] = []
                }
                let progress = LoadLines()
                let loaded = try await k8s.loadImage(ref: ref, archiveData: archive) {
                    progress.items.append($0)
                }
                return .json(
                    200,
                    ["progress": progress.items, "ref": loaded.ref, "bytes": loaded.bytes])

            // MARK: Exec
            case ("exec", .post):
                let payload = try decodeBody(request.body)
                let id = payload["id"] as? String ?? ""
                let command = payload["command"] as? String ?? ""
                guard !id.isEmpty, !command.isEmpty else {
                    return .json(400, ["error": "id and command are required"])
                }
                let result = try await containers.execDetailed(
                    ContainerExecRequest(containerID: id, arguments: [command], workdir: payload["workdir"] as? String))
                return .json(
                    200,
                    [
                        "output": result.output,
                        "error": result.error,
                        "exitCode": result.exitCode,
                    ])

            default:
                return .json(404, ["error": "not found: \(method.rawValue) \(path)"])
            }
        } catch let error as AppControlError {
            // App down / socket broken / updater refused → service unavailable.
            return .json(503, ["error": error.localizedDescription])
        } catch let error as MicropodError {
            return .json(500, ["error": error.localizedDescription])
        } catch {
            return .json(500, ["error": error.localizedDescription])
        }
    }

    // MARK: - Body helpers

    private func decodeBody(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MicropodError.message("invalid JSON body")
        }
        return object
    }

    private func runRequest(from data: Data) throws -> ContainerRunRequest {
        let payload = try decodeBody(data)
        let env = (payload["env"] as? [String]) ?? []
        let ports: [PortSpec] = ((payload["ports"] as? [[String: Any]]) ?? []).compactMap { port in
            guard let containerPort = port["containerPort"] as? Int else { return nil }
            return PortSpec(
                hostPort: (port["hostPort"] as? Int) ?? 0,
                containerPort: containerPort,
                transportProtocol: (port["protocol"] as? String) ?? "tcp",
                hostIP: port["hostIP"] as? String)
        }
        let labels: [LabelSpec] = ((payload["labels"] as? [String: String]) ?? [:]).map {
            LabelSpec(key: $0.key, value: $0.value)
        }
        return ContainerRunRequest(
            image: payload["image"] as? String ?? "",
            name: payload["name"] as? String,
            detach: (payload["detach"] as? Bool) ?? true,
            cpus: payload["cpus"] as? Double,
            memory: payload["memory"] as? String,
            env: env,
            publishedPorts: ports,
            volumes: (payload["volumes"] as? [String]) ?? [],
            labels: labels,
            useInit: (payload["init"] as? Bool) ?? false,
            arguments: (payload["arguments"] as? [String]) ?? [])
    }

    // MARK: - JSON projections (proto → API JSON)

    /// `VolumePolicy` → response JSON (`sync` omitted when unset so the
    /// per-mount defaults are visible as "not overridden").
    private static func policyBody(_ policy: VolumePolicy) -> [String: Any] {
        var body: [String: Any] = [
            "cloneMode": policy.cloneMode.rawValue,
            "goldenVolumes": policy.goldenVolumes,
            "jobsOnly": policy.jobsOnly,
            "cache": policy.cache.rawValue,
            "labels": [
                "clone": "com.micropod.cache.clone",
                "sync": "com.micropod.volume.sync",
                "cache": "com.micropod.volume.cache",
            ],
        ]
        if let sync = policy.sync { body["sync"] = sync.rawValue }
        return body
    }

    private func k8sConfigDict(_ c: K8sConfig) -> [String: Any] {
        [
            "enabled": c.enabled, "image": c.image, "memory": c.memory,
            "cpus": c.cpus, "metalLB": c.metalLB, "ingress": c.ingress,
            "lbPool": c.lbPool ?? "", "clusterName": c.clusterName,
        ]
    }

    private func projection(_ container: Micropod_V1_Container) -> [String: Any] {
        [
            "id": container.id,
            "state": container.state,
            "image": container.image,
            "createdAt": container.createdAt,
            "ipv4Address": container.ipv4Address,
            "networks": container.networks,
            "env": container.env,
            "labels": container.labels,
            "platform": container.platform,
            "readOnly": container.readOnly,
            "useInit": container.useInit,
            "rosetta": container.rosetta,
            "ports": container.publishedPorts.map { port in
                [
                    "hostPort": port.hostPort, "containerPort": port.containerPort,
                    "protocol": port.`protocol`, "hostIP": port.hostIp,
                ]
            },
            "mounts": container.mounts.map { mount in
                [
                    "type": mount.type, "source": mount.source, "destination": mount.destination,
                    "readOnly": mount.readOnly,
                ]
            },
            "resources": ["cpus": container.resources.cpus, "memoryBytes": container.resources.memoryBytes],
        ]
    }

    private func projection(_ image: Micropod_V1_Image) -> [String: Any] {
        [
            "id": image.id,
            "names": image.names,
            "digest": image.digest,
            "sizeBytes": image.sizeBytes,
            "createdAt": image.createdAt,
            "variants": image.variants.map { variant in
                ["os": variant.os, "architecture": variant.architecture]
            },
        ]
    }

    private func projection(_ volume: Micropod_V1_Volume) -> [String: Any] {
        [
            "id": volume.id, "driver": volume.driver, "format": volume.format,
            "sizeBytes": volume.sizeBytes, "source": volume.source, "createdAt": volume.createdAt,
            "labels": volume.labels,
        ]
    }

    private func projection(_ network: Micropod_V1_Network) -> [String: Any] {
        [
            "id": network.id, "mode": network.mode, "plugin": network.plugin,
            "ipv4Subnet": network.ipv4Subnet, "ipv4Gateway": network.ipv4Gateway,
            "ipv6Subnet": network.ipv6Subnet, "createdAt": network.createdAt,
            "builtin": network.builtin, "labels": network.labels,
        ]
    }

    private func projection(_ stats: Micropod_V1_ContainerStats) -> [String: Any] {
        [
            "id": stats.id,
            "cpuPercent": stats.cpuPercent,
            "memoryUsedBytes": stats.memoryUsedBytes,
            "memoryLimitBytes": stats.memoryLimitBytes,
            "networkRxBytes": stats.networkRxBytes,
            "networkTxBytes": stats.networkTxBytes,
            "blockReadBytes": stats.blockReadBytes,
            "blockWriteBytes": stats.blockWriteBytes,
            "pids": stats.pids,
        ]
    }

    private func projection(_ usage: Micropod_V1_DiskUsage) -> [String: Any] {
        func category(_ c: Micropod_V1_DiskCategory) -> [String: Any] {
            [
                "total": c.total, "active": c.active, "sizeBytes": c.sizeBytes,
                "reclaimableBytes": c.reclaimableBytes,
            ]
        }
        return [
            "containers": category(usage.containers),
            "images": category(usage.images),
            "volumes": category(usage.volumes),
            "totalReclaimableBytes": usage.totalReclaimableBytes,
        ]
    }
}
