import Foundation

public enum MicropodError: LocalizedError, Sendable, Equatable {
    /// The `container` binary is missing at the expected path.
    case cliUnavailable(String)
    /// The CLI exited non-zero.
    case cliFailure(command: String, exitCode: Int32, stderr: String)
    /// The command exceeded its timeout and was terminated.
    case cliTimeout(command: String)
    /// Output could not be decoded.
    case decode(String)
    /// The runtime (apiserver) is not running.
    case runtimeNotRunning
    /// The operation is not supported by the installed CLI.
    case unsupported(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable(let path):
            return
                "The `container` CLI was not found at \(path). Install it from the Apple container GitHub releases and try again."
        case .cliFailure(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` failed (exit \(code))\(detail.isEmpty ? "" : ": \(detail)")"
        case .cliTimeout(let command):
            return "`\(command)` timed out and was terminated."
        case .decode(let detail):
            return "Failed to parse `container` output: \(detail)"
        case .runtimeNotRunning:
            return "The container runtime is not running. Start it from the menu bar or the dashboard."
        case .unsupported(let detail):
            return detail
        case .message(let detail):
            return detail
        }
    }
}
