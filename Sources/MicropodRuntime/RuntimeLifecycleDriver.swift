import Foundation
import MicropodCore

/// IO boundary for lifecycle orchestration. Tests replace the runtime and
/// package operations, while production always uses the pinned Apple release.
public protocol RuntimeLifecycleDriving: Sendable {
    func stage(root: URL) async throws -> ManagedRuntimeReceipt
    func verifyStaged(_ receipt: ManagedRuntimeReceipt, root: URL) async throws
    func assertIdle(executable: URL) async throws
    func status(executable: URL) async throws -> String
    func stop(executable: URL) async throws
    func start(executable: URL) async throws
    func verify(executable: URL, installRoot: URL, stopped: Bool) async throws
}

public struct NativeRuntimeLifecycleDriver: RuntimeLifecycleDriving {
    public init() {}
    public func stage(root: URL) async throws -> ManagedRuntimeReceipt {
        try await ManagedRuntimeInstaller(root: root).prepare()
    }
    public func verifyStaged(_ receipt: ManagedRuntimeReceipt, root: URL) async throws {
        try await ManagedRuntimeInstaller(root: root).verify(receipt)
    }
    public func assertIdle(executable: URL) async throws {
        let client = ContainerCLIClient(executableURL: executable)
        if try await SystemService(client: client).status().status == "stopped" { return }
        let containers = try await ContainerService(client: client).list()
        let machines = try await MachineService(client: client).list()
        guard containers.allSatisfy({ ["stopped", "exited", "dead"].contains($0.state) }),
            machines.allSatisfy({ ["stopped", "exited"].contains($0.state) })
        else {
            throw MicropodError.message("Running, pending or unmanaged runtime work prevents maintenance")
        }
    }
    public func status(executable: URL) async throws -> String {
        try await SystemService(client: ContainerCLIClient(executableURL: executable)).status().status
    }
    public func stop(executable: URL) async throws {
        try await SystemService(client: ContainerCLIClient(executableURL: executable)).stop()
    }
    public func start(executable: URL) async throws {
        _ = try await ContainerCLIClient(executableURL: executable).run(
            .init(arguments: ["system", "start", "--enable-kernel-install"]), timeout: .seconds(300))
    }
    public func verify(executable: URL, installRoot: URL, stopped: Bool) async throws {
        let system = SystemService(client: ContainerCLIClient(executableURL: executable))
        if stopped {
            guard try await system.status().status == "stopped" else {
                throw MicropodError.message("Runtime stop is unconfirmed")
            }
            return
        }
        guard try await system.cliVersion() == AppleRuntimeRelease.supported.version else {
            throw MicropodError.message("Installed CLI version did not match")
        }
        let api = APIServerClient()
        let health = try await api.ping(timeout: .seconds(5))
        let actual = health.installRoot.flatMap { value -> URL? in
            if let url = URL(string: value), url.isFileURL { return url }
            return value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
        }
        guard health.semver == AppleRuntimeRelease.supported.version,
            actual?.resolvingSymlinksInPath() == installRoot.resolvingSymlinksInPath()
        else {
            throw MicropodError.message("Native API did not adopt the selected managed runtime")
        }
        _ = try await api.list()
    }
}
