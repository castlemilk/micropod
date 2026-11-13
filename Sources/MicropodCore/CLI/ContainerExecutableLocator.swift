import Darwin
import Foundation

/// Shared by the app, API, CLI, MCP server and Docker shim. Resolve again on
/// use so an installation made while Micropod is open is discovered.
public enum ContainerExecutableLocator {
    public static let installerURL = URL(string: "https://github.com/apple/container/releases/tag/1.5.0")!

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultDirectories: [String] = ["/usr/local/bin", "/opt/homebrew/bin"],
        isExecutable: (String) -> Bool = ContainerExecutableLocator.isExecutableFile
    ) -> URL {
        // An explicit path is authoritative, including when it is missing.
        // Silently substituting another runtime would hide a broken rig config.
        if let path = environment["MICROPOD_CONTAINER_CLI_PATH"] {
            return URL(fileURLWithPath: path)
        }
        if let managed = isolatedExecutable() { return managed }
        if let managed = ManagedRuntimeLocation.executable() { return managed }
        let directories = defaultDirectories + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for directory in directories where directory.hasPrefix("/") && seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("container")
            if isExecutable(candidate.path) { return candidate }
        }
        // A stable missing path makes diagnostics useful on a fresh Mac.
        return URL(fileURLWithPath: "/usr/local/bin/container")
    }

    public static func isolatedExecutable() -> URL? {
        guard FileManager.default.fileExists(atPath: IsolatedRuntimePolicy.identityURL.path),
            let identity = try? IsolatedRuntimeIdentity.readRootOwned(),
            getuid() == identity.ownerUID || getuid() == identity.serviceUID
        else { return nil }
        do {
            let configuration = try IsolatedRuntimeAPIConfiguration.read(identity: identity, allowStaged: true)
            return IsolatedRuntimePolicy.root.appendingPathComponent(
                "apple/versions/" + configuration.selection.directoryName + "/bin/container")
        } catch {
            return IsolatedRuntimePolicy.root.appendingPathComponent("invalid-selection/bin/container")
        }
    }

    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
