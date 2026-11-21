import Foundation

// Compile with Sources/MicropodSharedFS/*.swift. Measure the cache bind phase of a container start.
@main
struct CacheBindBench {
    enum Failure: Error { case invalidArguments, wrongView, unexpectedMounts }
    struct Batch: Encodable {
        let round: Int
        let clients: Int
        let mode: String
        let seconds: Double
    }
    struct Receipt: Encodable {
        let transport: String
        let sources: [String]
        let build: String
        let rounds: Int
        let batches: [Batch]
        let passed: Bool
    }

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5, ["direct", "unix"].contains(args[0]), let rounds = Int(args[4]), rounds > 0 else {
            throw Failure.invalidArguments
        }
        let root = URL(fileURLWithPath: args[1])
        let sources = ["npm-cache", "go-mod-cache", "go-build-cache"].map { root.appendingPathComponent($0) }
        let daemon = try SharedFSDaemon(cacheRoot: URL(fileURLWithPath: args[2]))
        let socket = (args[2] as NSString).appendingPathComponent("s")
        let server = SharedFSServer(socketPath: socket, daemon: daemon)
        if args[0] == "unix" { try server.start() }
        defer { if args[0] == "unix" { server.stop() } }
        let client: any SharedFSClient = args[0] == "unix" ? UnixSocketClient(socketPath: socket) : daemon
        var pins: [MountInfo] = []
        for source in sources {
            let pin = try await client.mountShared(src: source, readonly: false)
            guard pin.sizeBytes > 0 else { throw Failure.wrongView }
            pins.append(pin)
        }
        let expected = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0.viewPath) })
        guard expected.count == sources.count else { throw Failure.wrongView }
        let levels = [1, 4, 8, 16]
        var samples: [Batch] = []
        for block in 0..<rounds {
            for offset in levels.indices {
                let n = levels[(block + offset) % levels.count]
                for detailed in (block + offset).isMultiple(of: 2) ? [true, false] : [false, true] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let leases = try await withThrowingTaskGroup(of: [SharedBind].self) { group in
                        for _ in 0..<n {
                            group.addTask {
                                var acquired: [SharedBind] = []
                                for source in sources {
                                    if detailed {
                                        acquired.append(try await client.mountShared(src: source, readonly: false).bind)
                                    } else {
                                        acquired.append(try await client.bindShared(src: source, readonly: false))
                                    }
                                }
                                return acquired
                            }
                        }
                        var result: [[SharedBind]] = []
                        for try await mounts in group { result.append(mounts) }
                        return result
                    }
                    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
                    for job in leases {
                        guard Set(job.map(\.id)) == Set(expected.keys) else { throw Failure.wrongView }
                        for bind in job {
                            guard expected[bind.id] == bind.viewPath else { throw Failure.wrongView }
                            try await client.unmount(id: bind.id)
                        }
                    }
                    samples.append(
                        Batch(round: block + 1, clients: n, mode: detailed ? "size-and-bind" : "bind", seconds: seconds)
                    )
                }
            }
        }
        guard Set(try await client.list().map(\.id)) == Set(expected.keys) else { throw Failure.unexpectedMounts }
        for pin in pins { try await client.unmount(id: pin.id) }
        guard try await client.list().isEmpty else { throw Failure.unexpectedMounts }
        let receipt = Receipt(
            transport: args[0], sources: sources.map(\.lastPathComponent),
            build: "optimized", rounds: rounds, batches: samples, passed: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: URL(fileURLWithPath: args[3]))
    }
}
