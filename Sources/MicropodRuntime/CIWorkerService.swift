import Darwin
import Foundation
import MicropodCore

extension CIWorker {
    private static let agentLabel = "com.skunkworq.micropod.ci-worker"

    private var agentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(Self.agentLabel + ".plist")
    }

    /// Used by launchd before the runner begins accepting individual jobs.
    public func launchAgent(executable: URL) throws -> Data {
        var environment = resourceEnvironment
        environment["MICROPOD_CI_HOME"] = directory.path
        var plist: [String: Any] = [
            "Label": Self.agentLabel, "ProgramArguments": [executable.path, "ci", "serve"],
            "EnvironmentVariables": environment, "RunAtLoad": true, "KeepAlive": ["Crashed": true],
            "StandardOutPath": log.path, "StandardErrorPath": log.path,
        ]
        if isNativeRunner && environment["MICROPOD_CI_PORT_RELAY"] == "kqueue-interactive" {
            plist["ProcessType"] = "Interactive"
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func registeredDirectory() throws -> String? {
        guard FileManager.default.fileExists(atPath: agentFile.path) else { return nil }
        let data = try Data(contentsOf: agentFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist["Label"] as? String == Self.agentLabel,
            let environment = plist["EnvironmentVariables"] as? [String: String],
            let path = environment["MICROPOD_CI_HOME"]
        else { throw MicropodError.message("Unrecognized CI launch agent at \(agentFile.path)") }
        return path
    }

    private func launchctl(_ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func loadedTarget() throws -> String? {
        for domain in ["gui/\(getuid())", "user/\(getuid())"] {
            let target = domain + "/" + Self.agentLabel
            if try launchctl(["print", target]) == 0 { return target }
        }
        return nil
    }

    func serviceTarget() throws -> String? {
        guard try registeredDirectory() == directory.path else { return nil }
        guard let target = try loadedTarget() else {
            throw MicropodError.message("CI service is registered but unloaded; run micropod ci install-service")
        }
        return target
    }

    public func installService(executable: URL) async throws -> Status {
        try prepareDirectory()
        if let existing = try registeredDirectory() {
            guard existing == directory.path else {
                throw MicropodError.message("The account's CI service uses \(existing)")
            }
            if try loadedTarget() != nil { return try await start(executable: executable) }
        }
        guard !isOwned() else {
            throw MicropodError.message("Pause intake and stop the standalone CI worker before installing its service")
        }
        try FileManager.default.createDirectory(
            at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try launchAgent(executable: executable).write(to: agentFile, options: .atomic)
        let gui = "gui/\(getuid())"
        let domain = try launchctl(["print", gui]) == 0 ? gui : "user/\(getuid())"
        guard try launchctl(["bootstrap", domain, agentFile.path]) == 0 || loadedTarget() != nil else {
            throw MicropodError.message("Could not bootstrap \(agentFile.path) in \(domain)")
        }
        return try await start(executable: executable)
    }

    public func uninstallService() async throws {
        guard let path = try registeredDirectory() else { return }
        guard path == directory.path else { throw MicropodError.message("The account's CI service uses \(path)") }
        try await stop()
        if let target = try loadedTarget(), try launchctl(["bootout", target]) != 0 {
            throw MicropodError.message("Could not unload CI service \(target)")
        }
        try FileManager.default.removeItem(at: agentFile)
    }
}
