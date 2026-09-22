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

    public func pull(_ reference: String, platform: String? = nil) -> AsyncThrowingStream<
        ProgressEvent, Error
    > {
        let command = ContainerCommandFactory.pullImage(reference, platform: platform)
        return progressStream(command)
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
