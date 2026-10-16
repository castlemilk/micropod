import Foundation

/// ImagePullBudget v1: API requests perform one CLI pull; an acknowledged
/// caller owns retries across requests. Standalone ImageService.pull is separate.
public struct ImagePullBudget: Sendable, Equatable {
    public struct InvalidHeaders: LocalizedError, Sendable {
        public var errorDescription: String? { "Invalid image pull budget headers" }
    }

    let callerAttempt: Int?
    let maximumTotalAttempts: Int
    let deadlineUnixMilliseconds: Int64?

    /// HTTPRequest supplies lowercased header names. Partial or malformed
    /// budgets must fail before invoking the CLI, rather than falling back.
    public static func api(headers: [String: String]) throws -> Self {
        let names = [
            "micropod-pull-budget-owner", "micropod-pull-attempt",
            "micropod-pull-max-attempts", "micropod-pull-deadline-unix-ms",
        ]
        guard names.contains(where: { headers[$0] != nil }) else {
            return Self(callerAttempt: nil, maximumTotalAttempts: 1, deadlineUnixMilliseconds: nil)
        }
        guard headers[names[0]] == "caller",
            let attemptText = headers[names[1]], let attempt = Int(attemptText), String(attempt) == attemptText,
            let maximumText = headers[names[2]], let maximum = Int(maximumText), String(maximum) == maximumText,
            (1...3).contains(maximum), (1...maximum).contains(attempt),
            let deadlineText = headers[names[3]], let deadline = Int64(deadlineText),
            String(deadline) == deadlineText, deadline > 0
        else { throw InvalidHeaders() }
        return Self(callerAttempt: attempt, maximumTotalAttempts: maximum, deadlineUnixMilliseconds: deadline)
    }

    var remainingMilliseconds: Int64? {
        deadlineUnixMilliseconds.map { $0 - Int64(Date().timeIntervalSince1970 * 1000) }
    }

    var expired: Bool { remainingMilliseconds.map { $0 <= 0 } ?? false }

    func receipt(_ failure: ImagePullFailure, attempts: Int) -> ImagePullFailure {
        var result = failure
        result.budgetOwner = callerAttempt == nil ? "micropod" : "caller"
        result.attempts = attempts
        result.callerAttempt = callerAttempt
        result.maximumTotalAttempts = maximumTotalAttempts
        result.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        result.retryBudgetExhausted = callerAttempt.map { $0 >= maximumTotalAttempts } ?? true
        return result
    }

    func terminalError(_ error: Error, attempts: Int) -> Error {
        var failure = ImagePullFailure.from(error) ?? ImagePullFailure()
        if case MicropodError.pullStalled = error { failure.category = .stalled }
        if case MicropodError.message(let detail) = error, detail.hasPrefix("image_pull_v1 "),
            let decoded = try? JSONDecoder().decode(
                ImagePullFailure.self, from: Data(detail.dropFirst("image_pull_v1 ".count).utf8))
        {
            failure = decoded
        }
        failure = receipt(failure, attempts: attempts)
        if case MicropodError.cliFailure(_, let exitCode, _) = error {
            return MicropodError.cliFailure(
                command: "container image pull", exitCode: exitCode, stderr: failure.message)
        }
        return MicropodError.message(failure.message)
    }

    func deadlineError(attempts: Int) -> Error {
        MicropodError.message(receipt(ImagePullFailure(category: .deadline), attempts: attempts).message)
    }
}
