import Darwin
import Foundation
import Security
import SwiftProtobuf

// The live implementations of what RigUpgradeEngine drives. Tests replace
// every one of them; nothing here runs during `swift test`.

/// Runs a short-lived tool and collects its output.
enum RigProcess {
    static func run(_ path: String, _ arguments: [String], timeout: Duration = .seconds(30)) async -> (
        status: Int32, output: String
    ) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let seconds = Double(timeout.components.seconds)
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(
                    returning: (
                        process.terminationStatus,
                        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
            }
        }
    }
}

/// The user's launchd domain through `/bin/launchctl`.
public struct RigLaunchctl: RigLaunchControlling {
    public let domain: String
    public init(domain: String = "gui/\(getuid())") { self.domain = domain }

    public func isLoaded(_ label: String) async -> Bool {
        await RigProcess.run("/bin/launchctl", ["print", domain + "/" + label]).status == 0
    }

    public func bootout(_ label: String) async throws {
        let result = await RigProcess.run("/bin/launchctl", ["bootout", domain + "/" + label], timeout: .seconds(60))
        guard result.status != 0, await isLoaded(label) else { return }
        throw MicropodError.message("launchctl bootout \(label) failed (\(result.status)): \(result.output)")
    }

    public func bootstrap(_ plist: URL, label: String) async throws {
        if await isLoaded(label) { return }
        let result = await RigProcess.run("/bin/launchctl", ["bootstrap", domain, plist.path])
        guard result.status != 0, !(await isLoaded(label)) else { return }
        throw MicropodError.message("launchctl bootstrap \(label) failed (\(result.status)): \(result.output)")
    }
}

/// Every running process's executable path.
public enum RigProcessTable {
    public static func processes() -> [(pid: Int32, path: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard actual > 0, actual <= pids.count else { return [] }
        return pids.prefix(Int(actual)).compactMap { pid in
            UpdateServiceWitness.processPath(pid).map { (pid, $0) }
        }
    }

    @Sendable public static func executables() -> [String] { processes().map(\.path) }

    /// The executable of a TCP port's single listener.
    @Sendable public static func portOwner(_ port: UInt16) -> String? {
        guard let owners = EndpointOwners.tcpListeners(port: port), owners.count == 1, let pid = owners.first else {
            return nil
        }
        return UpdateServiceWitness.processPath(pid)
    }
}

/// The desktop app and the agents it spawns from its own bundle.
public struct RigAppProcesses: RigAppControlling {
    /// Agents an app outside the dedicated runtime runs as its children.
    static let agents = ["MicropodAPI", "micropod-docker-shim", "micropod-sharedfs"]
    public init() {}

    static func mainExecutable(_ app: URL) -> String {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info =
            FileManager.default.contents(atPath: plist.path).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            }
        let name = info?["CFBundleExecutable"] as? String ?? "Micropod"
        return app.appendingPathComponent("Contents/MacOS/" + name).path
    }

    private func pids(_ paths: Set<String>) -> [Int32] {
        RigProcessTable.processes().filter { paths.contains($0.path) }.map(\.pid)
    }

    public func isRunning(_ app: URL) async -> Bool { !pids([Self.mainExecutable(app)]).isEmpty }

    public func stop(_ app: URL, timeout: Duration) async throws {
        let agents = Set(Self.agents.map { app.appendingPathComponent("Contents/MacOS/" + $0).path })
        // The app ends its own agents on SIGTERM; stragglers get their own.
        try await terminate([Self.mainExecutable(app)], timeout: timeout)
        try await terminate(agents, timeout: .seconds(10))
    }

    private func terminate(_ paths: Set<String>, timeout: Duration) async throws {
        var running = pids(paths)
        guard !running.isEmpty else { return }
        for pid in running { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + timeout
        while !running.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            running = pids(paths)
        }
        for pid in running { kill(pid, SIGKILL) }
        for _ in 0..<25 where !pids(paths).isEmpty { try await Task.sleep(for: .milliseconds(200)) }
        guard pids(paths).isEmpty else {
            throw MicropodError.message("\(paths.sorted().joined(separator: ", ")) did not exit")
        }
    }

