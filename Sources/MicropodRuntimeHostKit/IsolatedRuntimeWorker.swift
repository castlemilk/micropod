import Darwin
import Foundation
import MicropodCore
import MicropodRuntime

/// Runs only after the root helper enters the dedicated user's launchd
/// namespace and drops uid/gid. It never looks up the desktop user's service.
public enum IsolatedRuntimeWorker {
    public static func execute(_ request: IsolatedRuntimeWorkerRequest) async throws -> IsolatedRuntimeObservation {
        let identity = try IsolatedRuntimeIdentity.readRootOwned()
        guard geteuid() == identity.serviceUID, getuid() == identity.serviceUID, getgid() == identity.serviceGID,
            ProcessInfo.processInfo.environment["MICROPOD_ISOLATED_RUNTIME"] == "1", request.selection.isSupported
        else {
            throw MicropodError.message("The worker is outside the dedicated runtime account")
        }
        let domain = try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl")).run(
            .init(arguments: ["managername"]), timeout: .seconds(10)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let managerUID = try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl")).run(
            .init(arguments: ["manageruid"]), timeout: .seconds(10)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard domain == "Background", UInt32(managerUID) == identity.serviceUID else {
            throw MicropodError.message(
                "macOS did not provide an isolated user service namespace; the shared runtime was left unchanged")
        }
        let root = RootRuntimeStorage.apple.appendingPathComponent("versions/" + request.selection.directoryName)
        let receipt = ManagedRuntimeReceipt(selection: request.selection, files: AppleRuntimeRelease.payloadSHA256)
        try await ManagedRuntimeInstaller(root: RootRuntimeStorage.apple).verify(receipt)
        let client = ContainerCLIClient(executableURL: root.appendingPathComponent("bin/container"))
        return try await RuntimeAdmission.$maintenanceOwner.withValue(request.maintenanceOwner) {
            switch request.action {
            case .start:
                let status = try await SystemService(client: client).status()
                if status.status == "running" {
                    let observed = try await observe(client: client, root: root, identity: identity)
                    try await startGateway(identity: identity)
                    return observed
                }
                guard status.status == "stopped" else {
                    throw MicropodError.message("Private runtime state is unconfirmed")
                }
                _ = try await client.run(
                    .init(arguments: [
                        "system", "start", "--app-root", IsolatedRuntimePolicy.appRoot.path, "--install-root",
                        root.path, "--enable-kernel-install", "--timeout", "180",
                    ]), timeout: .seconds(240))
                let observed = try await observe(client: client, root: root, identity: identity)
                try await startGateway(identity: identity)
                return observed
            case .stop:
                let observation = try await observe(client: client, root: root, identity: identity)
                if observation.state == "stopped" {
                    try await stopGateway(identity: identity)
                    return observation
                }
                try await assertNativeIdle(client: client)
                try await stopGateway(identity: identity)
                try await SystemService(client: client).stop()
                guard try await SystemService(client: client).status().status == "stopped" else {
                    throw MicropodError.message("Private runtime stop is unconfirmed")
                }
                return .init(
                    serviceUID: identity.serviceUID, bootstrapDomain: "user/\(identity.serviceUID)", state: "stopped")
            case .status, .verify:
                let observed = try await observe(client: client, root: root, identity: identity)
                if request.requiresIdle {
                    if observed.state != "stopped" { try await assertNativeIdle(client: client) }
                    try await assertGatewayIdle(identity: identity)
                }
                return observed
            case .workload:
                _ = try await observe(client: client, root: root, identity: identity)
                let id = "mp-owned-" + UUID().uuidString.lowercased()
                let output = try await client.run(
                    .init(arguments: [
                        "run", "--rm", "--name", id, "--cpus", "1", "--memory", "256M", "docker.io/library/alpine:3.19",
                        "/bin/echo", "micropod-isolated-runtime-ok",
                    ]), timeout: .seconds(120))
                guard output.contains("micropod-isolated-runtime-ok"),
                    try await !ContainerService(client: client).list().contains(where: { $0.id == id })
                else { throw MicropodError.message("Isolated workload acceptance is unconfirmed") }
                let observed = try await observe(client: client, root: root, identity: identity)
                return .init(
                    serviceUID: observed.serviceUID, bootstrapDomain: observed.bootstrapDomain, state: observed.state,
                    nativeVersion: observed.nativeVersion, nativeAppRoot: observed.nativeAppRoot,
                    nativeInstallRoot: observed.nativeInstallRoot, containerCount: observed.containerCount,
                    workloadOutput: output.trimmingCharacters(in: .whitespacesAndNewlines))
            case .install, .restart, .session, .cancel, .probe:
                throw MicropodError.message("This operation belongs to the root lifecycle owner")
            }
        }
    }

