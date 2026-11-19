import Darwin
import Foundation
import MicropodCore
import MicropodRuntime

enum CICommands {
    static let help = """
        micropod ci start                 start or join this account's Linux worker
        micropod ci endpoint              ensure readiness and print the Docker socket URI
        micropod ci status                print worker, kernel boot and daemon identities as JSON
        micropod ci run [options] IMAGE   run a fresh container on the worker (docker run --rm)
        micropod ci stop                  stop the idle worker and retain its disk and caches
        micropod ci serve                 supervise the worker in the foreground
        """

    static func main(_ args: [String]) async -> Int32 {
        let worker = CIWorker()
        guard let command = args.first else {
            print(help)
            return 2
        }
        if ["--help", "-h", "help"].contains(command) {
            print(help)
            return 0
        }
        guard command == "run" || args.count == 1 else {
            print(help)
            return 2
        }
        do {
            switch command {
            case "serve": return try await worker.serve()
            case "stop": try await worker.stop()
            case "status": try printStatus(await worker.status())
            case "start", "endpoint", "run":
                guard let executable = Bundle.main.executableURL else {
                    throw MicropodError.message("Cannot locate micropod executable")
                }
                guard command != "run" || args.count > 1 else {
                    print(help)
                    return 2
                }
                let current = try await worker.start(executable: executable)
                if command == "run" {
                    // Replace the CLI so job streams, signals and exit status belong to Docker.
                    let arguments = ["docker", "--host", current.endpoint, "run", "--rm"] + args.dropFirst()
                    let argv = arguments.map { strdup($0) } + [nil]
                    defer { argv.forEach { free($0) } }
                    _ = execvp("docker", argv)
                    throw MicropodError.message("Cannot execute docker: \(String(cString: strerror(errno)))")
                }
                if command == "endpoint" { print(current.endpoint) } else { try printStatus(current) }
            default:
                print(help)
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data(("micropod ci: " + error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private static func printStatus(_ status: CIWorker.Status) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    }
}
