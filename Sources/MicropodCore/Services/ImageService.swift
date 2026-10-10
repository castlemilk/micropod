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

    private static let stageExpression = try? NSRegularExpression(pattern: #"\[[^\]]*?(\d+)/(\d+)\]"#)
    private static let timerExpression = try? NSRegularExpression(pattern: #"\[\d+s\]\s*$"#)

    /// Tolerant parse of progress lines: classic `[3/6] Unpacking image [2s]`
    /// and BuildKit `#5 [linux/arm64 1/2] RUN echo …`.
    public static func parse(line: String) -> ProgressEvent {
        guard let regex = stageExpression,
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
        if let timerMatch = timerExpression?.firstMatch(
            in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)),
            let timer = Range(timerMatch.range, in: name)
        {
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
    private let retrySleep: @Sendable (Duration) async throws -> Void

    public init(client: ContainerCLIClient) {
        self.client = client
        retrySleep = { try await Task.sleep(for: $0) }
    }

    init(client: ContainerCLIClient, retrySleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.client = client
        self.retrySleep = retrySleep
    }

    public func list() async throws -> [Micropod_V1_Image] {
        let output = try await client.run(ContainerCommandFactory.listImages(verbose: true), timeout: .seconds(30))
        let entries = try MicropodJSON.decodeArray(ImageListEntry.self, from: Data(output.utf8), context: "image list")
        return entries.map(ModelMapper.image(from:))
    }

    /// Pull with bounded progress observation and safe terminal diagnostics.
    /// Classified transient fetch failures get at most two retries, after
    /// one and two seconds. Authentication, storage, TLS, unknown failures
    /// and stalls stop without credential changes or runtime operations.
    ///
    /// A nil or empty `platform` pulls `defaultPullPlatform`, not every
    /// platform in the index. If the image has no variant for it, the pull
    /// is retried once with no platform, which is what it did before the
    /// default existed. A given platform is passed through and never widened.
    public func pull(_ reference: String, platform: String? = nil) -> AsyncThrowingStream<
        ProgressEvent, Error
    > {
        let requested = platform.flatMap { $0.isEmpty ? nil : $0 }
        let callerWasCancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard !callerWasCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                var attempts = 0
                // nil only once a defaulted pull found no host variant.
                var pinned: String? = requested ?? Self.defaultPullPlatform
                while true {
                    let widenable = requested == nil && pinned != nil
                    attempts += 1
                    do {
                        try Task.checkCancellation()
                        for try await event in pullOnce(reference, platform: pinned) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                        return
                    } catch MicropodError.pullStalled {
                        continuation.finish(throwing: MicropodError.pullStalled(reference: reference))
                        return
                    } catch {
                        let failure = ImagePullFailure.from(error)
                        if widenable, failure?.category == .platform, failure?.completedCLIExit == true,
                            failure?.outputTruncated == false,
                            attempts < 3, let missing = pinned, !Task.isCancelled
                        {
                            pinned = nil
                            continuation.yield(
                                ProgressEvent(
                                    line: "Image has no \(missing) variant; pulling every platform it has"))
                            continue
                        }
                        if failure?.retryAllowed == true, attempts < 3, !Task.isCancelled {
                            do {
                                try await retrySleep(.seconds(attempts))
                                try Task.checkCancellation()
                                continuation.yield(
                                    ProgressEvent(line: "Retrying transient image fetch (attempt \(attempts + 1)/3)"))
                                continue
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The platform a pull fetches when the caller names none: the one
    /// CreateContainer defaults to. With no `--platform` the CLI fetches and
    /// unpacks every platform in the index (9 snapshots, about 10 GiB, for
    /// busybox), and only the host's is ever run.
    static var defaultPullPlatform: String {
        "linux/\(LocalImagePresence.hostArchitecture)"
    }

    /// Whether a pull output line is the runtime refusing the platform it
    /// was asked for (containerization 0.42.0, as `container` prints it):
    /// the import of a single-manifest image built for another platform
    /// ("does not support required platforms"), or the unpack of an index
    /// with no entry for that platform ("unsupported platform linux/arm64").
    static func reportsMissingPlatform(_ line: String) -> Bool {
        line.contains("does not support required platforms") || line.contains("unsupported platform")
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

    /// One pull attempt with a forward-progress watchdog layered over the
    /// raw CLI stream. A separate watchdog task so a pull that emits zero
    /// lines (wedged before first output) still fails within the budget.
    private func pullOnce(_ reference: String, platform: String?) -> AsyncThrowingStream<
        ProgressEvent, Error
    > {
        let inner = pullProgressStream(ContainerCommandFactory.pullImage(reference, platform: platform))
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

    private func pullProgressStream(_ command: ContainerCommand) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                var evidence = ImagePullEvidence()
                do {
                    for try await chunk in client.stream(command, reportExitCode: true) {
                        for event in evidence.consume(chunk) { continuation.yield(event) }
                    }
                    if let event = evidence.finish() { continuation.yield(event) }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    if let event = evidence.finish() { continuation.yield(event) }
                    if Task.isCancelled || error is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } else if case MicropodError.cliFailure(_, let exitCode, _) = error {
                        var failure = evidence.failure
                        failure.exitCode = exitCode
                        continuation.finish(
                            throwing: MicropodError.cliFailure(
                                command: "container image pull", exitCode: exitCode, stderr: failure.message))
                    } else {
                        continuation.finish(throwing: MicropodError.message(evidence.failure.message))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
