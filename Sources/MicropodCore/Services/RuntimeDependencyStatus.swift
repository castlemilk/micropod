import Foundation

/// A read-only observation, never permission to install, stop or restart.
/// Native readiness must come from a live native handshake, not CLI presence.
public struct RuntimeDependencyStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case checking, unsupportedHost, missingCLI, stopped, starting, stopping
        case nativeReady, cliFallback, unsupportedVersion, apiUnavailable, degraded

        public var title: String {
            switch self {
            case .checking: "Checking runtime"
            case .unsupportedHost: "Unsupported Mac"
            case .missingCLI: "Apple container missing"
            case .stopped: "Runtime stopped"
            case .starting: "Starting runtime"
            case .stopping: "Stopping runtime"
            case .nativeReady: "Native API ready"
            case .cliFallback: "CLI fallback"
            case .unsupportedVersion: "Runtime version unqualified"
            case .apiUnavailable: "Native API unavailable"
            case .degraded: "Runtime needs attention"
            }
        }
    }

    public enum NativeReadiness: Sendable {
        case unobserved
        case ready(version: String)
        case managedReady(version: String, installRoot: String)
        case unsupported(version: String)
        case unavailable
    }

    public let state: State
    public let cliPath: String
    public let cliVersion: String
    public let cliVersionSupported: Bool
    public let apiServerVersion: String
    public let backend: String
    public let runtimeInstallRoot: String
    public let maintenanceBlocked: Bool
    public let message: String
    public let nextAction: String
    public let installerURL: String

    public static var hostSupported: Bool {
        #if arch(arm64)
            ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        #else
            false
        #endif
    }

    public init(
        cliAvailable: Bool, cliPath: String, status: Micropod_V1_SystemStatus?,
        statusFailed: Bool = false, backend: String = "cli", native: NativeReadiness = .unobserved,
        starting: Bool = false, stopping: Bool = false, unresponsive: Bool = false,
        hostSupported: Bool = Self.hostSupported
    ) {
        self.cliPath = cliPath
        installerURL = ContainerExecutableLocator.installerURL.absoluteString
        cliVersion = status?.cliVersion ?? ""
        cliVersionSupported = AppleContainerCompatibility.isVerified(semver: cliVersion)
        apiServerVersion =
            switch native {
            case .ready(let version), .managedReady(let version, _), .unsupported(let version): version
            case .unobserved, .unavailable: status?.apiServerVersion ?? ""
            }
        self.backend = backend
        maintenanceBlocked =
            cliPath.hasPrefix(IsolatedRuntimePolicy.root.path + "/")
            ? RuntimeAdmission(root: IsolatedRuntimePolicy.admissionRoot).isClosed : RuntimeAdmission.shared.isClosed
        runtimeInstallRoot = if case .managedReady(_, let root) = native { root } else { "" }

        if !hostSupported {
            state = .unsupportedHost
            message = "Apple container requires Apple silicon and macOS 26 or later."
            nextAction = "Use a supported Mac and macOS version."
        } else if !cliAvailable {
            state = .missingCLI
            message = "Apple container is not installed at the configured or discovered path."
            nextAction =
                "Get the signed installer from Apple's supported release, then check again. Check any configured CLI path."
        } else if stopping {
            state = .stopping
            message = "Stopping the Apple container runtime."
            nextAction = "Wait for the service to stop. Automatic startup remains paused."
        } else if starting {
            state = .starting
            message = "Starting the Apple container runtime."
            nextAction = "Wait for the runtime readiness check."
        } else if statusFailed || unresponsive {
            state = .degraded
            message = "The installed runtime is not responding correctly."
            nextAction = "Check runtime diagnostics. Automatic recovery will not stop running work."
        } else if status?.status == "stopped" {
            state = .stopped
            message = "Apple container is installed; its system service is stopped."
            nextAction =
                cliVersionSupported
                ? "Start the runtime when this rig is ready."
                : "Choose a supported CLI release before enabling automatic startup on this rig."
        } else if status?.status == "running" {
            switch native {
            case .ready, .managedReady:
                state = .nativeReady
                message = "The native Apple container API answered its readiness check."
                nextAction = "No setup required."
            case .unsupported(let version):
                state = .unsupportedVersion
                message = "Apple container \(version) has not been qualified for Micropod's native backend."
                nextAction = "Use a supported runtime version for native rig workloads."
            case .unavailable:
                state = .apiUnavailable
                message = "The service reports running, but the native API is unavailable."
                nextAction = "Check the runtime service and native API diagnostics."
            case .unobserved:
                state = .cliFallback
                message = "The runtime answers through the CLI; native readiness is unconfirmed."
                nextAction = "Check the Micropod API before admitting native rig workloads."
            }
        } else {
            state = status == nil ? .checking : .degraded
            message = "Runtime readiness has not been established."
            nextAction = "Check the runtime status again."
        }
    }
}
