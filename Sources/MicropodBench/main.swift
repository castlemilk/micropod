import Foundation
import MicropodCore
import MicropodRuntime

// MicropodBench — performance validation against the real Apple `container`
// runtime. Measures the exact paths the app polls every few seconds:
//
//   1. CLI round-trips      (status/df/list/stats …)
//   2. Decode + map CPU     (raw CLI output → proto models)
//   3. Poll cycle e2e       (list → decode → map)
//   4. Streaming throughput (logs follow lines/sec, pull events/sec)
//   5. Lifecycle ops        (run/start/stop/delete)
//   6. MCP tool latency     (JSON-RPC round-trips over stdio)
//   7. Scale                (100/1000-container decode+map)
//
// Every section prints p50/p95/max and a PASS/FAIL against a threshold.
// Exit code is non-zero if any check fails.

// MARK: - Timing helpers

struct Stats {
    let name: String
    let samples: [Double]  // milliseconds
    let thresholdMs: Double?

    var sorted: [Double] { samples.sorted() }
    func percentile(_ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let index = Int((Double(sorted.count) - 1) * p)
        return sorted[index]
    }
    var p50: Double { percentile(0.50) }
    var p95: Double { percentile(0.95) }
    var max: Double { sorted.last ?? 0 }
    var mean: Double { samples.reduce(0, +) / Double(Swift.max(1, samples.count)) }

    var passed: Bool? {
        guard let thresholdMs else { return nil }
        return p95 <= thresholdMs
    }

    func render() -> String {
        let verdict: String
        if let passed {
            verdict = passed ? "PASS" : "FAIL"
        } else {
            verdict = "  –"
        }
        return String(
            format: "  [%@] %@ p50 %8.2f ms   p95 %8.2f ms   max %8.2f ms   mean %8.2f ms  (n=%d%@)",
            verdict, name.padding(toLength: 34, withPad: " ", startingAt: 0),
            p50, p95, max, mean, samples.count,
            thresholdMs.map { String(format: "  ≤%.0f ms", $0) } ?? "")
    }
}

