import Darwin
import Foundation

/// Shared by the app, API, CLI, MCP server and Docker shim. Resolve again on
/// use so an installation made while Micropod is open is discovered.
public enum ContainerExecutableLocator {
    public static let installerURL = URL(string: "https://github.com/apple/container/releases/tag/1.5.0")!

    /// The variables `resolve` reads, from the live environment. Every
    /// `ContainerCLIClient.executableURL` resolves, several times per API
    /// request; building `ProcessInfo.environment` (a dictionary of the whole
    /// environment, ~20 µs) each time was a quarter of a listing's cost.
    public static func lookupEnvironment() -> [String: String] {
        LiveEnvironment.values([
            "MICROPOD_CONTAINER_CLI_PATH", "MICROPOD_RUNTIME_CONTEXT", "MICROPOD_ISOLATED_RUNTIME", "PATH",
        ])
    }

    public static func resolve(
        environment: [String: String] = ContainerExecutableLocator.lookupEnvironment(),
        defaultDirectories: [String] = ["/usr/local/bin", "/opt/homebrew/bin"],
        managedExecutable: () -> URL? = {
            isolatedExecutable() ?? ManagedRuntimeLocation.executable()
        },
        hasConfiguredRig: () -> Bool = { RuntimeRigClient.hasConfiguredRig() },
        isExecutable: (String) -> Bool = ContainerExecutableLocator.isExecutableFile
    ) -> URL {
        // An explicit path is authoritative, including when it is missing.
        // Silently substituting another runtime would hide a broken rig config.
        if let path = environment["MICROPOD_CONTAINER_CLI_PATH"] {
            return URL(fileURLWithPath: path)
        }
        let requested = (environment["MICROPOD_RUNTIME_CONTEXT"] ?? "automatic")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["automatic", "existing", "managed"].contains(requested) else {
            return IsolatedRuntimePolicy.root.appendingPathComponent("invalid-context/bin/container")
        }
        // The dedicated service is launched with this fixed environment by
        // the helper. Desktop clients must choose the managed context
        // explicitly when a prior installation or CI configuration exists.
        if requested == "managed" || environment["MICROPOD_ISOLATED_RUNTIME"] == "1" {
            return managedExecutable()
                ?? IsolatedRuntimePolicy.root.appendingPathComponent("missing-managed-runtime/bin/container")
        }
        var seen = Set<String>()
        func installed(in directory: String) -> URL? {
            guard directory.hasPrefix("/"), seen.insert(directory).inserted else { return nil }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("container")
            return isExecutable(candidate.path) ? candidate : nil
        }
        for directory in defaultDirectories {
            if let found = installed(in: directory) { return found }
        }
        // PATH is split only when no default directory has the CLI.
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            if let found = installed(in: String(directory)) { return found }
        }
        if requested == "automatic", !hasConfiguredRig(), let managed = managedExecutable() { return managed }
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
