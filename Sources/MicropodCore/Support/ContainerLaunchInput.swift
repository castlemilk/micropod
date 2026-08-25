import Foundation

public enum ContainerLaunchInputError: Error, Equatable, LocalizedError, Sendable {
    case invalidCPU
    case invalidPorts
    case invalidTTL

    public var errorDescription: String? {
        switch self {
        case .invalidCPU:
            "CPU must be a finite number greater than 0."
        case .invalidPorts:
            "Ports must use host:container with each port from 1 to 65535."
        case .invalidTTL:
            "TTL must be a whole number of minutes greater than 0."
        }
    }
}

public enum ContainerLaunchInput {
    public static func parseOptionalCPU(_ value: String) throws -> Double? {
        let value = trimmed(value)
        guard !value.isEmpty else { return nil }
        guard let cpus = Double(value), cpus.isFinite, cpus > 0 else {
            throw ContainerLaunchInputError.invalidCPU
        }
        return cpus
    }

    public static func parsePorts(_ value: String) throws -> [PortSpec] {
        let value = trimmed(value)
        guard !value.isEmpty else { return [] }

        return try value.split(separator: ",", omittingEmptySubsequences: false).map { segment in
            let ports = segment.split(separator: ":", omittingEmptySubsequences: false)
            guard ports.count == 2,
                let hostPort = parsePort(String(ports[0])),
                let containerPort = parsePort(String(ports[1]))
            else {
                throw ContainerLaunchInputError.invalidPorts
            }
            return PortSpec(hostPort: hostPort, containerPort: containerPort)
        }
    }

    public static func parseOptionalTTL(_ value: String) throws -> Int? {
        let value = trimmed(value)
        guard !value.isEmpty else { return nil }
        guard isDecimalInteger(value), let minutes = Int(value), minutes > 0 else {
            throw ContainerLaunchInputError.invalidTTL
        }
        return minutes
    }

    public static func agentLabels(
        isAgent: Bool,
        jobID: String,
        owner: String,
        isEphemeral: Bool,
        ttlMinutes: Int?
    ) -> [LabelSpec] {
        guard isAgent else { return [] }

        var labels = [LabelSpec(key: WorkloadLabel.agent, value: "true")]
        if let jobID = nonEmpty(jobID) {
            labels.append(LabelSpec(key: WorkloadLabel.job, value: jobID))
        }
        if let owner = nonEmpty(owner) {
            labels.append(LabelSpec(key: WorkloadLabel.owner, value: owner))
        }
        if isEphemeral {
            labels.append(LabelSpec(key: WorkloadLabel.ephemeral, value: "true"))
        }
        if let ttlMinutes, ttlMinutes > 0 {
            labels.append(LabelSpec(key: WorkloadLabel.ttlMinutes, value: String(ttlMinutes)))
        }
        return labels
    }

    private static func parsePort(_ value: String) -> Int? {
        let value = trimmed(value)
        guard isDecimalInteger(value), let port = Int(value), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    private static func isDecimalInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