    public func launch(_ app: URL) async throws {
        if await isRunning(app) { return }
        let result = await RigProcess.run("/usr/bin/open", ["-g", app.path])
        guard result.status == 0 else {
            throw MicropodError.message("Could not launch \(app.path): \(result.output)")
        }
        for _ in 0..<150 {
            if await isRunning(app) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw MicropodError.message("\(app.lastPathComponent) did not start")
    }
}

/// Cuttlefish's maintenance socket, through the shared-runtime protocol:
/// `drain` holds new leases and preempts in-flight attempts after the rig's
/// bounded grace; `abort` then `abortComplete` lets the rig take work again.
/// No runtime admission fence or host fence is ever taken.
public struct RigCuttlefishDrain: RigDrainCoordinating {
    public let home: URL
    /// Constant per host, so every call names the same operation spec.
    public let installRoot: URL
    public init(home: URL, installRoot: URL) {
        self.home = home
        self.installRoot = installRoot
    }

    private func transition(_ operation: UUID, _ action: String) async throws -> RuntimeRigReceipt? {
        try await RuntimeRigClient(ownerHome: home).transition(
            operation: operation, action: action, installRoot: installRoot, localGeneration: 1,
            targetState: "running")
    }

    public func isConfigured() -> Bool { RuntimeRigClient.hasConfiguredRig(ownerHome: home) }

    public func drain(_ operation: UUID) async throws -> RigDrainReply {
        do {
            let receipt = try await transition(operation, "drain")
            return RigDrainReply(drained: receipt?.phase == "drained", reason: receipt?.reason)
        } catch let error as RuntimeRigAdmissionError {
            throw RigDrainError.unavailable(error.localizedDescription)
        }
    }

    public func release(_ operation: UUID) async throws {
        do {
            _ = try await transition(operation, "abort")
            let receipt = try await transition(operation, "abortComplete")
            guard receipt?.phase == "cancelled" else {
                throw MicropodError.message("Cuttlefish did not confirm the release (\(receipt?.phase ?? "no answer"))")
            }
        } catch let error as MicropodError where error.errorDescription?.contains("operation is unknown") == true {
            // The rig never recorded this drain, so it holds nothing.
        }
    }
}

/// Health gate probes: sockets accept, the Connect API answers Ping with the
/// expected release and components, the app reports itself, and a smoke
/// container runs and is removed through the same API.
public struct RigHealthProbe: RigHealthProbing {
    public init() {}

    private func call<Response: Message>(
        port: UInt16, _ service: String, _ method: String, _ body: some Message, timeout: TimeInterval = 5
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/micropod.v1.\(service)/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.jsonUTF8Data()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MicropodError.message(
                "\(method) answered \((response as? HTTPURLResponse)?.statusCode ?? 0): "
                    + String(decoding: data.prefix(300), as: UTF8.self))
        }
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        return try Response(jsonUTF8Data: data, options: options)
    }

    private func ping(_ port: UInt16) async throws -> Micropod_V1_PingResponse {
        try await call(port: port, "SystemService", "Ping", Micropod_V1_Empty())
    }

    public func connectAnswers(port: UInt16) async -> Bool { (try? await ping(port)) != nil }

    public func check(_ expectation: RigHealthExpectation) async -> RigHealthReport {
        var report = RigHealthReport()
        for socket in expectation.sockets where ComponentProbe.observeSocket(socket) != .accepting {
            report.failures.append("\(socket) does not accept connections")
        }
        if expectation.connectRequired {
            do {
                let ping = try await ping(expectation.connectPort)
                report.runtimeAvailable = ping.status == "running"
                if expectation.connectVersionGated, ping.micropodVersion != expectation.version {
                    report.failures.append(
                        "The Connect API reports \(ping.micropodVersion.isEmpty ? "no release" : ping.micropodVersion), "
                            + "not \(expectation.version)")
                }
                for name in expectation.retainedComponents {
                    let component = ping.components.first { $0.name == name }
                    if component?.version != expectation.version || component?.state != "running" {
                        report.failures.append(
                            "\(name) is \(component?.state ?? "unreported") at \(component?.version ?? "no release"), "
                                + "not running \(expectation.version)")
                    }
                }
            } catch {
                report.failures.append(
                    "The Connect API on :\(expectation.connectPort) did not answer Ping: \(error.localizedDescription)")
            }
        }
        if expectation.appRunning {
            do {
                let status = try await AppControlClient(socketPath: expectation.appControlSocket, requestTimeout: 3)
                    .updateStatus()
                let version = status["currentVersion"] as? String ?? ""
                let revision = status["currentSourceRevision"] as? String ?? ComponentProbe.unknown
                if version != expectation.version
                    || (revision != ComponentProbe.unknown && revision != expectation.revision)
                {
                    report.failures.append(
                        "The app reports \(version) (\(revision.prefix(12))), not \(expectation.version)")
                }
            } catch {
                report.failures.append("The app does not answer on its control socket: \(error.localizedDescription)")
            }
        }
        return report
    }

