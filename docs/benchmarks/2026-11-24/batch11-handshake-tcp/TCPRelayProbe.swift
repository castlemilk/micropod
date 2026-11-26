import CPublishedTCP
import Foundation

enum SecretSource {
    static func stderrLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
enum CIWorkerPortRelay { static let parallelWorkers = 1...4 }

@main
struct TCPRelayProbe {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "127.0.0.1", let guestPort = UInt16(args[2]) else {
            throw POSIXError(.EINVAL)
        }
        let relay = try NativeLoopbackRelay(guest: args[1], dataWorkers: 2)
        guard relay.dataWorkerCount == 2, relay.dataCallbackEvents == 128, relay.readBytes == 262144 else {
            throw POSIXError(.EINVAL)
        }
        let port = try relay.bind(host: 0, guest: guestPort)
        FileHandle.standardOutput.write(Data(("127.0.0.1:" + String(port) + "\n").utf8))
        withExtendedLifetime(relay) { dispatchMain() }
    }
}
