import Foundation
import MicropodCore

public enum RuntimeDependencyProbe {
    /// A fresh, bounded handshake. A cached backend choice alone cannot say
    /// the native API is still available after a dependency restart/upgrade.
    public static func nativeReadiness(_ services: RuntimeServices?) async -> RuntimeDependencyStatus.NativeReadiness {
        guard let services else { return .unobserved }
        if let api = services.api {
            do {
                let health = try await api.ping(timeout: .seconds(2))
                let version = health.semver ?? health.apiServerVersion
                guard health.semver.map(RuntimeServices.isVerified(semver:)) == true else {
                    return .unsupported(version: version)
                }
                if let root = health.installRoot {
                    let path = URL(string: root).flatMap { $0.isFileURL ? $0.path : nil } ?? root
                    return .managedReady(version: version, installRoot: path)
                }
                return .ready(version: version)
            } catch {
                return .unavailable
            }
        }
        if let health = services.health, !services.versionSupported {
            return .unsupported(version: health.semver ?? health.apiServerVersion)
        }
        return .unobserved
    }

    public static func inspect(
        system: SystemService, services: RuntimeServices?
    ) async -> RuntimeDependencyStatus {
        await inspectWithStatus(system: system, services: services).dependency
    }

    /// `inspect`, with the service status it was judged from.
    public static func inspectWithStatus(
        system: SystemService, services: RuntimeServices?
    ) async -> (dependency: RuntimeDependencyStatus, status: Micropod_V1_SystemStatus?) {
        await system.dependencyReport(backend: services?.kind.rawValue ?? "") {
            await nativeReadiness(services)
        }
    }
}