func measure(
    _ name: String, warmup: Bool = true, iterations: Int = 15, thresholdMs: Double? = nil,
    _ body: () async throws -> Void
) async throws -> Stats {
    if warmup {
        try await body()
    }
    var samples: [Double] = []
    for _ in 0..<iterations {
        let clock = ContinuousClock()
        let start = clock.now
        try await body()
        let elapsed = start.duration(to: clock.now)
        samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    return Stats(name: name, samples: samples, thresholdMs: thresholdMs)
}

// MARK: - Environment

struct Environment {
    let client: ContainerCLIClient
    let system: SystemService
    let containers: ContainerService
    let images: ImageService
    let volumes: VolumeService
    let networks: NetworkService
    let stats: StatsSampler
    let logs: LogStreamer
    let compose: ComposeService
    let namespace: String

    static func live() throws -> Environment {
        let client = ContainerCLIClient()
        guard client.isAvailable() else {
            throw MicropodError.message("`container` CLI not available")
        }
        return Environment(
            client: client,
            system: SystemService(client: client),
            containers: ContainerService(client: client),
            images: ImageService(client: client),
            volumes: VolumeService(client: client),
            networks: NetworkService(client: client),
            stats: StatsSampler(client: client),
            logs: LogStreamer(client: client),
            compose: ComposeService(client: client),
            namespace: "micropod-bench-\(UUID().uuidString.prefix(6).lowercased())")
    }

    func cleanup() async {
        if let listed = try? await containers.list() {
            // Remove this run's namespace AND any leftovers from interrupted
            // runs (shared "micropod-bench" prefix).
            for c in listed where c.id.hasPrefix("micropod-bench") {
                _ = try? await containers.delete(c.id, force: true)
            }
        }
    }
}

// MARK: - Scale fixture generation (mock-shape container records)

func makeContainerJSON(count: Int) -> Data {
    var records: [String] = []
    for i in 0..<count {
        records.append(
            """
            {"configuration":{"creationDate":"2026-08-15T00:00:00Z","id":"bench-\(i)","image":{"descriptor":{"digest":"sha256:mock","mediaType":"application/vnd.oci.image.index.v1+json","size":856},"reference":"docker.io/library/alpine:3.20"},"labels":{"app":"bench"},"mounts":[],"networks":[{"network":"default","options":{}}],"platform":{"architecture":"arm64","os":"linux"},"resources":{"cpuOverhead":1,"cpus":1,"memoryInBytes":1073741824},"rosetta":false,"readOnly":false,"runtimeHandler":"","ssh":false,"useInit":false,"virtualization":false,"initProcess":{"environment":[],"executable":"/bin/sh","terminal":false,"workingDirectory":"","user":{"id":{"uid":0,"gid":0}}}},"id":"bench-\(i)","status":{"networks":[{"network":"default","hostname":"bench-\(i)","ipv4Address":"192.168.64.\(10 + i % 200)/24","ipv4Gateway":"192.168.64.1"}],"state":"running"}}
            """
        )
    }
    return Data(("[\(records.joined(separator: ","))]").utf8)
}

// MARK: - Main

@main
struct MicropodBench {
    static func main() async {
        do {
            try await run()
        } catch {
            print("BENCH ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        print("bench starting", terminator: "\n")
        fflush(stdout)
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = try Environment.live()
        // Clean any leftovers from a previous interrupted run.
        await env.cleanup()
        defer { Task { await env.cleanup() } }

        var allStats: [Stats] = []
        var failures = 0

        func section(_ title: String) {
            print("\n=== \(title) ===")
        }

        // Host info
        print("Machine: \(Sysctl.machine) · \(Sysctl.cpuCount) cores · macOS \(Sysctl.osVersion)")

        // 1. CLI round-trips -------------------------------------------------
        section("CLI round-trips (real runtime)")
        let cliSection = try await resilientSection { sectionBody in
            for (name, threshold, body) in [
                ("system status", 750.0, { try await env.system.status() } as () async throws -> Void),
                ("system df", 750.0, { _ = try await env.system.diskUsage() }),
                ("container list", 750.0, { _ = try await env.containers.list() }),
                ("image list --verbose", 750.0, { _ = try await env.images.list() }),
                ("volume list", 750.0, { _ = try await env.volumes.list() }),
                ("network list", 750.0, { _ = try await env.networks.list() }),
                ("stats --no-stream", 3500.0, { _ = try await env.stats.snapshot() }),
            ] {
                let s = try await measure(name, iterations: 15, thresholdMs: threshold, body)
                sectionBody(s)
            }
        }
        allStats += cliSection.stats
        failures += cliSection.failures
        // 2. Decode + map CPU ------------------------------------------------
        section("Decode + map (app CPU cost per poll)")
        let realList = try await env.client.run(ContainerCommandFactory.listContainers(all: true))
        let listData = Data(realList.utf8)
        let realImages = try await env.client.run(ContainerCommandFactory.listImages(verbose: true))
        let imagesData = Data(realImages.utf8)

        let decodeList = try await measure(
            "decode+map \(env.containersCountHint(listData)) containers", iterations: 200, thresholdMs: 5
        ) {
            let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: listData, context: "bench")
            _ = entries.map(ModelMapper.container(from:))
        }
        allStats.append(decodeList)
        print(decodeList.render())
        if decodeList.passed == false { failures += 1 }

        let decodeImages = try await measure("decode+map images", iterations: 200, thresholdMs: 5) {
            let entries = try MicropodJSON.decodeArray(ImageListEntry.self, from: imagesData, context: "bench")
            _ = entries.map(ModelMapper.image(from:))
        }
        allStats.append(decodeImages)
        print(decodeImages.render())
        if decodeImages.passed == false { failures += 1 }

        // 3. Poll cycle e2e --------------------------------------------------
        section("Poll cycle end-to-end (list → decode → map)")
        let poll = try await measure("container list poll cycle", iterations: 20, thresholdMs: 1500) {
            _ = try await env.containers.list()
        }
        allStats.append(poll)
        print(poll.render())
        if poll.passed == false { failures += 1 }

        // 4. Streaming throughput --------------------------------------------
        section("Streaming throughput")
        // Logs follow: ticking container writing ~10 lines/sec.
        let logContainer = try await withRetry {
            try await env.containers.run(
                ContainerRunRequest(
                    image: "alpine:3.20",
                    name: "\(env.namespace)-ticker",
                    arguments: ["sh", "-c", "while true; do echo x; done"]))
        }
        try await Task.sleep(for: .seconds(2))
        let logLines = await measureLines { env.logs.stream(id: logContainer, tail: 0, boot: false) }
        print(
            String(
                format: "  [%@] %@ %8.0f lines/sec (%.0f lines in 3s)",
                logLines.rate >= 1000 ? "PASS" : "FAIL",
                "logs -f throughput".padding(toLength: 34, withPad: " ", startingAt: 0),
                logLines.rate, Double(logLines.count)))
        if logLines.rate < 1000 { failures += 1 }

        // 5. Lifecycle ops ---------------------------------------------------
        section("Container lifecycle (real runtime, alpine cached)")
        let lifecycleSection = await resilientSection { emit in
            let runTime = try await measure("container run (detach)", warmup: true, iterations: 3, thresholdMs: 10_000)
            {
                _ = try await env.containers.run(
                    ContainerRunRequest(
                        image: "alpine:3.20",
                        name: "\(env.namespace)-life-\(UUID().uuidString.prefix(6))",
                        arguments: ["sleep", "120"]))
            }
            emit(runTime)

            let lifecycleID = try await env.containers.run(
                ContainerRunRequest(
                    image: "alpine:3.20",
                    name: "\(env.namespace)-lifecycle",
                    arguments: ["sleep", "300"]))
            try await Task.sleep(for: .seconds(2))
            // `container stop --time 10` burns the FULL grace on this runtime
            // (~10-14s observed), then start adds ~1-2s — a runtime characteristic,
            // not an app regression. Budget 20s and flag anything worse.
            let stopTime = try await measure("stop+start", warmup: false, iterations: 5, thresholdMs: 20000) {
                try await env.containers.stop(lifecycleID)
                try await env.containers.start(lifecycleID)
            }
            emit(stopTime)

            // Clean up the lifecycle containers so later sections measure a quiet runtime.
            if let listed = try? await env.containers.list() {
                for c in listed where c.id.hasPrefix(env.namespace) {
                    _ = try? await env.containers.delete(c.id, force: true)
                }
            }
            let deleteTime = try await measure("delete (run+rm)", warmup: false, iterations: 5, thresholdMs: 5000) {
                let id = try await env.containers.run(
                    ContainerRunRequest(
                        image: "alpine:3.20",
                        name: "\(env.namespace)-del-\(UUID().uuidString.prefix(6))",
                        arguments: ["sleep", "5"]))
                try await env.containers.delete(id, force: true)
            }
            emit(deleteTime)
        }
        allStats += lifecycleSection.stats
        failures += lifecycleSection.failures

        // 5b. Native backend head-to-head ------------------------------------
        // Same operations through the XPC path vs the CLI spawn path.
        // The native service needs a live apiserver; skip quietly when the
        // ping fails (e.g. runtime stopped).
        section("Native backend vs CLI (same ops, both paths)")
        let nativeSection = await resilientSection { emit in
            let api = APIServerClient()
            _ = try await api.ping(timeout: .seconds(10))
            let native = NativeContainerService(api: api, cli: env.containers)

            func pair(
                _ name: String, iterations: Int = 15, thresholdMs: Double? = nil,
                cli cliBody: @escaping () async throws -> Void,
                native nativeBody: @escaping () async throws -> Void
            ) async throws {
                emit(
                    try await measure(
                        "\(name) [cli]", iterations: iterations, thresholdMs: thresholdMs, cliBody))
                emit(
                    try await measure(
                        "\(name) [native]", iterations: iterations, thresholdMs: thresholdMs, nativeBody))
            }

            try await pair(
                "container list",
                cli: { _ = try await env.containers.list() },
                native: { _ = try await native.list() })

            // Shared fixture for inspect/exec/stats.
            let fixture = try await native.run(
                ContainerRunRequest(
                    image: "alpine:3.20",
                    name: "\(env.namespace)-nv",
                    arguments: ["sleep", "300"]))
            try await Task.sleep(for: .seconds(2))

            try await pair(
                "container inspect",
                cli: { _ = try await env.containers.inspect(fixture) },
                native: { _ = try await native.inspect(fixture) })

            try await pair(
                "exec echo (exit code)",
                cli: {
                    _ = try await env.containers.exec(
                        ContainerExecRequest(containerID: fixture, arguments: ["echo", "x"]))
                },
                native: {
                    _ = try await native.exec(
                        ContainerExecRequest(containerID: fixture, arguments: ["echo", "x"]))
                })

            try await pair(
                "stats sample",
                cli: { _ = try await env.stats.snapshot() },
                native: { _ = try await NativeStatsSampler(api: api).snapshot() })

            // Concurrency: 8 execs at once — spawn contention vs one
            // persistent XPC connection.
            func exec8(_ svc: any ContainerServing) async throws {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            _ = try await svc.exec(
                                ContainerExecRequest(containerID: fixture, arguments: ["echo", "x"]))
                        }
                    }
                    try await group.waitForAll()
                }
            }
            try await pair(
                "exec ×8 concurrent", iterations: 5,
                cli: { try await exec8(env.containers) },
                native: { try await exec8(native) })

            // Full cycle: create → bootstrap → start → delete.
            func cycle(_ svc: any ContainerServing) async throws {
                let id = try await svc.run(
                    ContainerRunRequest(
                        image: "alpine:3.20",
                        name: "\(env.namespace)-cyc-\(UUID().uuidString.prefix(6))",
                        arguments: ["sleep", "60"]))
                try await svc.delete(id, force: true)
            }
            try await pair(
                "run -d + delete cycle", iterations: 3,
                cli: { try await cycle(env.containers) },
                native: { try await cycle(native) })

            // 5c. Cache-mount strategies ----------------------------------
            // CI-cache patterns: virtiofs shared dir vs ext4 named volume
            // vs APFS-cloned golden (nosync). Workload = 500 small-file
            // creates + full stat/read sweep + 64MB write + sync — the
            // metadata-heavy shape package-manager caches produce.
            let sharedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(env.namespace)-shared", isDirectory: true)
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            let volName = "\(env.namespace)-vol"
            let goldName = "\(env.namespace)-golden"
            _ = try await api.getOrCreateVolume(name: volName)
            _ = try await api.getOrCreateVolume(name: goldName)

            let workload = """
                cd /cache && rm -rf w && mkdir w && cd w && \
                for i in $(seq 1 500); do echo "d$i" > f$i.txt; done && \
                cat *.txt > /dev/null && \
                dd if=/dev/zero of=big bs=1M count=64 2>/dev/null && sync
                """

            struct Strategy {
                let name: String
                let volumes: [String]
                let labels: [LabelSpec]
            }
            let strategies = [
                Strategy(
                    name: "virtiofs shared dir",
                    volumes: ["\(sharedDir.path):/cache"], labels: []),
                Strategy(
                    name: "ext4 volume (fsync)",
                    volumes: ["\(volName):/cache"], labels: []),
                Strategy(
                    name: "ext4 clone (nosync)",
                    volumes: ["\(goldName):/cache"],
                    labels: [LabelSpec(key: "com.micropod.cache.clone", value: goldName)]),
            ]
            for strategy in strategies {
                let cid = try await native.run(
                    ContainerRunRequest(
                        image: "alpine:3.20",
                        name: "\(env.namespace)-cm-\(UUID().uuidString.prefix(6).lowercased())",
                        volumes: strategy.volumes,
                        labels: strategy.labels,
                        arguments: ["sleep", "300"]))
                let s = try await measure(
                    "meta+io: \(strategy.name)", warmup: true, iterations: 3
                ) {
                    _ = try await native.exec(
                        ContainerExecRequest(
                            containerID: cid,
                            arguments: ["sh", "-c", workload]))
                }
                emit(s)
                try await native.delete(cid, force: true)
            }

            // Clone cost itself — should be O(1) regardless of golden size.
            if let golden = try await api.volumeInspect(name: goldName),
                case .object(let goldenObj) = golden,
                case .string(let src)? = goldenObj["source"]
            {
                var s = try await measure("clonefile golden → clone", warmup: true, iterations: 10) {
                    _ = try NativeContainerService.cloneVolumeImage(
                        source: src, containerID: "bench-clone-probe", volume: goldName)
                }
                emit(s)

                // Grow the golden to ~256MB and re-measure — APFS CoW must
                // keep clone cost flat as the golden grows.
                let grower = try await native.run(
                    ContainerRunRequest(
                        image: "alpine:3.20",
                        name: "\(env.namespace)-grow-\(UUID().uuidString.prefix(6).lowercased())",
                        volumes: ["\(goldName):/cache"],
                        arguments: [
                            "sh", "-c",
                            "dd if=/dev/zero of=/cache/fill bs=1M count=256 2>/dev/null && sync",
                        ]))
                for _ in 0..<60 {
                    let st = try await api.list()
                    let entries = try MicropodJSON.decodeArray(
                        ContainerListEntry.self, from: st, context: "list")
                    if entries.first(where: { $0.id == grower })?.status.state != "running" { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                try await native.delete(grower, force: true)
                s = try await measure("clonefile 256MB golden → clone", warmup: false, iterations: 10) {
                    _ = try NativeContainerService.cloneVolumeImage(
                        source: src, containerID: "bench-clone-probe", volume: goldName)
                }
                emit(s)
                try? FileManager.default.removeItem(
                    at: NativeContainerService.cloneRoot.appendingPathComponent("bench-clone-probe"))
            }

            // Create-path overhead: cloning create vs plain named-volume
            // create — isolates policy+list+inspect+clonefile cost from
            // the VM-boot work that `run` adds.
            func createOnce(_ labels: [LabelSpec], _ volume: String) async throws {
                let id = try await native.create(
                    ContainerRunRequest(
                        image: "alpine:3.20",
                        name: "\(env.namespace)-co-\(UUID().uuidString.prefix(6).lowercased())",
                        volumes: ["\(volume):/cache"],
                        labels: labels,
                        arguments: ["sleep", "300"]))
                try await native.delete(id, force: true)
            }
            emit(
                try await measure("create+delete: plain volume", warmup: true, iterations: 3) {
                    try await createOnce([], volName)
                })
            emit(
                try await measure(
                    "create+delete: clone", warmup: true, iterations: 3
                ) {
                    try await createOnce(
                        [LabelSpec(key: "com.micropod.cache.clone", value: goldName)], goldName)
                })

            // Fan-out: 4 concurrent creates cloning the same golden —
            // throughput + the concurrent-create path (sweep included).
            emit(
                try await measure("clone create ×4 concurrent", warmup: false, iterations: 3) {
                    try await withThrowingTaskGroup(of: String.self) { group in
                        for _ in 0..<4 {
                            group.addTask {
                                try await native.create(
                                    ContainerRunRequest(
                                        image: "alpine:3.20",
                                        name: "mpb-fan-\(UUID().uuidString.prefix(8).lowercased())",
                                        volumes: ["\(goldName):/cache"],
                                        labels: [
                                            LabelSpec(
                                                key: "com.micropod.cache.clone", value: goldName)
                                        ],
                                        arguments: ["sleep", "300"]))
                            }
                        }
                        var ids: [String] = []
                        for try await id in group { ids.append(id) }
                        for id in ids { try await native.delete(id, force: true) }
                    }
                })
            _ = try? await env.client.run(
                ContainerCommandFactory.deleteVolume(volName), timeout: .seconds(15))
            _ = try? await env.client.run(
                ContainerCommandFactory.deleteVolume(goldName), timeout: .seconds(15))
            try? FileManager.default.removeItem(at: sharedDir)

            try await native.delete(fixture, force: true)
        }
        allStats += nativeSection.stats
        failures += nativeSection.failures

        // 6. MCP latency -----------------------------------------------------
        section("MCP tool latency (stdio JSON-RPC)")
        let mcp = try await MCPSession.launch()
        let mcpInit = try await measure("initialize", warmup: false, iterations: 10, thresholdMs: 500) {
            _ = try await mcp.call("initialize", params: "{}")
        }
        allStats.append(mcpInit)
        print(mcpInit.render())
        if mcpInit.passed == false { failures += 1 }

        let mcpStatus = try await measure("tools/call status", warmup: false, iterations: 10, thresholdMs: 1500) {
            _ = try await mcp.call("tools/call", params: #"{"name":"status","arguments":{}}"#)
        }
        allStats.append(mcpStatus)
        print(mcpStatus.render())
        if mcpStatus.passed == false { failures += 1 }

        let mcpContainers = try await measure(
            "tools/call list_containers", warmup: false, iterations: 10, thresholdMs: 1500
        ) {
            _ = try await mcp.call("tools/call", params: #"{"name":"list_containers","arguments":{}}"#)
        }
        allStats.append(mcpContainers)
        print(mcpContainers.render())
        if mcpContainers.passed == false { failures += 1 }
        mcp.close()

        // 7. Scale -----------------------------------------------------------
        section("Scale (decode+map cost with N containers)")
        for count in [100, 1000] {
            let data = makeContainerJSON(count: count)
            let s = try await measure(
                "decode+map \(count) containers", warmup: true, iterations: 50, thresholdMs: count == 100 ? 10 : 100
            ) {
                let entries = try MicropodJSON.decodeArray(ContainerListEntry.self, from: data, context: "bench")
                _ = entries.map(ModelMapper.container(from:))
            }
            allStats.append(s)
            print(s.render())
            if s.passed == false { failures += 1 }
        }

        // Summary ------------------------------------------------------------
        print("\n=== Summary ===")
        let checked = allStats.filter { $0.passed != nil }
        let passed = checked.filter { $0.passed == true }.count
        print("\(passed)/\(checked.count) threshold checks passed (\(failures) failed)")
        if failures > 0 {
            print("FAILED: \(allStats.filter { $0.passed == false }.map(\.name).joined(separator: ", "))")
            exit(1)
        }
        print("All benchmarks within budget.")
    }
}

/// Runs a benchmark section; a thrown error becomes a FAIL row instead of
/// aborting the whole report.
struct SectionResult {
    var stats: [Stats] = []
    var failures = 0
}

func resilientSection(
    _ body: (_ emit: (Stats) -> Void) async throws -> Void
) async -> SectionResult {
    var result = SectionResult()
    do {
        try await body { stats in
            result.stats.append(stats)
            print(stats.render())
            if stats.passed == false { result.failures += 1 }
        }
    } catch {
        let s = Stats(
            name: "section error", samples: [], thresholdMs: nil)
        _ = s
        print("  [FAIL] section aborted: \(error.localizedDescription)")
        result.failures += 1
    }
    return result
}

/// Retries an operation that can transiently fail (VM bootstrap flakiness).
func withRetry<T>(attempts: Int = 2, _ body: () async throws -> T) async throws -> T {
    var lastError: Error?
    for _ in 0..<attempts {
        do { return try await body() } catch {
            lastError = error
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }
    throw lastError ?? MicropodError.message("retry exhausted")
}

// MARK: - Streaming measurement helpers

struct Rate {
    let count: Int
    let rate: Double  // per second
}

func measureLines(_ open: () -> AsyncThrowingStream<LogLine, Error>) async -> Rate {
    let stream = open()
    let task = Task { () -> Int in
        var count = 0
        do {
            for try await _ in stream { count += 1 }
        } catch {}
        return count
    }
    try? await Task.sleep(for: .seconds(3))
    task.cancel()
    let count = (try? await task.value) ?? 0
    return Rate(count: count, rate: Double(count) / 3.0)
}

func measurePullEvents(_ open: () -> AsyncThrowingStream<ProgressEvent, Error>) async -> Rate {
    let stream = open()
    let task = Task { () -> Int in
        var count = 0
        do {
            for try await _ in stream { count += 1 }
        } catch {}
        return count
    }
    try? await Task.sleep(for: .seconds(3))
    task.cancel()
    let count = (try? await task.value) ?? 0
    return Rate(count: count, rate: Double(count) / 3.0)
}

// MARK: - MCP stdio client

final class MCPSession {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var nextID = 1

    static func launch() throws -> MCPSession {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // main.swift
            .deletingLastPathComponent()  // MicropodBench/
            .deletingLastPathComponent()  // Sources/
            .appendingPathComponent(".build/debug/MicropodMCP")
        let process = Process()
        process.executableURL = url
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        return MCPSession(
            process: process, stdin: stdinPipe.fileHandleForWriting, stdout: stdoutPipe.fileHandleForReading)
    }

    private init(process: Process, stdin: FileHandle, stdout: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
    }

    func call(_ method: String, params: String) throws -> String {
        let id = nextID
        nextID += 1
        try stdin.write(
            contentsOf: Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}\n".utf8))
        var buffer = Data()
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty { throw MicropodError.message("MCP closed") }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<newline], encoding: .utf8) ?? ""
            }
        }
    }

    func close() {
        try? stdin.close()
        process.terminate()
    }
}

// MARK: - System info helpers

enum Sysctl {
    static var machine: String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
    static var cpuCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

extension Environment {
    func containersCountHint(_ data: Data) -> Int {
        (try? MicropodJSON.decodeArray(ContainerListEntry.self, from: data, context: "count"))?.count ?? 0
    }
}
