import Darwin
import Foundation

/// A launchd-retained desktop service: the signed payload executable it runs,
/// with its arguments and environment. Kept at `~/.micropod/services/<id>.json`
/// and written before its launch agent is registered. The desktop app creates
/// it (PersistentDesktopAgents); a rig upgrade replaces it while it holds the
/// upgrade fence (RigUpgradeEngine).
public struct RetainedServiceRecord: Codable, Equatable, Sendable {
    public let schema: Int
    public let sourceVersion: String
    public let executable: String
    public let identifier: String
    public let sha256: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        schema: Int, sourceVersion: String, executable: String, identifier: String, sha256: String,
        arguments: [String], environment: [String: String]
    ) {
        self.schema = schema
        self.sourceVersion = sourceVersion
        self.executable = executable
        self.identifier = identifier
        self.sha256 = sha256
        self.arguments = arguments
        self.environment = environment
    }

    /// The same service run from another release's payload: its executable
    /// and digest, that release's arguments, and this host's environment with
    /// every value that named the previous bundle moved to the new one and
    /// the release's own settings applied over it.
    public func moved(
        to payload: URL, sourceVersion version: String, sha256 digest: String, definition: RetainedServiceDefinition
    ) -> Self {
        let binary = URL(fileURLWithPath: executable).lastPathComponent
        let previous = ComponentProbe.enclosingBundle(of: URL(fileURLWithPath: executable))?.path
        var environment = self.environment
        if let previous {
            for (key, value) in environment where value == previous || value.hasPrefix(previous + "/") {
                environment[key] = payload.path + String(value.dropFirst(previous.count))
            }
        }
        environment.merge(definition.environment, uniquingKeysWith: { _, release in release })
        return Self(
            schema: schema, sourceVersion: version,
            executable: payload.appendingPathComponent("Contents/MacOS/" + binary).path,
            identifier: identifier, sha256: digest, arguments: definition.arguments, environment: environment)
    }
}

/// What a release runs a retained service with, beyond this host's
/// environment. The app builds its agent specs from these, and a staged
/// release reports its own through `micropod update rig-helper --probe`.
public struct RetainedServiceDefinition: Codable, Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String: String]
    public init(arguments: [String] = [], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }
}

/// The retained services' launchd jobs, shared by the desktop app (which first
/// registers them) and the rig upgrade (which replaces them).
public enum RetainedServiceLaunchAgent {
    /// Service ids in the order the app manages them.
    public static let ids = ["docker-shim", "api-server", "shared-fs"]

    /// This build's definition of each retained service.
    public static func definition(_ id: String) -> RetainedServiceDefinition { RetainedServiceDefinition() }

    public static var definitions: [String: RetainedServiceDefinition] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, definition($0)) })
    }

    public static func label(_ id: String) -> String { "com.skunkworq.micropod.service." + id }

    /// The code-signing identifier of a service's executable.
    public static func identifier(_ id: String) -> String {
        switch id {
        case "api-server": "com.skunkworq.micropod.api"
        case "docker-shim": "com.skunkworq.micropod.docker-shim"
        default: "com.skunkworq.micropod.sharedfs"
        }
    }

    public static func recordURL(_ id: String, servicesRoot: URL) -> URL {
        servicesRoot.appendingPathComponent(id + ".json")
    }

    public static func plistURL(_ id: String, launchAgents: URL) -> URL {
        launchAgents.appendingPathComponent(label(id) + ".plist")
    }

    public static func readRecord(_ url: URL) throws -> RetainedServiceRecord {
        try JSONDecoder().decode(
            RetainedServiceRecord.self, from: RuntimeDurableFile.read(url, maximumBytes: 8192))
    }

    /// The launch agent definition for a record. The app writes exactly this.
    public static func configuration(_ id: String, record: RetainedServiceRecord, servicesRoot: URL) -> [String: Any] {
        let log = servicesRoot.appendingPathComponent(id + ".log").path
        return [
            "Label": label(id), "ProgramArguments": [record.executable] + record.arguments,
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "EnvironmentVariables": record.environment,
            "StandardOutPath": log, "StandardErrorPath": log,
            "ProcessType": "Background", "Umask": 0o077,
        ]
    }

    public static func plistData(_ id: String, record: RetainedServiceRecord, servicesRoot: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: configuration(id, record: record, servicesRoot: servicesRoot), format: .xml, options: 0)
    }
}
