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
                return health.semver.map(RuntimeServices.isVerified(semver:)) == true
                    ? .ready(version: version) : .unsupported(version: version)
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
        await system.dependencyStatus(backend: services?.kind.rawValue ?? "") {
            await nativeReadiness(services)
        }
    }
}
