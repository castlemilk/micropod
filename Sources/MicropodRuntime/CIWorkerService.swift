import Darwin
import Foundation
import MicropodCore

extension CIWorker {
    public enum LaunchProcessType: String, Sendable {
        case standard = "Standard"
        case interactive = "Interactive"
    }

    private static let agentLabel = "com.skunkworq.micropod.ci-worker"

    private var agentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(Self.agentLabel + ".plist")
    }

    /// Used by launchd before the runner begins accepting individual jobs.
    public func launchAgent(executable: URL) throws -> Data {
        try launchAgent(executable: executable, processType: nil)
    }

    /// Render a job with an explicit scheduling role for a same-relay comparison.
    public func launchAgent(executable: URL, processType: LaunchProcessType?) throws -> Data {
        var environment = resourceEnvironment
        environment["MICROPOD_CI_HOME"] = directory.path
        if let vmm = environment["MICROPOD_CI_VMM"], !vmm.isEmpty {
            environment["MICROPOD_CI_VMM"] = try selectedVMM().rawValue
        }
        var plist: [String: Any] = [
            "Label": Self.agentLabel, "ProgramArguments": [executable.path, "ci", "serve"],
            "EnvironmentVariables": environment, "RunAtLoad": true, "KeepAlive": ["Crashed": true],
            "StandardOutPath": log.path, "StandardErrorPath": log.path,
        ]
        let interactiveRelay = isNativeRunner && environment["MICROPOD_CI_PORT_RELAY"] == "kqueue-interactive"
        plist["ProcessType"] =
            processType?.rawValue ?? (interactiveRelay ? LaunchProcessType.interactive.rawValue : nil)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func registeredEnvironment() throws -> [String: String]? {
        guard FileManager.default.fileExists(atPath: agentFile.path) else { return nil }
        let data = try Data(contentsOf: agentFile)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist["Label"] as? String == Self.agentLabel,
            let environment = plist["EnvironmentVariables"] as? [String: String],
            environment["MICROPOD_CI_HOME"] != nil
        else { throw MicropodError.message("Unrecognized CI launch agent at \(agentFile.path)") }
        return environment
    }

    private func registeredDirectory() throws -> String? {
        try registeredEnvironment()?["MICROPOD_CI_HOME"]
    }

    func verifyServiceCPU(_ policy: CIWorkerCPUCount) throws {
        guard let env = try registeredEnvironment(), env["MICROPOD_CI_HOME"] == directory.path,
            let pinned = env["MICROPOD_CI_CPUS"], try CIWorkerCPUCount(pinned) != policy
        else { return }
        throw MicropodError.message(
            "The registered launch agent pins MICROPOD_CI_CPUS=\(pinned). Uninstall the idle service before changing that policy."
        )
    }

    private func launchctl(_ args: [String], captureOutput: Bool = false) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = captureOutput ? Pipe() : nil
        if let pipe { process.standardOutput = pipe } else { process.standardOutput = FileHandle.nullDevice }
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    struct LoadedService {
        let target: String
        let environment: [String: String]?
    }

    static func loadedEnvironment(from output: String) -> [String: String]? {
        let lines = output.split(separator: "\n")
        let labels = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let keys = ["MICROPOD_CI_HOME", "MICROPOD_CI_ENGINE", "MICROPOD_CI_VMM"]
        var environment: [String: String] = [:]
        // launchctl print is diagnostic output. Require the worker's home in
        // the job's own environment block before acting on a loaded job.
        for block in ["default environment = {", "inherited environment = {", "environment = {"] {
            guard let start = labels.firstIndex(of: block) else { continue }
            guard let end = labels[(start + 1)...].firstIndex(of: "}") else { return nil }
            for entry in lines[(start + 1)..<end] {
                guard let separator = entry.range(of: " => ") else { continue }
                let key = entry[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                if key == "MICROPOD_CI_HOME", block != "environment = {" { continue }
                if keys.contains(key) { environment[key] = String(entry[separator.upperBound...]) }
            }
        }
        guard environment["MICROPOD_CI_HOME"] != nil else { return nil }
        return environment
    }

    private func loadedService() throws -> LoadedService? {
        for domain in ["gui/\(getuid())", "user/\(getuid())"] {
            let target = domain + "/" + Self.agentLabel
            let reply = try launchctl(["print", target], captureOutput: true)
            if reply.status == 0 {
                return LoadedService(target: target, environment: Self.loadedEnvironment(from: reply.output))
            }
        }
        return nil
    }

    func serviceTarget() throws -> String? {
        try serviceTarget(registeredHome: registeredDirectory(), loadService: loadedService)
    }

    func serviceTarget(registeredHome: String?, loadService: () throws -> LoadedService?) throws -> String? {
        guard registeredHome == directory.path else { return nil }
        guard let loaded = try loadService() else {
            throw MicropodError.message("CI service is registered but unloaded; run micropod ci install-service")
        }
        return try verifiedTarget(loaded)
    }

    private func verifiedTarget(_ loaded: LoadedService) throws -> String {
        guard let environment = loaded.environment, let home = environment["MICROPOD_CI_HOME"] else {
            throw MicropodError.message("Could not verify the loaded CI service configuration for \(loaded.target)")
        }
        guard home == directory.path else {
            throw MicropodError.message(
                "The loaded CI service uses \(home). Uninstall that service before changing its worker home.")
        }
        let registered = CIWorker(environment: environment)
        guard registered.isNativeRunner == isNativeRunner else {
            throw MicropodError.message(
                "The loaded CI service uses another container engine. Select its MICROPOD_CI_ENGINE or reinstall the service.")
        }
        let activeVMM = try registered.selectedVMM()
        if let requested = resourceEnvironment["MICROPOD_CI_VMM"], !requested.isEmpty {
            let requestedVMM = try selectedVMM()
            guard requestedVMM == activeVMM else {
                throw MicropodError.message(
                    "Requested VMM \(requestedVMM.rawValue), but the loaded CI service uses \(activeVMM.rawValue) at \(home). "
                        + "Uninstall the idle service before changing its VMM.")
            }
        }
        return loaded.target
    }

    func workerForServiceInstallation(recordedEnvironment: [String: String]?) -> CIWorker {
        var environment = (recordedEnvironment ?? [:]).merging(resourceEnvironment) { _, explicit in explicit }
        environment["MICROPOD_CI_HOME"] = directory.path
        return CIWorker(environment: environment)
    }

    public func installService(executable: URL) async throws -> Status {
        let registration = try registeredEnvironment()
        if let home = registration?["MICROPOD_CI_HOME"], home != directory.path {
            throw MicropodError.message("The account's CI service uses \(home)")
        }
        if let loaded = try loadedService() {
            _ = try verifiedTarget(loaded)
            guard registration != nil else {
                throw MicropodError.message(
                    "The CI service is already loaded. Unload it before installing a new registration.")
            }
            return try await start(executable: executable)
        }
        let worker = workerForServiceInstallation(recordedEnvironment: registration)
        let plist = try worker.launchAgent(executable: executable)
        try worker.prepareDirectory()
        guard !worker.isOwned() else {
            throw MicropodError.message("Pause intake and stop the standalone CI worker before installing its service")
        }
        try FileManager.default.createDirectory(
            at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.write(to: agentFile, options: .atomic)
        let gui = "gui/\(getuid())"
        let domain = try launchctl(["print", gui]).status == 0 ? gui : "user/\(getuid())"
        if try launchctl(["bootstrap", domain, agentFile.path]).status != 0 {
            guard let loaded = try loadedService() else {
                throw MicropodError.message("Could not bootstrap \(agentFile.path) in \(domain)")
            }
            _ = try worker.verifiedTarget(loaded)
        }
        return try await worker.start(executable: executable)
    }

    public func uninstallService() async throws {
        guard let path = try registeredDirectory() else { return }
        guard path == directory.path else { throw MicropodError.message("The account's CI service uses \(path)") }
        if let loaded = try loadedService() { _ = try verifiedTarget(loaded) }
        try await stop()
        if let loaded = try loadedService() {
            let target = try verifiedTarget(loaded)
            guard try launchctl(["bootout", target]).status == 0 else {
                throw MicropodError.message("Could not unload CI service \(target)")
            }
        }
        guard try registeredDirectory() == directory.path else {
            throw MicropodError.message("The registered CI service changed while stopping the worker")
        }
        try FileManager.default.removeItem(at: agentFile)
    }
}
