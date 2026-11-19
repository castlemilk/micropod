import Foundation

public enum IsolatedRuntimeAction: String, Codable, Sendable {
    case status, install, start, stop, restart, verify, workload, session, cancel, probe
    /// Replace the setup app, root helper, dedicated API and Apple build with
    /// the ones the installed desktop app carries (docs/runtime-component-update.md).
    case update
    /// Return to the exact setup app bytes the last component update replaced.
    case rollback
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
    public var runtimeRig: RuntimeCoordinationRetainedReceipt?
    public var runtimeRigAttempted: Bool?
    public var runtimeCancelledBeforeAction: Bool?
    public var runtimeActionStarted: Bool?
    /// A start whose action left the runtime verified stopped, released to
    /// the coordinator as stopped: rig intake stays paused until a start.
    public var runtimeReleasedStopped: Bool?
    public var selection: ManagedRuntimeLocation.Selection?
    public var nativeVersion: String?
    public var nativeState: String?
    public var nativeAppRoot: String?
    public var nativeInstallRoot: String?
    public var error: String?
    public var pendingOperationCount: Int?
    public var pendingOperationRoutes: [String]?
    /// Ephemeral capability, returned only over authenticated IPC. Never journaled.
    public var session: IsolatedRuntimeAPISession?
    /// The component update protocol this helper implements; absent from
    /// helpers that cannot update themselves. Status replies only.
    public var componentProtocol: Int?
    /// The current or last runtime component update. Status replies only;
    /// `operation.json` never carries it.
    public var componentUpdate: RuntimeComponentUpdateSummary?
    /// `protected`, or `unprotected: <reason>`: whether this helper runs as
    /// the root-owned authority (docs/runtime-component-update.md). Status
    /// replies only.
    public var componentProtection: String?
    /// The Mach service the answering helper listens on: the authority's,
    /// or the legacy SMAppService job's. Status replies only.
    public var helperService: String?
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
    public let requiresIdle: Bool
    public init(
        action: IsolatedRuntimeAction, selection: ManagedRuntimeLocation.Selection, maintenanceOwner: UUID? = nil,
        requiresIdle: Bool = false
    ) {
        self.action = action
        self.selection = selection
        self.maintenanceOwner = maintenanceOwner
        self.requiresIdle = requiresIdle
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
    /// Every container id the runtime listed, for proving stale admission
    /// receipts dead. Nil from older workers and when the runtime is stopped.
    public let containerIDs: [String]?
    public init(
        serviceUID: UInt32, bootstrapDomain: String, state: String, nativeVersion: String? = nil,
        nativeAppRoot: String? = nil, nativeInstallRoot: String? = nil, containerCount: Int = 0,
        workloadOutput: String? = nil, containerIDs: [String]? = nil
    ) {
        self.serviceUID = serviceUID
        self.bootstrapDomain = bootstrapDomain
        self.state = state
        self.nativeVersion = nativeVersion
        self.nativeAppRoot = nativeAppRoot
        self.nativeInstallRoot = nativeInstallRoot
        self.containerCount = containerCount
        self.workloadOutput = workloadOutput
        self.containerIDs = containerIDs
    }
}
