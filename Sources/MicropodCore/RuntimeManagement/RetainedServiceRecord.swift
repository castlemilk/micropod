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

    /// The same service run from another payload bundle: its executable, its
    /// digest and every environment value that named the previous bundle.
    public func moved(to payload: URL, sourceVersion version: String, sha256 digest: String) -> Self {
        let binary = URL(fileURLWithPath: executable).lastPathComponent
        let previous = ComponentProbe.enclosingBundle(of: URL(fileURLWithPath: executable))?.path
        var environment = self.environment
        if let previous {
            for (key, value) in environment where value == previous || value.hasPrefix(previous + "/") {
                environment[key] = payload.path + String(value.dropFirst(previous.count))
            }
        }
        return Self(
            schema: schema, sourceVersion: version,
            executable: payload.appendingPathComponent("Contents/MacOS/" + binary).path,
            identifier: identifier, sha256: digest, arguments: arguments, environment: environment)
    }
}

/// The retained services' launchd jobs, shared by the desktop app (which first
/// registers them) and the rig upgrade (which replaces them).
public enum RetainedServiceLaunchAgent {
    /// Service ids in the order the app manages them.
    public static let ids = ["docker-shim", "api-server", "shared-fs"]

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
