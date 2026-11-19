import Foundation
import Network
import Synchronization

/// Ends a unary request's handler with its client.
///
/// A client that gave up used to leave its handler running to the end. On
/// Gamma-128 (2026-11-19), creates the agent abandoned at its 60 s deadline
/// reached `containerCreate` one to seven minutes later, and helpers the
/// agent had already deleted (`not_found`) booted seconds after: work for
/// attempts that had already failed, queued ahead of the ones that had not,
/// each leaving an uncertain admission receipt behind.
///
/// Now the handler runs as its own task, and that task is cancelled
///
///  - when the client closes its side of the connection (every request has a
///    connection of its own: the server closes it after one response), and
///  - when `Connect-Timeout-Ms` passes; the answer is then
///    `deadline_exceeded`.
///
/// Cancellation stops what has not reached the runtime yet: an XPC send
/// checks it before sending, starts and deletes wait under
/// `NativeLifecycleOperations` (queued cancellation prevents dispatch), and a
/// create checks it before `containerCreate`. Those settle their admission
/// receipts as definitive failures. Work already sent runs to its end, as
/// before, and keeps its receipt until the runtime answers.
///
/// Only unary calls qualify (``applies(_:)``): a streamed, bridged or relayed
/// response reads or watches the connection itself after the handler
/// returns. `MICROPOD_CANCEL_ON_HANGUP=off` restores the old behaviour.
enum UnaryCancellation {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MICROPOD_CANCEL_ON_HANGUP"] != "off"
    }

    /// `POST /api/micropod.v1.*` with a unary body (`application/json` or
    /// `application/proto`), not a server-streaming one
    /// (`application/connect+…`).
    static func applies(_ request: HTTPRequest) -> Bool {
        guard enabled, request.method == .post, request.path.hasPrefix("/api/micropod.v1.") else { return false }
        return !(request.headers["content-type"] ?? "").lowercased().hasPrefix("application/connect+")
    }

    /// The Connect deadline: `Connect-Timeout-Ms`, one to ten ASCII digits.
    /// Anything else is ignored, as if absent.
    static func deadline(of request: HTTPRequest) -> Duration? {
        guard let raw = request.headers["connect-timeout-ms"]?.trimmingCharacters(in: .whitespaces),
            (1...10).contains(raw.count), raw.allSatisfy({ $0.isASCII && $0.isNumber }), let ms = Int64(raw)
        else { return nil }
        return .milliseconds(ms)
    }

    /// Why the handler's task ended early, if it did. The first to happen
    /// wins; once the handler has answered nothing else counts (the server's
    /// own close after the response looks like a hangup to the watch).
    enum Ending: Equatable, Sendable {
        case answered, hungUp, expired
    }

    final class Outcome: Sendable {
        private let state = Mutex<Ending?>(nil)
        /// Records `ending` if nothing has; true when it was the first.
        @discardableResult
        func mark(_ ending: Ending) -> Bool {
            state.withLock { current in
                guard current == nil else { return false }
                current = ending
                return true
            }
        }
        var ending: Ending? { state.withLock { $0 } }
    }

    /// `HTTPResponse` carries `[String: Any]` bodies, so it is not Sendable;
    /// each one is handed over once, to the one awaiting it.
    struct Handed: @unchecked Sendable {
        let response: HTTPResponse
    }

    /// What ``run(_:on:server:watch:outcome:)`` answers with.
    struct Answer: Sendable {
        let handed: Handed
        /// Set when the deadline answered before the handler did: the
        /// handler's task is cancelled but still running, and `finished`
        /// ends when it does — the request's admission claim covers it
        /// until then.
        let early: Bool
        let finished: Task<Void, Never>
        var response: HTTPResponse { handed.response }
    }

    static var deadlineExceeded: HTTPResponse {
        .data(
            ConnectWireCode.deadlineExceeded.httpStatus, "application/json",
            Data(
                #"{"code":"deadline_exceeded","message":"the request's Connect-Timeout-Ms passed before it was answered"}"#
                    .utf8))
    }

    /// Runs `server.handler(request)` under the hangup watch and the Connect
    /// deadline. At the deadline the answer is `deadline_exceeded` at once,
    /// whether or not the handler has noticed its cancellation yet (it may be
    /// waiting on something that does not observe it). `watch` and `outcome`
    /// are seams for tests.
    static func run(
        _ request: HTTPRequest, on connection: NWConnection, server: HTTPServer,
        watch: (NWConnection, @escaping @Sendable () -> Void) -> Void = HTTPServer.watchForHangup,
        outcome: Outcome = Outcome()
    ) async -> Answer {
        let work = Task { Handed(response: await server.handler(request)) }
        let finished = Task { _ = await work.value }
        watch(connection) {
            if outcome.mark(.hungUp) { work.cancel() }
        }
        let limit = deadline(of: request)
        return await withCheckedContinuation { (answered: CheckedContinuation<Answer, Never>) in
            let once = Once(answered)
            Task {
                let handed = await work.value
                outcome.mark(.answered)
                once.resume(Answer(handed: handed, early: false, finished: finished))
            }
            if let limit {
                Task {
                    try? await Task.sleep(for: limit)
                    guard outcome.mark(.expired) else { return }
                    work.cancel()
                    once.resume(Answer(handed: Handed(response: deadlineExceeded), early: true, finished: finished))
                }
            }
        }
    }

    /// Resumes a continuation exactly once: the first of the handler's
    /// answer and the deadline.
    private final class Once: Sendable {
        private let continuation: Mutex<CheckedContinuation<Answer, Never>?>
        init(_ continuation: CheckedContinuation<Answer, Never>) { self.continuation = Mutex(continuation) }
        func resume(_ answer: Answer) {
            let pending = continuation.withLock { value -> CheckedContinuation<Answer, Never>? in
                defer { value = nil }
                return value
            }
            pending?.resume(returning: answer)
        }
    }
}
