import CPublishedTCP
import Foundation

enum SecretSource { static func stderrLog(_ message: String) { print(message) } }
enum CIWorkerPortRelay { static let parallelWorkers = 1...4 }

@main
struct GuestReadProfileFixture {
    static func main() throws {
        for (port, workers, profile) in [(4001, 2, false), (4002, 2, true), (4000, 0, true)] {
            let relay = try NativeLoopbackRelay(guest: "127.0.0.1", dataWorkers: workers, profile: profile)
            let bound = try relay.bind(host: UInt16(port), guest: 8080)
            relay.release(bound)
            relay.stop()
        }
    }
}
