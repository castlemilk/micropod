import Foundation

/// The dedicated account serves data for its fixed Apple store. Changing
/// engines, endpoints, application software or dependency lifecycle belongs
/// to the separate owner controls, never to an API data capability.
enum IsolatedRuntimeRequestPolicy {
    static func allows(_ path: String) -> Bool {
        let controls: Set<String> = [
            "ListRuntimes", "SetDefaultRuntime", "UpdateRuntime", "CheckForUpdates", "GetUpdateStatus", "ApplyUpdate",
        ]
        // Connect dispatch selects procedures by their last path component.
        // Refuse aliases through any service name as well as the canonical one.
        if path.hasPrefix("/api/micropod.v1."), let procedure = path.split(separator: "/").last,
            controls.contains(String(procedure))
        {
            return false
        }
        return !["/v1/runtimes", "/v1/system/runtime", "/v1/system/update"].contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }
}
