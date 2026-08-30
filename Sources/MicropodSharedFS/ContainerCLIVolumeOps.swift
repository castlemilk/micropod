import Foundation

/// `VolumeContainerOps` backed by the Apple `container` CLI.
public struct ContainerCLIVolumeOps: VolumeContainerOps {
    public let cliPath: String
    /// Image the helper runs. It only needs `sh`, `tar`, `mkdir` and `rm`, so
    /// the smallest image that has them keeps the first sync cheap.
    public let helperImage: String

    public init(
        cliPath: String = "/usr/local/bin/container",
        helperImage: String = "alpine:3.20"
    ) {
        self.cliPath = cliPath
        self.helperImage = helperImage
    }

    /// Volume identity from `container volume inspect`.
    ///
    /// `creationDate` is only second-granular, so a delete-and-recreate inside
    /// one second is indistinguishable — `sync --always-hash` or `invalidate`
    /// is the escape hatch for that. It reliably catches the cases that matter:
    /// the volume being gone, recreated later, or resized.
    public func fingerprint(volume: String) async throws -> String? {
        guard let output = try? await run(["volume", "inspect", volume]),
            let data = output.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let entry: [String: Any]?
        if let list = parsed as? [[String: Any]] {
            entry = list.first
        } else {
            entry = parsed as? [String: Any]
        }
        guard let configuration = entry?["configuration"] as? [String: Any] else { return nil }
        let created = configuration["creationDate"] as? String ?? ""
        let size = configuration["sizeInBytes"] as? Int ?? 0
        let source = configuration["source"] as? String ?? ""
        guard !created.isEmpty || !source.isEmpty else { return nil }
        return "\(created)|\(size)|\(source)"
    }

    public func reapStaleHelpers(volume: String) async {
        guard let output = try? await run(["list", "-a", "--format", "json"]),
            let data = output.data(using: .utf8),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        for entry in list {
            let configuration = entry["configuration"] as? [String: Any] ?? [:]
            let labels = configuration["labels"] as? [String: String] ?? [:]
            guard labels[Self.helperLabelKey] == volume else { continue }
            guard let id = entry["id"] as? String else { continue }
            _ = try? await run(["rm", "-f", id])
        }
    }

    /// Marks a container as this tool's helper for a specific volume, so a
    /// crashed sync's leftover can be found and removed by name-independent
    /// means on the next run.
    static let helperLabelKey = "com.micropod.sync.volume"

    public func startHelper(volume: String, mountPath: String) async throws -> String {
        let name = "micropod-sync-\(UUID().uuidString.prefix(8))"
        // Detached and long-sleeping: we drive it with exec and remove it when
        // done. The sleep is a ceiling, not a schedule — a sync that outlives
        // it would leave the volume attached to a dead helper.
        _ = try await run([
            "run", "-d", "--name", name,
            "--label", "\(Self.helperLabelKey)=\(volume)",
            "-v", "\(volume):\(mountPath)",
            helperImage, "sh", "-c", "sleep 3600",
        ])
        return name
    }

    public func copyIn(hostPath: String, containerID: String, containerPath: String) async throws {
        _ = try await run(["cp", hostPath, "\(containerID):\(containerPath)"])
    }

    @discardableResult
    public func exec(containerID: String, arguments: [String]) async throws -> String {
        try await run(["exec", containerID] + arguments)
    }

    public func remove(containerID: String) async {
        // `rm -f` without a preceding `stop`: the caller issues a `sync` inside
        // the container first, which is what actually makes the writes durable,
        // and the runtime's stop costs seconds of pure latency on every sync.
        // Best-effort — a helper left holding the volume exclusively is worse
        // than a lost error message.
        _ = try? await run(["rm", "-f", containerID])
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a pipe that fills while we block on exit
        // deadlocks the child.
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let combined =
            String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SharedFSError.containerCommandFailed(
                arguments.joined(separator: " "), combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return combined
    }
}
