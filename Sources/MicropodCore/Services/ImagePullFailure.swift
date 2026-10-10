import Foundation

/// Pull diagnostics contain only fixed categories and numeric facts. Raw CLI
/// lines, references, URLs, credentials and headers never enter the receipt.
struct ImagePullFailure: Codable, Equatable, Sendable {
    enum Category: String, Codable, Sendable, Hashable {
        case unknown, authentication, storage, tls, notFound, platform, rateLimited
        case transientNetwork, transientRegistry, stalled
    }
    enum Stage: String, Codable, Sendable { case unknown, fetch, unpack }

    var version = 1
    var category = Category.unknown
    var stage = Stage.unknown
    var exitCode: Int32?
    var httpStatus: Int?
    var outputTruncated = false

    // Only an ordinary, completed CLI failure can authorize another pull.
    // Missing status means a stream/launch failure; negative status means a signal.
    var completedCLIExit: Bool { exitCode.map { (1...255).contains($0) } ?? false }

    var retryAllowed: Bool {
        completedCLIExit && !outputTruncated && stage == .fetch
            && (category == .transientNetwork || category == .transientRegistry)
    }

    var message: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        fields["retryAllowed"] = retryAllowed
        let receipt = (try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)) ?? Data("{}".utf8)
        return "image_pull_v1 " + String(decoding: receipt, as: UTF8.self)
    }

    static func from(_ error: Error) -> Self? {
        guard case MicropodError.cliFailure(_, _, let detail) = error,
            detail.hasPrefix("image_pull_v1 ")
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(detail.dropFirst("image_pull_v1 ".count).utf8))
    }
}

/// One bounded line of private process output, consumed before publication.
/// An oversized line makes the observation incomplete and disables retries.
struct ImagePullEvidence {
    static let maximumLineBytes = 8192
    private var line = Data()
    private var discardingLine = false
    private var observedCategories: Set<ImagePullFailure.Category> = []
    private(set) var failure = ImagePullFailure()

    mutating func consume(_ data: Data) -> [ProgressEvent] {
        var events: [ProgressEvent] = []
        for byte in data {
            if byte == 10 || byte == 13 {
                if !discardingLine, !line.isEmpty, let event = observe(String(decoding: line, as: UTF8.self)) {
                    events.append(event)
                }
                line.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if line.count < Self.maximumLineBytes {
                    line.append(byte)
                } else {
                    line.removeAll(keepingCapacity: true)
                    discardingLine = true
                    failure.outputTruncated = true
                }
            }
        }
        return events
    }

    mutating func finish() -> ProgressEvent? {
        defer { line.removeAll(keepingCapacity: false) }
        return discardingLine || line.isEmpty ? nil : observe(String(decoding: line, as: UTF8.self))
    }