    private static func startGateway(identity: IsolatedRuntimeIdentity) async throws {
        let launchctl = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl"))
        let service = "user/\(identity.serviceUID)/" + IsolatedRuntimeAPIConfiguration.serviceLabel
        let loaded = (try? await launchctl.run(.init(arguments: ["print", service]), timeout: .seconds(5))) != nil
        if !loaded {
            _ = try await launchctl.run(
                .init(arguments: [
                    "bootstrap", "user/\(identity.serviceUID)",
                    IsolatedRuntimeAPIConfiguration.agentURL.path,
                ]), timeout: .seconds(15))
        }
        // Check the listener itself; a launchd process record is insufficient.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let response = try? await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/curl")).run(
                .init(arguments: [
                    "--fail", "--silent", "--max-time", "2", "--unix-socket",
                    IsolatedRuntimeAPIConfiguration.internalSocketURL.path, "http://localhost:45454/health",
                ]), timeout: .seconds(3)),
                let data = response.data(using: .utf8),
                let health = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                health["status"] == "ok"
            {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw MicropodError.message("The managed API listener did not become ready")
    }
    private static func stopGateway(identity: IsolatedRuntimeIdentity) async throws {
        let launchctl = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl"))
        let service = "user/\(identity.serviceUID)/" + IsolatedRuntimeAPIConfiguration.serviceLabel
        if (try? await launchctl.run(.init(arguments: ["print", service]), timeout: .seconds(5))) != nil {
            try await assertGatewayIdle(identity: identity)
            _ = try await launchctl.run(.init(arguments: ["bootout", service]), timeout: .seconds(15))
        }
    }
    private static func assertNativeIdle(client: ContainerCLIClient) async throws {
        let containers = try await ContainerService(client: client).list()
        let machines = try await MachineService(client: client).list()
        guard containers.allSatisfy({ ["stopped", "exited", "dead"].contains($0.state) }),
            machines.allSatisfy({ ["stopped", "exited"].contains($0.state) })
        else { throw MicropodError.message("Private runtime work is still active; no workload was stopped") }
    }
    private static func assertGatewayIdle(identity: IsolatedRuntimeIdentity) async throws {
        let launchctl = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/bin/launchctl"))
        let service = "user/\(identity.serviceUID)/" + IsolatedRuntimeAPIConfiguration.serviceLabel
        if (try? await launchctl.run(.init(arguments: ["print", service]), timeout: .seconds(5))) != nil {
            let response = try await ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/curl")).run(
                .init(arguments: [
                    "--fail", "--silent", "--max-time", "5", "--unix-socket",
                    IsolatedRuntimeAPIConfiguration.internalSocketURL.path,
                    "http://localhost:45454/v1/managed/maintenance",
                ]), timeout: .seconds(7))
            guard let data = response.data(using: .utf8),
                let inventory = try JSONSerialization.jsonObject(with: data) as? [String: Bool],
                inventory["idle"] == true
            else {
                throw MicropodError.message(
                    "Managed API workloads remain active or unconfirmed; the API was left running")
            }
        }
    }

    private static func observe(client: ContainerCLIClient, root: URL, identity: IsolatedRuntimeIdentity) async throws
        -> IsolatedRuntimeObservation
    {
        let system = try await SystemService(client: client).status()
        if system.status == "stopped" {
            return .init(
                serviceUID: identity.serviceUID, bootstrapDomain: "user/\(identity.serviceUID)", state: "stopped")
        }
        guard system.status == "running" else { throw MicropodError.message("Private runtime state is unconfirmed") }
        let api = APIServerClient()
        let health = try await api.ping(timeout: .seconds(5))
        func path(_ text: String?) -> String? {
            guard let text else { return nil }
            return URL(string: text).flatMap { $0.isFileURL ? $0.path : nil } ?? text
        }
        guard health.semver == AppleRuntimeRelease.supported.version,
            path(health.appRoot) == IsolatedRuntimePolicy.appRoot.path,
            path(health.installRoot) == root.path
        else { throw MicropodError.message("The native service did not adopt the dedicated runtime identity") }
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: await api.list(), context: "private runtime inventory")
        return .init(
            serviceUID: identity.serviceUID, bootstrapDomain: "user/\(identity.serviceUID)", state: "nativeReady",
            nativeVersion: health.semver, nativeAppRoot: path(health.appRoot),
            nativeInstallRoot: path(health.installRoot), containerCount: entries.count)
    }
}
