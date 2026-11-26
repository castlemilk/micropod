import Foundation
import Network

/// Whether a request lets the server keep its connection for the next one
/// (RFC 9112 §9.3). HTTP/1.1 persists unless the client sends
/// `Connection: close`; HTTP/1.0 persists only when it asks with
/// `Connection: keep-alive`, and then the reply has to say so too.
enum HTTPPersistence: Sendable, Equatable {
    case persistent
    /// HTTP/1.0 with `Connection: keep-alive`: kept only when the reply
    /// carries `Connection: keep-alive`.
    case announced
    case close

    init(version: String, connection: String?) {
        let tokens = Set(
            (connection ?? "").lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
        if tokens.contains("close") {
            self = .close
        } else if version == "HTTP/1.0" {
            self = tokens.contains("keep-alive") ? .announced : .close
        } else {
            self = .persistent
        }
    }
}

extension HTTPServer {
    /// How long a connection may sit in each phase, and how many may stay
    /// open between requests.
    ///
    /// Within a request, the head and body have to finish arriving within
    /// `requestDeadline`, with no silence longer than `requestIdle`: a stuck
    /// or malicious client gets 408 instead of holding the connection. On a
    /// new connection both clocks start at accept, so a client that never
    /// sends a byte gets 408 too. On a kept connection they start at the
    /// first byte of the next request; until then `keepAliveIdle` applies,
    /// and when it runs out the connection is closed without a reply (a 408
    /// on an idle connection is a response nobody asked for: Go's client
    /// logs it as "Unsolicited response received on idle HTTP channel").
    /// Its default, 120 s, is longer than Go's 90 s `IdleConnTimeout`, so a
    /// Go client drops an idle connection before the server does and never
    /// reuses one the server is closing.
    struct ConnectionPolicy: Sendable {
        var requestIdle: DispatchTimeInterval
        var requestDeadline: DispatchTimeInterval
        var keepAliveIdle: DispatchTimeInterval
        /// Connections the server keeps open for another request at once;
        /// past it a reply says `Connection: close`. Each is an open file
        /// descriptor; a request in flight on one counts until it is
        /// answered.
        var maxKeptConnections: Int

        /// Milliseconds from `MICROPOD_API_READ_IDLE_TIMEOUT_MS` (30 s),
        /// `MICROPOD_API_READ_DEADLINE_MS` (120 s) and
        /// `MICROPOD_API_KEEPALIVE_IDLE_MS` (120 s), so tests need not wait.
        init(environment: [String: String]) {
            func milliseconds(_ key: String, _ fallback: Int) -> DispatchTimeInterval {
                .milliseconds(max(1, environment[key].flatMap { Int($0) } ?? fallback))
            }
            requestIdle = milliseconds("MICROPOD_API_READ_IDLE_TIMEOUT_MS", 30_000)
            requestDeadline = milliseconds("MICROPOD_API_READ_DEADLINE_MS", 120_000)
            keepAliveIdle = milliseconds("MICROPOD_API_KEEPALIVE_IDLE_MS", 120_000)
            maxKeptConnections = 256
        }

        init(
            requestIdle: DispatchTimeInterval, requestDeadline: DispatchTimeInterval,
            keepAliveIdle: DispatchTimeInterval, maxKeptConnections: Int
        ) {
            self.requestIdle = requestIdle
            self.requestDeadline = requestDeadline
            self.keepAliveIdle = keepAliveIdle
            self.maxKeptConnections = maxKeptConnections
        }

        static let live = ConnectionPolicy(environment: ProcessInfo.processInfo.environment)
    }

    /// The connections a server has promised to keep for another request:
    /// from the reply that leaves them open until the next request's first
    /// byte (or their close). Bounded by `limit`; once the server stops it
    /// promises nothing more and closes the ones waiting idle.
    final class KeptConnections: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var held: [ObjectIdentifier: (connection: NWConnection, idle: Bool)] = [:]
        private var stopping = false

        init(limit: Int) { self.limit = max(0, limit) }

        /// Holds a place for `connection` before its reply goes out; false
        /// at the limit or once the server stops (the reply then closes).
        func reserve(_ connection: NWConnection) -> Bool {
            lock.withLock {
                guard !stopping, held.count < limit else { return false }
                held[ObjectIdentifier(connection)] = (connection, false)
                return true
            }
        }

        /// The reply went out and nothing of the next request is buffered:
        /// `connection` now waits idle. False once the server stops (the
        /// caller closes it; its place is released).
        func park(_ connection: NWConnection) -> Bool {
            lock.withLock {
                let key = ObjectIdentifier(connection)
                guard !stopping, held[key] != nil else {
                    held.removeValue(forKey: key)
                    return false
                }
                held[key]?.idle = true
                return true
            }
        }

        /// `connection` left its kept state: the next request began, or it
        /// closed. Idempotent.
        func release(_ connection: NWConnection) {
            lock.withLock { _ = held.removeValue(forKey: ObjectIdentifier(connection)) }
        }

        var count: Int { lock.withLock { held.count } }

        /// Promises nothing more and returns the idle connections, which the
        /// caller closes; one with a request in flight closes after its reply.
        func stop() -> [NWConnection] {
            lock.withLock {
                stopping = true
                let idle = held.filter { $0.value.idle }
                for key in idle.keys { held.removeValue(forKey: key) }
                return idle.values.map(\.connection)
            }
        }
    }
}
