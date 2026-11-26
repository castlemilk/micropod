import Foundation
import Dispatch

// Both arms use the serial queue construction and synchronous startup handoff
// of Containerization 0.42.0. No VZ instance or framework completion is created.
final class Attempt: @unchecked Sendable {
    let candidate: Bool
    let number: Int
    let requested: UInt32
    var checks = [String: [String: Int]]()
    init(candidate: Bool, number: Int, requested: UInt32) {
        self.candidate = candidate
        self.number = number
        self.requested = requested
    }
    func run() {
        let label = "com.apple.containerization.vzvm.\(UUID().uuidString)"
        let q = candidate ? DispatchQueue(label: label, qos: .userInitiated) : DispatchQueue(label: label)
        let key = DispatchSpecificKey<Int>()
        q.setSpecific(key: key, value: number)
        let caller = observe_thread()
        precondition(caller.qos == requested)
        func sample(_ name: String) {
            precondition(DispatchQueue.getSpecific(key: key) == number)
            let t = observe_thread()
            checks[name] = ["qos": Int(t.qos), "base": Int(t.base), "current": Int(t.current),
                            "sameThreadAsSubmitter": t.tid == caller.tid ? 1 : 0]
        }
        q.sync { sample("sync") }
        let complete = DispatchSemaphore(value: 0)
        q.async {
            sample("async")
            complete.signal()
        }
        complete.wait()
        checks["before"] = ["qos": Int(caller.qos), "base": Int(caller.base), "current": Int(caller.current)]
        let after = observe_thread()
        checks["after"] = ["qos": Int(after.qos), "base": Int(after.base), "current": Int(after.current)]
    }
}

for (number, entry) in CommandLine.arguments.dropFirst().enumerated() {
    let values = entry.split(separator: ",")
    let pair = Int(values[0])!
    let candidate = values[1] == "explicit"
    let qos = UInt32(values[2])!
    let attempt = Attempt(candidate: candidate, number: number, requested: qos)
    run_on_pthread(qos, { raw in
        Unmanaged<Attempt>.fromOpaque(raw!).takeUnretainedValue().run()
    }, Unmanaged.passUnretained(attempt).toOpaque())
    let record: [String: Any] = ["pair": pair, "arm": String(values[1]), "callerQos": qos,
                                  "states": attempt.checks]
    let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
}
