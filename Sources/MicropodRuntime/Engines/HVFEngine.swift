import Foundation
import MicropodCore

/// Experimental Rust Hypervisor.framework engine (`vmm/`).
///
/// This is deliberately **not** presented as container-capable yet. The Rust
/// VMM can boot and supervise a worker microVM, but it has no daemon-owned
/// container inventory, OCI rootfs/image pipeline, exec service, or stable
/// lifecycle API. Advertising it as a drop-in `ContainerServing` backend
/// would make the app, API and MCP silently accept lifecycle operations the
/// engine cannot honour. The engine is nevertheless listed so every surface
/// can report accurate installation/readiness state while the control plane
/// is built.
public struct HVFEngine: RuntimeEngine, ContainerServing, LogStreaming {
    public let root: URL

    public var name: String { "hvf" }
    public var kind: String { "microvm" }
    public var summary: String {
        "experimental Rust Hypervisor.framework worker engine — lifecycle control plane not yet available"
    }
    public var capabilities: [String] { [] }
    public var containers: any ContainerServing { self }
    public var logs: any LogStreaming { self }
    public var stats: (any StatsSampling)? { nil }

    public init(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
        } else if let configured = environment["MICROPOD_HVF_ROOT"], !configured.isEmpty {
            self.root = URL(fileURLWithPath: configured)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".micropod/hvf")
        }
    }

    private var binaryURL: URL { root.appendingPathComponent("micropod-vmm") }
    private var kernelURL: URL { root.appendingPathComponent("Image") }
    private var initrdURL: URL { root.appendingPathComponent("mp-hvf-init.cpio") }

    public func probe() async -> EngineProbe {
        var missing: [String] = []
        for (name, url) in [("micropod-vmm", binaryURL), ("Image", kernelURL), ("mp-hvf-init.cpio", initrdURL)] {
            if !FileManager.default.fileExists(atPath: url.path) { missing.append(name) }
        }
        if !missing.isEmpty {
            return EngineProbe(
                available: false,
                reason: "HVF worker assets missing: \(missing.joined(separator: ", "))",
                endpoint: root.path)
        }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return EngineProbe(available: false, reason: "micropod-vmm is not executable", endpoint: root.path)
        }
        return EngineProbe(
            available: false,
            reason: "assets present, but container lifecycle control plane is not implemented yet",
            endpoint: root.path)
    }

    public func owns(_ id: String) async -> Bool { false }

    private func unsupported(_ operation: String) -> MicropodError {
        .unsupported(
            "runtime 'hvf' cannot \(operation) yet: the Rust VMM is a worker microVM engine, "
                + "not yet a daemon-backed container lifecycle runtime")
    }

    // MARK: ContainerServing — explicit refusals rather than silent lifecycle loss

    public func list() async throws -> [Micropod_V1_Container] { [] }
    public func inspect(_ id: String) async throws -> Data { throw unsupported("inspect containers") }
    public func create(_ request: ContainerRunRequest) async throws -> String { throw unsupported("create containers") }
    public func run(_ request: ContainerRunRequest) async throws -> String { throw unsupported("run containers") }
    public func exec(_ request: ContainerExecRequest) async throws -> String { throw unsupported("exec in containers") }
    public func start(_ id: String) async throws { throw unsupported("start containers") }
    public func stop(_ id: String, timeout: Int) async throws { throw unsupported("stop containers") }
    public func restart(_ id: String) async throws { throw unsupported("restart containers") }
    public func stopAll() async throws {}
    public func kill(_ id: String, signal: String) async throws { throw unsupported("kill containers") }
    public func delete(_ id: String, force: Bool) async throws { throw unsupported("delete containers") }
    public func deleteAll(force: Bool) async throws {}
    public func prune() async throws -> String { "hvf: no containers" }
    public func export(_ id: String, to outputPath: String) async throws { throw unsupported("export containers") }
    public func copy(from: String, to: String) async throws { throw unsupported("copy container files") }

    // MARK: LogStreaming

    public func stream(id: String, tail: Int?, boot: Bool) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: unsupported("stream container logs"))
        }
    }

    public func tail(id: String, lines: Int, boot: Bool) async throws -> [LogLine] {
        throw unsupported("read container logs")
    }
}
