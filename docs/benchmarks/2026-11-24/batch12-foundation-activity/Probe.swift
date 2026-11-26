import CPublishedTCP
import Foundation

enum SecretSource {
    static func stderrLog(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}

enum CIWorkerPortRelay { static let parallelWorkers = 1...4 }

enum Evidence {
    static func record(_ fields: [String: Any]) {
        var event = fields
        event["uptime_ns"] = DispatchTime.now().uptimeNanoseconds
        event["pid"] = getpid()
        let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        FileHandle.standardError.write(data + Data([10]))
    }
}

// accept.queue serializes all first/last listener transitions in NativeLoopbackRelay.
final class ListenerActivity {
    private var token: (any NSObjectProtocol)?
    private let enabled = CommandLine.arguments[3] == "on"
    private let options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]

    func firstListener() {
        precondition(token == nil)
        if enabled {
            token = ProcessInfo.processInfo.beginActivity(options: options, reason: "Micropod active published TCP listener")
        }
        Evidence.record(["event": "first_listener", "held": token != nil, "options": options.rawValue,
                         "token": token.map { String(describing: ObjectIdentifier($0)) } ?? "none"])
    }

    func lastListener() {
        precondition((token != nil) == enabled)
        let identity = token.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        if let token { ProcessInfo.processInfo.endActivity(token) }
        token = nil
        Evidence.record(["event": "last_listener", "ended": enabled, "held": token != nil, "token": identity])
    }
}

@main
struct Probe {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "127.0.0.1", let guest = UInt16(args[2]),
              ["on","off"].contains(args[3]) else { throw POSIXError(.EINVAL) }
        let relay = try NativeLoopbackRelay(guest: args[1], dataWorkers: 2)
        guard relay.dataWorkerCount == 2, relay.dataCallbackEvents == 128, relay.readBytes == 262144 else {
            throw POSIXError(.EINVAL)
        }
        let port = try relay.bind(host: 0, guest: guest)
        relay.captureOwnerQoS("held_before")
        FileHandle.standardOutput.write(Data(("127.0.0.1:" + String(port) + "\n").utf8))
        guard readLine() == "release" else { throw POSIXError(.ECANCELED) }
        relay.captureOwnerQoS("held_after")
        relay.release(port)
        guard relay.hasReleased(guest: guest) else { throw POSIXError(.EBUSY) }
        Evidence.record(["event": "lease_released", "port": port])
    }
}
