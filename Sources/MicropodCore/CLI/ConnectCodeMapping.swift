import Foundation

/// The single error → Connect wire-code table. The Connect mount in
/// `MicropodAPI` (and any other Connect-speaking transport) delegates here so
/// the classification is testable without spinning up the HTTP server.
///
/// Codes are the Connect spec's snake_case strings (`"not_found"`,
/// `"unavailable"`, …). Anything that means "the runtime is not answering"
/// — XPC transport failures, the `container` CLI's runtime-down text, a
/// missing CLI — is `unavailable`, so clients back off and retry instead of
/// treating an outage as a server bug (`internal`).
public enum ConnectCodeMapping {
    public static func code(for error: Error) -> String {
        if let error = error as? MicropodError {
            switch error {
            case .transport, .runtimeNotRunning, .cliUnavailable:
                return "unavailable"
            case .cliTimeout:
                return "deadline_exceeded"
            case .unsupported:
                return "unimplemented"
            case .pullStalled:
                return "aborted"
            case .cliFailure(_, _, let stderr) where indicatesRuntimeDown(stderr):
                return "unavailable"
            case .cliFailure, .decode, .message:
                return prefixed(error.localizedDescription)
            }
        }
        return prefixed(error.localizedDescription)
    }

    /// True when CLI output carries one of the `container` CLI's own
    /// runtime-down signatures: the apiserver is unregistered with launchd,
    /// or the XPC connection to it is gone. Deliberately does not match a
    /// bare "not running" — `invalidState: container X is not running` is a
    /// stopped *container*, which is a caller error, not an outage.
    public static func indicatesRuntimeDown(_ text: String) -> Bool {
        let lower = text.lowercased()
        return runtimeDownSignatures.contains { lower.contains($0) }
    }

    /// Lowercased substrings, sourced from `container` 1.3.1
    /// (`SystemStatus.swift`, `Application.swift`) and XPC's error strings.
    static let runtimeDownSignatures: [String] = [
        "apiserver is not running",
        "not registered with launchd",
        "xpc connection error",
        "connection invalid",
        "connection interrupted",
        "ensure container system service has been started",
        "\"status\":\"unregistered\"",
        "\"status\":\"not running\"",
    ]

    /// Reads an upstream "camelCaseCode: message" prefix into a wire code.
    /// Runtime errors arrive preformatted this way (e.g. "notFound: container
    /// with ID … not found"); anything else is `internal`.
    static func prefixed(_ text: String) -> String {
        guard let colon = text.firstIndex(of: ":") else { return "internal" }
        switch String(text[..<colon]) {
        case "notFound": return "not_found"
        case "invalidArgument": return "invalid_argument"
        case "alreadyExists": return "already_exists"
        case "unavailable", "runtimeNotRunning": return "unavailable"
        case "unauthenticated": return "unauthenticated"
        case "permissionDenied": return "permission_denied"
        case "failedPrecondition": return "failed_precondition"
        case "resourceExhausted": return "resource_exhausted"
        case "deadlineExceeded", "timeout": return "deadline_exceeded"
        default: return "internal"
        }
    }
}
