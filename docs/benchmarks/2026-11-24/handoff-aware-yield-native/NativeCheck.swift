// Appended to the isolated NativeLoopbackRelay.swift so the checks can use its real queues and targets.
import Darwin

enum SecretSource { static func stderrLog(_ message: String) { print(message) } }
enum CIWorkerPortRelay { static let parallelWorkers = 1...4 }

extension NativeLoopbackRelay {
    fileprivate func checkHandoffs() throws -> [String: Any] {
        let first = workers[0], second = workers[1]
        let parent = fixture_parent(accept.backend.handle, 1)!
        let target = try Target(owner: first, parent: parent)
        let other = try Target(owner: second, parent: parent)
        let startFirst = DispatchSemaphore(value: 0)
        let between = DispatchSemaphore(value: 0)
        let resumeFirst = DispatchSemaphore(value: 0)
        let startSecond = DispatchSemaphore(value: 0)
        first.queue.async { startFirst.wait() }
        second.queue.async { startSecond.wait() }

        // Invalid descriptors exercise both adoption closures and their normal early error exit before dial.
        let accepted = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        target.adopt(-1, accepted: accepted)
        first.queue.async {
            between.signal()
            resumeFirst.wait()
        }
        target.adoptProfiled(-1, accepted: accepted)
        other.adopt(-1, accepted: accepted)
        func pending() -> [UInt32] {
            [fixture_pending(first.backend.handle), fixture_pending(second.backend.handle)]
        }
        var observed = [pending()]
        precondition(observed[0] == [2, 1])
        startFirst.signal()
        precondition(between.wait(timeout: .now() + .seconds(5)) == .success)
        observed.append(pending())
        precondition(observed[1] == [1, 1])
        resumeFirst.signal()
        first.queue.sync {}
        observed.append(pending())
        precondition(observed[2] == [0, 1])
        startSecond.signal()
        second.queue.sync {}
        observed.append(pending())
        precondition(observed[3] == [0, 0])
        _ = target.release(profile: true)
        _ = other.release(profile: true)
        var stats = mp_tcp_stats()
        mp_tcp_release(parent, &stats)
        let profiled = withUnsafeBytes(of: stats.handoff.accept_to_adopt_us) {
            $0.bindMemory(to: UInt64.self).reduce(0, +)
        }
        precondition(stats.accepted == 3 && stats.connect_errors == 3 && profiled == 1)
        return ["pending_counts": observed, "adopted": stats.accepted, "profiled_handoffs": profiled]
    }

    fileprivate func checkDispatchSource() throws -> [String: Any] {
        let owner = workers[0]
        let parent = fixture_parent(accept.backend.handle, 1)!
        let target = try Target(owner: owner, parent: parent)
        // A persistent test signal forces every productive drain to yield after its first poll.
        // Only the real dispatch source invokes drain throughout this test.
        let receiver = owner.queue.sync {
            mp_tcp_handoff_enqueued(owner.backend.handle)
            return fixture_stage_bulk(target.handle)
        }
        precondition(receiver >= 0)
        defer { _ = close(receiver) }
        let offered = 768 * 1024
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var received = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(receiver, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            precondition(n >= 0, "relay source stopped delivering before FIN")
            if n == 0 { break }
            precondition(buffer.prefix(n).allSatisfy { $0 == 0x5a })
            received += n
            precondition(received <= offered)
        }
        let (callbacks, largest) = owner.queue.sync {
            precondition(fixture_pending(owner.backend.handle) == 1)
            let counts = (fixture_productive_callbacks(owner.backend.handle),
                          fixture_largest_callback_bytes(owner.backend.handle))
            fixture_finish_bulk(target.handle)
            mp_tcp_handoff_started(owner.backend.handle)
            return counts
        }
        precondition(received == offered && callbacks >= 3 && largest > 0 && largest <= 256 * 1024)
        _ = target.release(profile: true)
        mp_tcp_release(parent, nil)
        return ["received_bytes": received, "eof": true, "productive_callbacks": callbacks,
                "largest_callback_bytes": largest]
    }
}

@main
struct NativeCheck {
    static func main() throws {
        alarm(15)
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1", dataWorkers: 2, profile: true)
        defer { relay.stop() }
        precondition(relay.dataCallbackEvents == 128 && relay.readBytes == 256 * 1024)
        let report: [String: Any] = ["handoffs": try relay.checkHandoffs(),
                                     "automatic_drain": try relay.checkDispatchSource(),
                                     "callback_events": 128, "read_bytes": 256 * 1024]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