    public func smoke(_ expectation: RigHealthExpectation, image: String) async throws {
        let port = expectation.connectPort
        guard (try await ping(port)).status == "running" else {
            throw MicropodError.message("The Apple runtime is not running")
        }
        var run = Micropod_V1_RunContainerRequest()
        run.image = image
        run.name =
            "mp-rig-smoke-" + expectation.operation.uuidString.prefix(8).lowercased() + "-"
            + UUID().uuidString.prefix(4).lowercased()
        run.detach = true
        run.entrypoint = "/bin/sh"
        run.arguments = ["-c", "exit 0"]
        run.labels = ["micropod.rig-upgrade": expectation.operation.uuidString]
        let created: Micropod_V1_ContainerRef = try await call(
            port: port, "ContainerService", "RunContainer", run, timeout: 300)
        let id = created.id.isEmpty ? run.name : created.id
        var delete = Micropod_V1_DeleteContainerRequest()
        delete.id = id
        delete.force = true
        do {
            var wait = Micropod_V1_WaitContainerRequest()
            wait.id = id
            wait.timeoutSeconds = 60
            let result: Micropod_V1_WaitContainerResponse = try await call(
                port: port, "ContainerService", "WaitContainer", wait, timeout: 75)
            guard result.exited, result.exitCode == 0 else {
                throw MicropodError.message("The smoke container ended \(result.state) with exit \(result.exitCode)")
            }
        } catch {
            let _: Micropod_V1_Empty? = try? await call(port: port, "ContainerService", "DeleteContainer", delete)
            throw error
        }
        let _: Micropod_V1_Empty = try await call(port: port, "ContainerService", "DeleteContainer", delete)
    }
}

/// Micropod's Developer ID signature on a whole bundle or one executable.
public struct RigCodeSignatureVerifier: RigBundleVerifying {
    public init() {}

    public func verifyApp(_ bundle: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule =
            "anchor apple generic and certificate leaf[subject.OU] = \"" + IsolatedRuntimePolicy.teamIdentifier
            + "\" and identifier \"com.skunkworq.micropod\""
        let flags = SecCSFlags(
            rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode))
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else {
            throw MicropodError.message("\(bundle.path) does not carry Micropod's sealed Developer ID signature")
        }
    }

    public func verifyExecutable(_ url: URL, identifier: String) throws {
        try RuntimeCodeIdentity.verifyExecutable(url, identifier: identifier)
    }
}

extension RigUpgradeEnvironment {
    /// The host's real launchd, processes, rig coordinator and probes.
    public static func live(layout: RigUpgradeLayout, log: @escaping @Sendable (String) -> Void = { _ in }) -> Self {
        Self(
            launch: RigLaunchctl(), app: RigAppProcesses(),
            drain: RigCuttlefishDrain(home: layout.home, installRoot: layout.releasesRoot),
            health: RigHealthProbe(), verifier: RigCodeSignatureVerifier(),
            dedicatedRuntime: { (try? IsolatedRuntimeIdentity.readRootOwned())?.ownerUID == getuid() },
            runtimeMaintenance: {
                RuntimeAdmission(root: ManagedRuntimeLocation.root.appendingPathComponent("admission")).isClosed
                    || RuntimeAdmission(root: IsolatedRuntimePolicy.admissionRoot).isClosed
            },
            runningExecutables: RigProcessTable.executables, portOwner: RigProcessTable.portOwner, log: log)
    }
}
