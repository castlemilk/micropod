import CPublishedTCP
import Foundation

// The project logging sink and CLI mode range are the only project dependencies of
// NativeLoopbackRelay used by this fixture. The production relay compiles unchanged.
enum SecretSource { static func stderrLog(_ message: String) { print(message) } }
enum CIWorkerPortRelay { static let parallelWorkers = 1...4 }

@main
struct HandoffProfileFixture {
    static func main() throws {
        for (workers, profile) in [(2, false), (2, true), (0, true)] {
            let relay = try NativeLoopbackRelay(guest: "127.0.0.1", dataWorkers: workers, profile: profile)
            let port = try relay.bind(host: UInt16(4000 + (profile ? workers : 1)), guest: 8080)
            fixture_submit(Int32(workers))
            relay.release(port)
            let clocks = fixture_finish()
            print("clock \(workers) \(profile) \(clocks)")
            relay.stop()
        }
    }
}
