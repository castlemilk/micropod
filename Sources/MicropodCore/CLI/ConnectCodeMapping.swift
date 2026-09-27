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
            case .cliFailure(let command, _, let stderr):
                return cliStderrCode(command: command, stderr: stderr)
            case .decode, .message:
                return prefixed(error.localizedDescription)
            }
        }
        return prefixed(error.localizedDescription)
    }

    /// Classifies a `container` CLI failure from the first `Error:` line of
    /// its stderr — the line ArgumentParser prints for the thrown error.
    /// `cliFailure`'s own message keeps its "`cmd` failed (exit N): …"
    /// wrapper; only the classification looks inside. Three shapes are
    /// read, in this order (all verified against `container` 1.3.1):
    ///
    /// 1. `Error: <code>: "<detail>"` — a `ContainerizationError` rendered
    ///    with its code — through the same prefix table as XPC errors.
    /// 2. `Error: internalError: "…" (cause: "<code>: …")` — the CLI wraps
    ///    the runtime's answer for some verbs; `container delete <missing>`
    ///    prints `internalError: "failed to delete container" (cause:
    ///    "notFound: "container with ID x not found"")`, so the code comes
    ///    from the cause (nested causes are read through to the first
    ///    classifiable one).
    /// 3. A bare message — `ContainerizationError.errorDescription` is the
    ///    message alone, without its code — for the CLI's own duplicate-id
    ///    refusals: `container create` prints `container already exists:
    ///    <id>` and `container run` prints `container with id <id> already
    ///    exists`. An `already exists` phrase is `already_exists`.
    ///
    /// Everything else is `internal`, and so is every failure of a command
    /// that relays the guest's stderr (``relaysGuestStderr(command:)``):
    /// the guest may print an `Error:` line of its own (`execDetailed`
    /// reports the exit code and text instead of classifying).
    static func cliStderrCode(command: String, stderr: String) -> String {
        guard !relaysGuestStderr(command: command) else { return "internal" }
        for line in stderr.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(cliErrorPrefix) else { continue }
            return classifyCLIErrorLine(String(trimmed.dropFirst(cliErrorPrefix.count)))
        }
        return "internal"
    }

    private static let cliErrorPrefix = "Error: "
    private static let cliCausePrefix = "(cause: \""

    /// Commands whose stderr and exit code are the guest process's, not the
    /// CLI's: `container exec …`, and an attached `container run …` — one
    /// without `--detach` (`-d`) right after the verb (REST `detach: false`;
    /// Connect always runs detached). `ContainerCommandFactory.run` emits
    /// `--detach` first or not at all, and only that position is read:
    /// `command` is the argv joined by spaces (`ContainerCommand.displayName`),
    /// so a later value with a space in it — `--env "OPTS=-v --detach"` —
    /// must not read as a flag. The verb is the first word after the binary
    /// name; a `cliFailure` names the command that way.
    static func relaysGuestStderr(command: String) -> Bool {
        let words = command.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= 2, words[0] == "container" else { return false }
        switch words[1] {
        case "exec":
            return true
        case "run":
            return !(words.count > 2 && (words[2] == "--detach" || words[2] == "-d"))
        default:
            return false
        }
    }

    /// The text after `Error: ` → wire code (see ``cliStderrCode``).
    static func classifyCLIErrorLine(_ text: String) -> String {
        let direct = prefixed(text)
        if direct != "internal" { return direct }
        if text.hasPrefix("internalError:"), let cause = causeCode(in: text) {
            return cause
        }
        if text.lowercased().contains("already exists") { return "already_exists" }
        return "internal"
    }

    /// The first classifiable code among the `(cause: "<code>: …")`
    /// suffixes of a CLI error line, outermost first; nil when none.
    private static func causeCode(in text: String) -> String? {
        var rest = Substring(text)
        while let range = rest.range(of: cliCausePrefix) {
            rest = rest[range.upperBound...]
            let code = prefixed(String(rest))
            if code != "internal" { return code }
        }
        return nil
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
        // `exists` is `ContainerizationError.Code.exists` as the runtime
        // prints it (XPC error payloads and the CLI's `Error:` line alike).
        case "alreadyExists", "exists": return "already_exists"
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
