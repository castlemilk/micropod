import Darwin
import Foundation
import MicropodCore

enum DockerTCPConnection {
    struct Address: Sendable {
        let value: sockaddr_storage
        let length: socklen_t

        var family: Int32 { Int32(value.ss_family) }
    }

    typealias Resolver = @Sendable (String, UInt16) throws -> [Address]

    // Some system resolver calls outlive the caller's deadline. Reserve a slot
    // before dispatching, so concurrent timeouts cannot stockpile background work.
    private static let resolverSlots = DispatchSemaphore(value: 4)
    private static let resolverQueue = DispatchQueue(
        label: "com.micropod.docker.resolver", qos: .utility, attributes: .concurrent)

    static func connect(host: String, port: UInt16, timeout: Duration, cancellation: SocketBox?) throws -> Int32 {
        try connect(host: host, port: port, timeout: timeout, cancellation: cancellation) { host, port in
            try lookup(host: host, port: port, numericOnly: false)
        }
    }

    static func connect(
        host: String, port: UInt16, timeout: Duration, cancellation: SocketBox?, resolve: @escaping Resolver
    ) throws -> Int32 {
        let name = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw MicropodError.message("invalidArgument: docker: invalid TCP hostname")
        }
        let endpoint = name.contains(":") ? "[\(name)]:\(port)" : "\(name):\(port)"
        let budget = Budget(deadline: .now + timeout, endpoint: endpoint, cancellation: cancellation)
        try budget.check()
        let numeric = try lookup(host: name, port: port, numericOnly: true)
        let addresses = try numeric.isEmpty ? resolveHost(name, port: port, budget: budget, resolve: resolve) : numeric
        let ordered = alternateFamilies(addresses)

        var lastError = POSIXError(.EHOSTUNREACH)
        for (index, address) in ordered.enumerated() {
            try budget.check()
            let now = ContinuousClock.now
            let remaining = budget.deadline - now
            let candidates = ordered.count - index
            // Leave room for other addresses when an earlier connection stalls.
            let attemptDeadline = candidates == 1
                ? budget.deadline
                : now + min(.milliseconds(250), remaining / candidates)

            do {
                return try connect(address, budget: budget, attemptDeadline: attemptDeadline)
            } catch let error as POSIXError {
                lastError = error
            }
        }
        try budget.check()
        throw MicropodError.message("unavailable: docker: connect \(endpoint): \(lastError.localizedDescription)")
    }

    private struct Budget {
        let deadline: ContinuousClock.Instant
        let endpoint: String
        let cancellation: SocketBox?

        func check() throws {
            try cancellation?.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw MicropodError.message("deadlineExceeded: docker: connect \(endpoint) timed out")
            }
        }

        func waitMilliseconds(until end: ContinuousClock.Instant) throws -> Int32 {
            try check()
            let remaining = end - .now
            guard remaining > .zero else { return 0 }
            // Round the final sub-millisecond interval up without creating a spin loop.
            let attoseconds = min(.milliseconds(20), remaining).components.attoseconds
            return Int32((attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
        }

        func wait(for semaphore: DispatchSemaphore) throws {
            while true {
                let milliseconds = try waitMilliseconds(until: deadline)
                if semaphore.wait(timeout: .now() + .milliseconds(Int(milliseconds))) == .success { return }
            }
        }
    }

    private final class Resolution: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Result<[Address], Error>?

        func finish(_ result: Result<[Address], Error>) {
            lock.withLock { value = result }
            ready.signal()
        }

        func result() throws -> [Address] {
            guard let result = lock.withLock({ value }) else {
                throw MicropodError.message("internal: docker: hostname lookup returned no result")
            }
            return try result.get()
        }
    }

    private static func resolveHost(
        _ host: String, port: UInt16, budget: Budget, resolve: @escaping Resolver
    ) throws -> [Address] {
        try budget.wait(for: resolverSlots)
        do {
            try budget.check()
        } catch {
            resolverSlots.signal()
            throw error
        }
        let job = Resolution()
        resolverQueue.async {
            defer { resolverSlots.signal() }
            guard ContinuousClock.now < budget.deadline, budget.cancellation?.cancelled != true else {
                job.finish(.failure(CancellationError()))
                return
            }
            job.finish(Result { try resolve(host, port) })
        }
        try budget.wait(for: job.ready)
        try budget.check()
        return try job.result()
    }

    private static func lookup(host: String, port: UInt16, numericOnly: Bool) throws -> [Address] {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV | (numericOnly ? AI_NUMERICHOST : 0),
            ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?
        let error = getaddrinfo(host, String(port), &hints, &head)
        guard error == 0, let head else {
            if numericOnly { return [] }
            throw MicropodError.message("unavailable: docker: resolve \(host): \(String(cString: gai_strerror(error)))")
        }
        defer { freeaddrinfo(head) }

        var addresses: [Address] = []
        var current: UnsafeMutablePointer<addrinfo>? = head
        while let node = current {
            let address = node.pointee
            current = address.ai_next
            let length: Int
            switch address.ai_family {
            case AF_INET: length = MemoryLayout<sockaddr_in>.size
            case AF_INET6: length = MemoryLayout<sockaddr_in6>.size
            default: continue
            }
            guard Int(address.ai_addrlen) == length, let raw = address.ai_addr else { continue }
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { target in
                target.copyBytes(from: UnsafeRawBufferPointer(start: raw, count: length))
            }
            addresses.append(Address(value: storage, length: address.ai_addrlen))
        }
        return addresses
    }

    private static func alternateFamilies(_ addresses: [Address]) -> [Address] {
        guard let first = addresses.first else { return [] }
        let preferred = addresses.filter { $0.family == first.family }
        let other = addresses.filter { $0.family != first.family }
        var result: [Address] = []
        result.reserveCapacity(addresses.count)
        for i in preferred.indices {
            result.append(preferred[i])
            if i < other.count { result.append(other[i]) }
        }
        result.append(contentsOf: other.dropFirst(preferred.count))
        return result
    }

    private static func connect(_ address: Address, budget: Budget, attemptDeadline: ContinuousClock.Instant) throws
        -> Int32
    {
        let fd = Darwin.socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw posixError() }
        var connected = false
        defer { if !connected { Darwin.close(fd) } }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw posixError()
        }

        var storage = address.value
        var result: Int32
        repeat {
            try budget.check()
            result = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, address.length) }
            }
        } while result < 0 && errno == EINTR
        if result != 0 && errno != EISCONN {
            guard errno == EINPROGRESS || errno == EALREADY else { throw posixError() }
            try waitForConnect(fd, budget: budget, attemptDeadline: attemptDeadline)
        }

        guard fcntl(fd, F_SETFL, flags) == 0 else { throw posixError() }
        try budget.check()
        connected = true
        return fd
    }

    private static func waitForConnect(_ fd: Int32, budget: Budget, attemptDeadline: ContinuousClock.Instant) throws {
        var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        while true {
            let wait = try budget.waitMilliseconds(until: attemptDeadline)
            guard wait > 0 else { throw POSIXError(.ETIMEDOUT) }
            let result = Darwin.poll(&pending, 1, wait)
            if result < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if result == 0 { continue }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw posixError() }
            if error != 0 { throw posixError(error) }
            return
        }
    }

    private static func posixError(_ error: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }
}
