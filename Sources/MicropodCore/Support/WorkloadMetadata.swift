import Foundation

public enum WorkloadLaunchSource: String, Equatable, Sendable {
    case direct = "Direct"
    case compose = "Compose"
}

public struct WorkloadMetadata: Equatable, Sendable {
    public let isAgent: Bool
    public let source: WorkloadLaunchSource
    public let jobID: String?
    public let owner: String?
    public let isEphemeral: Bool
    public let ttlMinutes: Int?

    public init(labels: [String: String]) {
        let cuttlefishJob = nonEmpty(labels[WorkloadLabel.cuttlefishJob])

        isAgent = labels[WorkloadLabel.agent] == "true" || cuttlefishJob != nil
        source = nonEmpty(labels[WorkloadLabel.compose]) == nil ? .direct : .compose
        jobID = nonEmpty(labels[WorkloadLabel.job]) ?? cuttlefishJob
        owner = nonEmpty(labels[WorkloadLabel.owner])
        isEphemeral = labels[WorkloadLabel.ephemeral] == "true"

        if let value = nonEmpty(labels[WorkloadLabel.ttlMinutes]),
            let minutes = Int(value), minutes > 0
        {
            ttlMinutes = minutes
        } else {
            ttlMinutes = nil
        }
    }
}

public func workloadMatchesQuery(
    query: String,
    id: String,
    image: String,
    labels: [String: String]
) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return true }

    if id.lowercased().contains(query) || image.lowercased().contains(query) {
        return true
    }

    return labels.contains { label in
        label.key.lowercased().contains(query) || label.value.lowercased().contains(query)
    }
}

/// Reports whether the requested image tag or digest is represented in the
/// supplied local references. This does not infer availability from shared layers.
public func localImageIsPresent(_ reference: String, in localReferences: [String]) -> Bool {
    guard let requested = normalizedImageReference(reference) else { return false }
    return localReferences.contains { normalizedImageReference($0) == requested }
}

public func containerImageReferenceIsValid(_ reference: String) -> Bool {
    normalizedImageReference(reference) != nil
}

public func localImageReferenceInventory(from images: [Micropod_V1_Image]) -> [String] {
    var references = Set<String>()
    for image in images {
        let digest = image.digest.trimmingCharacters(in: .whitespacesAndNewlines)
        for rawName in image.names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if containerImageReferenceIsValid(name) {
                references.insert(name)
            }
            if !digest.isEmpty, let repository = repositoryWithoutLeafTag(name) {
                let digestReference = repository + "@" + digest
                if containerImageReferenceIsValid(digestReference) {
                    references.insert(digestReference)
                }
            }
        }
    }
    return references.sorted()
}

enum WorkloadLabel {
    static let agent = "com.micropod.agent"
    static let job = "com.micropod.job"
    static let owner = "com.micropod.owner"
    static let ephemeral = "com.micropod.ephemeral"
    static let ttlMinutes = "com.micropod.ttl-minutes"
    static let cuttlefishJob = "com.cuttlefish.job"
    static let compose = "com.skunkworq.micropod.compose"
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func repositoryWithoutLeafTag(_ reference: String) -> String? {
    guard !reference.isEmpty, !reference.contains("@") else { return nil }
    guard let colon = reference.lastIndex(of: ":") else { return reference }
    if let slash = reference.lastIndex(of: "/"), colon < slash {
        return reference
    }
    return String(reference[..<colon])
}

private func normalizedImageReference(_ reference: String) -> String? {
    let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty,
        !reference.contains(where: { $0.isWhitespace })
    else {
        return nil
    }

    let digestParts = reference.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let name = String(digestParts[0])
    let digest = digestParts.count == 2 ? String(digestParts[1]) : nil
    guard !name.isEmpty,
        digest?.isEmpty != true,
        digest?.contains("@") != true
    else {
        return nil
    }
    if let digest {
        let components = digest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
            !components[0].isEmpty,
            !components[1].isEmpty,
            !components[1].contains(":")
        else {
            return nil
        }
    }

    var components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty, !components.contains(where: \.isEmpty) else { return nil }
    if let leaf = components.last {
        guard leaf.filter({ $0 == ":" }).count <= 1 else { return nil }
        if let tagSeparator = leaf.lastIndex(of: ":") {
            guard tagSeparator != leaf.startIndex, leaf.index(after: tagSeparator) != leaf.endIndex else {
                return nil
            }
        }
    }

    let first = components[0]
    let hasExplicitRegistry =
        components.count > 1
        && (first.contains(".") || first.contains(":") || first == "localhost")
    if !hasExplicitRegistry {
        components.insert("docker.io", at: 0)
    }
    if components[0] == "index.docker.io" {
        components[0] = "docker.io"
    }
    if components[0] == "docker.io", components.count == 2 {
        components.insert("library", at: 1)
    }

    var normalized = components.joined(separator: "/")
    if let digest {
        return normalized + "@" + digest
    }
    if components.last?.contains(":") != true {
        normalized += ":latest"
    }

    return normalized
}
