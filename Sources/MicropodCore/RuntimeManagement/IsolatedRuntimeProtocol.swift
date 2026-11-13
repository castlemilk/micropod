import Foundation

public enum IsolatedRuntimeAction: String, Codable, Sendable {
    case status, install, start, stop, restart, verify, workload, session, cancel, probe
}

public struct IsolatedRuntimeRequest: Codable, Sendable {
    public let operation: UUID
    public let action: IsolatedRuntimeAction
    public init(operation: UUID = UUID(), action: IsolatedRuntimeAction) {
        self.operation = operation
        self.action = action
    }
}

public struct IsolatedRuntimeStatus: Codable, Sendable {
    public var operation: UUID?
    public var ownerUID: UInt32?
    public var action: IsolatedRuntimeAction?
    public var phase: String
    public var message: String
    public var identity: IsolatedRuntimeIdentity?
    public var workerBirth: RuntimeProcessBirth?
    public var pendingSelection: ManagedRuntimeLocation.Selection?
    public var workerSHA256: String?
    public var localGeneration: UInt64?
    public var rig: RuntimeRigReceipt?
    public var actionVerified: Bool?
    public var rigAttempted: Bool?
    public var selection: ManagedRuntimeLocation.Selection?
    public var nativeVersion: String?
    public var nativeState: String?
    public var nativeAppRoot: String?
    public var nativeInstallRoot: String?
    public var error: String?
    /// Ephemeral capability, returned only over authenticated IPC. Never journaled.
    public var session: IsolatedRuntimeAPISession?
    public var isTerminal: Bool {
        ["idle", "completed", "cancelled", "blocked", "failed", "recoveryRequired"].contains(phase)
    }
    public init(phase: String = "idle", message: String = "The managed runtime has not been set up") {
        self.phase = phase
        self.message = message
    }
}

public struct IsolatedRuntimeWorkerRequest: Codable, Sendable {
    public let action: IsolatedRuntimeAction
    public let selection: ManagedRuntimeLocation.Selection
    public let maintenanceOwner: UUID?
    public init(
        action: IsolatedRuntimeAction, selection: ManagedRuntimeLocation.Selection, maintenanceOwner: UUID? = nil
    ) {
        self.action = action
        self.selection = selection
        self.maintenanceOwner = maintenanceOwner
    }
}

public struct IsolatedRuntimeObservation: Codable, Sendable {
    public let serviceUID: UInt32
    public let bootstrapDomain: String
    public let state: String
    public let nativeVersion: String?
    public let nativeAppRoot: String?
    public let nativeInstallRoot: String?
    public let containerCount: Int
    public let workloadOutput: String?
    public init(
        serviceUID: UInt32, bootstrapDomain: String, state: String, nativeVersion: String? = nil,
        nativeAppRoot: String? = nil, nativeInstallRoot: String? = nil, containerCount: Int = 0,
        workloadOutput: String? = nil
    ) {
        self.serviceUID = serviceUID
        self.bootstrapDomain = bootstrapDomain
        self.state = state
        self.nativeVersion = nativeVersion
        self.nativeAppRoot = nativeAppRoot
        self.nativeInstallRoot = nativeInstallRoot
        self.containerCount = containerCount
        self.workloadOutput = workloadOutput
    }
}