    private mutating func observe(_ raw: String) -> ProgressEvent? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        // Publish a canonical progress label and bounded percentage only.
        for (prefix, stage) in [
            ("[1/2] Fetching image", ImagePullFailure.Stage.fetch), ("[2/2] Unpacking image", .unpack),
            ("[1/3] Resolving", .fetch), ("[2/3] Downloading", .fetch), ("[3/3] Pull complete", .unpack),
        ] {
            if text.hasPrefix(prefix) {
                if failure.stage != .unpack { failure.stage = stage }
                var safe = prefix
                let suffix = text.dropFirst(prefix.count)
                if let match = suffix.range(
                    of: #"^\s+(?:for platform linux/(?:arm64|amd64)\s+)?[0-9]{1,3}%"#, options: .regularExpression),
                    let percent = suffix[match].split(separator: " ").last,
                    let value = Int(percent.dropLast()), value <= 100
                {
                    safe += " \(value)%"
                }
                // Whole percentages can remain unchanged while a large blob
                // advances. Retain bounded numeric counters for the watchdog.
                let countPattern =
                    #"\([0-9]{1,9} of [0-9]{1,9} (?:blobs|entries)(?:, [0-9]{1,9}(?:\.[0-9]{1,3})?(?:/[0-9]{1,9}(?:\.[0-9]{1,3})?)? (?:B|KB|MB|GB|TB))?"#
                let grammar = #"^\s+(?:for platform linux/(?:arm64|amd64)\s+)?(?:[0-9]{1,3}%\s+)?"# + countPattern
                if let counters = suffix.range(of: grammar, options: .regularExpression),
                    let start = suffix[counters].firstIndex(of: "(")
                {
                    safe += " " + suffix[start..<counters.upperBound] + ")"
                }
                return ProgressEvent.parse(line: safe)
            }
        }
        // Progress and opaque values are not error evidence. Require the
        // CLI's explicit error boundary before interpreting known markers.
        guard lower.hasPrefix("error:") else { return nil }
        var body = String(lower.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
        for wrapper in ["unavailable:", "failed:", "internalerror:"] {
            if body.hasPrefix(wrapper) {
                body = String(body.dropFirst(wrapper.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if body.hasPrefix("\"") { body.removeFirst() }
        let statusPattern = #"(?:http(?: status)?|status code|response status)\s*[:=]?\s*([1-5][0-9]{2})\b"#
        var status: Int?
        if let range = body.range(of: "^" + statusPattern, options: .regularExpression),
            let digits = body[range].range(of: #"[1-5][0-9]{2}$"#, options: .regularExpression)
        {
            status = Int(body[range][digits])
            failure.httpStatus = status
        }
        let category: ImagePullFailure.Category
        if lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("authentication")
            || lower.contains("credential") || lower.contains("access denied")
            || status == 401 || status == 403
        {
            category = .authentication
        } else if lower.contains("no space left") || lower.contains("disk quota exceeded")
            || lower.contains("read-only file system") || lower.contains("permission denied")
            || lower.contains("input/output error")
            || lower.range(
                of:
                    #"\b(?:enospc|edquot|erofs|eacces|eperm|eio)\b|(?:errno|posixerror)\s*[:=]?\s*(?:1|5|13|28|30|122)\b"#,
                options: .regularExpression) != nil
        {
            category = .storage
        } else if lower.contains("certificate") || lower.contains("tls") {
            category = .tls
        } else if body.range(
            of: #"^invalidargument:\s*\"unsupported platform linux/(?:arm64|amd64)\"$"#, options: .regularExpression)
            != nil
            || body.range(
                of: #"^unsupported:\s*\"image sha256:[a-f0-9]{1,64} does not support required platforms\"$"#,
                options: .regularExpression) != nil
        {
            category = .platform
        } else if lower.contains("notfound") || lower.contains("no such image") || status == 404 {
            category = .notFound
        } else if status == 429 || lower.contains("too many requests") {
            category = .rateLimited
        } else if [500, 502, 503, 504].contains(status) {
            category = .transientRegistry
        } else if body.range(
            of:
                #"^(?:request failed: )?(?:connection reset by peer|connection timed out|temporary failure in name resolution)(?:$|[\s\".;])"#,
            options: .regularExpression) != nil
        {
            category = .transientNetwork
        } else {
            category = .unknown
        }
        // A platform-only failure may use the existing default-platform
        // fallback. Other permanent/unknown evidence prevents it, in either
        // order. Mixed platform and transient evidence is ambiguous.
        let transient: Set<ImagePullFailure.Category> = [.transientNetwork, .transientRegistry]
        observedCategories.insert(category)
        let blockers: [ImagePullFailure.Category] = [
            .authentication, .storage, .tls, .notFound, .rateLimited, .unknown,
        ]
        if let blocker = blockers.first(where: { observedCategories.contains($0) }) {
            failure.category = blocker
        } else if observedCategories.contains(.platform), observedCategories.count > 1 {
            failure.category = .unknown
        } else {
            failure.category = category
        }
        if transient.contains(category), failure.stage == .unknown { failure.stage = .fetch }
        return nil
    }
}
