import Foundation

/// A parsed line of BuildKit/CLI progress output.
public struct ProgressEvent: Sendable, Equatable {
    public let line: String
    public let stage: Int?
    public let totalStages: Int?
    public let stageName: String?

    public init(line: String, stage: Int? = nil, totalStages: Int? = nil, stageName: String? = nil) {
        self.line = line
        self.stage = stage
        self.totalStages = totalStages
        self.stageName = stageName
    }

    /// Tolerant parse of progress lines: classic `[3/6] Unpacking image [2s]`
    /// and BuildKit `#5 [linux/arm64 1/2] RUN echo …`.
    public static func parse(line: String) -> ProgressEvent {
        let pattern = #"\[[^\]]*?(\d+)/(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let nsMatch = regex.firstMatch(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
            let stageRange = Range(nsMatch.range(at: 1), in: line),
            let totalRange = Range(nsMatch.range(at: 2), in: line),
            let stage = Int(line[stageRange]),
            let total = Int(line[totalRange]),
            let match = Range(nsMatch.range, in: line)
        else {
            return ProgressEvent(line: line)
        }
        var name = String(line[match.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing elapsed timers like "[12s]".
        if let timer = name.range(of: #"\[\d+s\]\s*$"#, options: String.CompareOptions.regularExpression) {
            name = String(name[name.startIndex..<timer.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ProgressEvent(line: line, stage: stage, totalStages: total, stageName: name.isEmpty ? nil : name)
    }
}

public protocol ImageServing: Sendable {
    func list() async throws -> [Micropod_V1_Image]
    func pull(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error>
    func push(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error>
    func build(_ request: ContainerBuildRequest) -> AsyncThrowingStream<ProgressEvent, Error>
    func delete(_ reference: String, force: Bool) async throws
    func prune(danglingOnly: Bool) async throws -> String
    func tag(source: String, target: String) async throws
    func save(_ reference: String, to outputPath: String) async throws
    func saveAll(_ references: [String], to outputPath: String) async throws
    func load(from inputPath: String) async throws
    func inspect(_ reference: String) async throws -> Data
}

public struct ImageService: ImageServing {
    private let client: ContainerCLIClient

    public init(client: ContainerCLIClient) {
        self.client = client
    }

    public func list() async throws -> [Micropod_V1_Image] {
        let output = try await client.run(ContainerCommandFactory.listImages(verbose: true), timeout: .seconds(30))
        let entries = try MicropodJSON.decodeArray(ImageListEntry.self, from: Data(output.utf8), context: "image list")
        return entries.map(ModelMapper.image(from:))
    }

    /// Pull with stall detection + credential recovery.
    ///
    /// The runtime's registry client can wedge before any network I/O —
    /// most reproducibly when a stored credential for the registry exists
    /// and the token endpoint challenges back (`Fetching image` ticks
    /// forever, zero connections). Without a watchdog that pull hangs the
    /// caller forever, so:
    ///
    ///   1. Watch progress markers: if the line (minus the elapsed-time
    ///      ticker and transfer-rate suffix) doesn't change for
    ///      `MICROPOD_PULL_STALL_TIMEOUT` seconds (default 90), fail the
    ///      pull with `MicropodError.pullStalled`.
    ///   2. On stall, if the registry has a stored credential, log it out
    ///      and retry once anonymously — the known-good path for registries
    ///      with anonymous reads.
    public func pull(_ reference: String, platform: String? = nil) -> AsyncThrowingStream<
        ProgressEvent, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                var recovered = false
                while true {
                    do {
                        for try await event in pullOnce(reference, platform: platform) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch MicropodError.pullStalled {
                        guard !recovered, !Task.isCancelled else {
                            continuation.finish(throwing: MicropodError.pullStalled(reference: reference))
                            return
                        }
                        recovered = true
                        if await clearStoredCredential(Self.registryHost(of: reference)) {
                            continue
                        }
                        continuation.finish(throwing: MicropodError.pullStalled(reference: reference))
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Seconds with no forward progress before a pull is declared stalled.
    /// `getenv` (not ProcessInfo) so tests can mutate it mid-process.
    static var pullStallTimeout: TimeInterval {
        getenv("MICROPOD_PULL_STALL_TIMEOUT").flatMap { TimeInterval(String(cString: $0)) } ?? 90
    }

    /// Registry host portion of an image reference. Implicit docker.io
    /// references resolve to `registry-1.docker.io` — the name `container
    /// registry list` reports for it.
    static func registryHost(of reference: String) -> String {
        let name = reference.split(separator: "@").first.map(String.init) ?? reference
        let components = name.split(separator: "/")
        // A first component is a registry host only when the reference is
        // multi-component AND it looks like a host (".", ":" or localhost).
        if components.count > 1, let first = components.first.map(String.init),
            first.contains(".") || first.contains(":") || first == "localhost"
        {
            return first
        }
        return "registry-1.docker.io"
    }

    /// If the registry has a stored credential, log it out so the retry
    /// goes through the anonymous path. Returns true when a credential was
    /// actually cleared.
    private func clearStoredCredential(_ host: String) async -> Bool {
        guard
            let output = try? await client.run(
                ContainerCommandFactory.registryList(), timeout: .seconds(15)),
            let entries = try? JSONSerialization.jsonObject(with: Data(output.utf8))
                as? [[String: Any]],
            entries.contains(where: { ($0["name"] as? String) == host })
        else { return false }
        _ = try? await client.run(
            ContainerCommandFactory.registryLogout(host), timeout: .seconds(15))
        return true
    }

    /// One pull attempt with a forward-progress watchdog layered over the
    /// raw CLI stream. A separate watchdog task so a pull that emits zero
    /// lines (wedged before first output) still fails within the budget.
    private func pullOnce(_ reference: String, platform: String?) -> AsyncThrowingStream<
        ProgressEvent, Error
    > {
        let inner = progressStream(ContainerCommandFactory.pullImage(reference, platform: platform))
        let stallTimeout = Self.pullStallTimeout
        return AsyncThrowingStream { continuation in
            let progress = PullProgress()
            let task = Task {
                do {
                    for try await event in inner {
                        progress.note(Self.stallMarker(event.line))
                        continuation.yield(event)
                    }
                    // Cancellation unwinds for-await as a nil (clean end),
                    // not a throw — check the stall latch explicitly.
                    if progress.isStalled {
                        continuation.finish(
                            throwing: MicropodError.pullStalled(reference: reference))
                    } else if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish()
                    }
                } catch {
                    if progress.isStalled {
                        continuation.finish(
                            throwing: MicropodError.pullStalled(reference: reference))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            let watchdog = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled { return }
                    if progress.stalled(stallTimeout) {
                        task.cancel()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                watchdog.cancel()
            }
        }
    }

    /// The part of a progress line that reflects forward progress: the
    /// text minus the trailing elapsed-time ticker (`[12s]`, `[1m05s]`)
    /// and the transfer-rate suffix (`, 12.8 MB/s)`), both of which keep
    /// changing even when the fetch is deadlocked.
    static func stallMarker(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(
            of: #"\s*\[[\d.hms]+\]\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #",\s*[\w.]+\s*[A-Za-z]+/s\)?\s*$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Shared mutable progress state for the pull watchdog.
    private final class PullProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var lastMarker: String?
        private var lastProgressAt = Date()
        private var stalledFlag = false

        func note(_ marker: String) {
            lock.lock()
            defer { lock.unlock() }
            if marker != lastMarker {
                lastMarker = marker
                lastProgressAt = Date()
            }
        }

        /// Returns true (and latches) once the marker has been unchanged
        /// for `timeout` seconds.
        func stalled(_ timeout: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if Date().timeIntervalSince(lastProgressAt) >= timeout {
                stalledFlag = true
            }
            return stalledFlag
        }

        var isStalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stalledFlag
        }
    }

    public func push(_ reference: String, platform: String? = nil) -> AsyncThrowingStream<
        ProgressEvent, Error
    > {
        let command = ContainerCommandFactory.pushImage(reference, platform: platform)
        return progressStream(command)
    }

    public func build(_ request: ContainerBuildRequest) -> AsyncThrowingStream<ProgressEvent, Error> {
        progressStream(ContainerCommandFactory.build(request))
    }

    public func delete(_ reference: String, force: Bool = false) async throws {
        _ = try await client.run(ContainerCommandFactory.deleteImage(reference, force: force), timeout: .seconds(60))
    }

    public func prune(danglingOnly: Bool = true) async throws -> String {
        let output = try await client.run(
            ContainerCommandFactory.pruneImages(all: !danglingOnly), timeout: .seconds(120))
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func tag(source: String, target: String) async throws {
        _ = try await client.run(
            ContainerCommandFactory.tagImage(source: source, target: target), timeout: .seconds(15))
    }

    public func save(_ reference: String, to outputPath: String) async throws {
        _ = try await client.run(ContainerCommandFactory.saveImage(reference, to: outputPath), timeout: .seconds(300))
    }

    public func saveAll(_ references: [String], to outputPath: String) async throws {
        _ = try await client.run(
            ContainerCommandFactory.saveImages(references, to: outputPath), timeout: .seconds(300))
    }

    public func load(from inputPath: String) async throws {
        _ = try await client.run(ContainerCommandFactory.loadImage(from: inputPath), timeout: .seconds(300))
    }

    public func inspect(_ reference: String) async throws -> Data {
        let output = try await client.run(ContainerCommandFactory.inspectImage(reference), timeout: .seconds(15))
        return Data(output.utf8)
    }

    private func progressStream(_ command: ContainerCommand) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = ""
                    // reportExitCode: a failed pull/push/build must surface,
                    // not stream its error text as success.
                    for try await chunk in client.stream(command, reportExitCode: true) {
                        guard let text = String(data: chunk, encoding: .utf8) else { continue }
                        buffer += text
                        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
                        buffer = lines.last.map { String($0) } ?? ""
                        for line in lines.dropLast() {
                            continuation.yield(ProgressEvent.parse(line: String(line)))
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(ProgressEvent.parse(line: buffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
