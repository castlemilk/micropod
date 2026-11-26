import Foundation

/// The dedicated account serves data for its fixed Apple store. Changing
/// engines, endpoints, application software or dependency lifecycle belongs
/// to the separate owner controls, never to an API data capability.
enum IsolatedRuntimeRequestPolicy {
    static func allows(_ path: String) -> Bool {
        let controls: Set<String> = [
            "ListRuntimes", "SetDefaultRuntime", "UpdateRuntime", "CheckForUpdates", "GetUpdateStatus", "ApplyUpdate",
            // RigService: the rig mode is the default runtime by another
            // name (SetRigMode writes it), and the machine's payload and
            // lifecycle are dependency lifecycle. Their REST twins are
            // /v1/rig/mode and /v1/rig/hvf/*.
            "GetRigMode", "SetRigMode", "GetHVFUpdateStatus", "ApplyHVFUpdate", "RollbackHVFUpdate", "ControlMachine",
        ]
        // Connect dispatch selects procedures by their last path component.
        // Refuse aliases through any service name as well as the canonical one.
        if path.hasPrefix("/api/micropod.v1."), let procedure = path.split(separator: "/").last,
            controls.contains(String(procedure))
        {
            return false
        }
        return !["/v1/runtimes", "/v1/system/runtime", "/v1/system/update", "/v1/rig/mode", "/v1/rig/hvf"].contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }
}
