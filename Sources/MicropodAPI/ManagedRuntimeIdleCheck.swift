import MicropodCore

/// Disabling an engine hides it from the routed list but does not terminate
/// its VMs. Check the API's owned sandbox sessions independently of visibility.
enum ManagedRuntimeIdleCheck {
    static func check(
        visible: () async throws -> [Micropod_V1_Container],
        ownedSandboxes: () async throws -> [Micropod_V1_Container]
    ) async throws -> Bool {
        let listed = try await visible()
        let owned = try await ownedSandboxes()
        return (listed + owned).allSatisfy { ["stopped", "exited", "dead"].contains($0.state) }
    }
}
