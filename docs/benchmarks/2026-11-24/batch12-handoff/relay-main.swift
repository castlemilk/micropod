import CPublishedTCP
import Darwin
import Foundation

enum SecretSource {
    static func stderrLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
enum CIWorkerPortRelay { static let parallelWorkers = 1...4 }

@main struct Driver {
    static func main() throws {
        guard let arg = CommandLine.arguments.dropFirst().first, let port = UInt16(arg) else { throw POSIXError(.EINVAL) }
        let relay = try NativeLoopbackRelay(guest: "127.0.0.1", dataWorkers: 2, profile: false)
        let published = try relay.bind(host: 0, guest: port)
        let info = ["port": Int(published), "guest_port": Int(port), "workers": relay.dataWorkerCount,
                    "read_bytes": relay.readBytes ?? -1, "callback_events": relay.dataCallbackEvents ?? -1]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        _ = readLine()
        relay.release(published)
        relay.stop()
    }
}
