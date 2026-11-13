import Foundation

/// All owner-facing control surfaces use the same authenticated authority.
/// A desktop app exiting cannot strand an approved runtime operation.
public enum ManagedRuntimeControl {
    public static func request(
        _ command: String,
        call: @Sendable (IsolatedRuntimeRequest) async throws -> IsolatedRuntimeStatus = {
            try await IsolatedRuntimeClient().call($0)
        }
    ) async throws -> IsolatedRuntimeStatus {
        let action: IsolatedRuntimeAction
        switch command {
        case "repair": action = .install
        case "recover": action = .verify
        case "operation": action = .status
        default:
            guard let requested = IsolatedRuntimeAction(rawValue: command),
                [.install, .start, .stop, .restart, .cancel].contains(requested)
            else { throw MicropodError.message("Unknown managed runtime action '\(command)'") }
            action = requested
        }
        let response = try await call(.init(action: action))
        if command != "operation", response.isTerminal, let error = response.error {
            throw MicropodError.message(error)
        }
        return response
    }
}
