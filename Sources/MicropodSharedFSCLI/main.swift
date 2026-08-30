import Foundation
import MicropodSharedFS

// `micropod-sharedfs` entry point. In main.swift the top-level code IS the
// entry point — no @main needed, no struct wrapper. macOS-only: the daemon
// uses FSEvents and materialization uses the Apple `container` runtime.

#if canImport(CoreServices)

    let environment = ProcessInfo.processInfo.environment
    let cacheRoot =
        environment["MICROPOD_SHAREDFS_CACHE"]
        ?? NSString("~/micropod/share-cache").expandingTildeInPath

    func usage() -> Never {
        fputs(
            """
            usage: micropod-sharedfs <command>

              daemon                     run the shared-view daemon (default)
              sync --src <dir> --volume <name> [options]
                                         mirror a host directory into a block volume,
                                         shipping only what changed since the last sync
              invalidate --src <dir> --volume <name> [--dest <path>]
                                         forget the history so the next sync ships everything

            sync options:
              --dest <path>      path inside the volume (default "/")
              --always-hash      hash every file instead of trusting size+mtime
              --exclude <name>   repeatable; adds to the default exclude set
              --cli <path>       container CLI (default /usr/local/bin/container)
              --image <ref>      helper image (default alpine:3.20)
              --json             emit stats as JSON

            env:
              MICROPOD_SHAREDFS_CACHE   cache/manifest root (default ~/micropod/share-cache)
              MICROPOD_SHAREDFS_SOCKET  daemon socket path

            """, stderr)
        exit(2)
    }

    func flagValue(_ name: String, _ args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func flagValues(_ name: String, _ args: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == name, index + 1 < args.count {
                values.append(args[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return values
    }

    func runDaemon() -> Never {
        let socketPath =
            environment["MICROPOD_SHAREDFS_SOCKET"]
            ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: cacheRoot), withIntermediateDirectories: true)
            let daemon = try SharedFSDaemon(cacheRoot: URL(fileURLWithPath: cacheRoot))
            let server = SharedFSServer(socketPath: socketPath, daemon: daemon)
            try server.start()
            fputs("[sharedfs] listening at \(socketPath)\n", stderr)

            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let stop: @Sendable () -> Void = {
                fputs("[sharedfs] shutting down\n", stderr)
                server.stop()
                exit(0)
            }
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            term.setEventHandler(handler: stop)
            term.resume()
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            interrupt.setEventHandler(handler: stop)
            interrupt.resume()

            RunLoop.main.run()
            exit(0)
        } catch {
            fputs("[sharedfs] fatal: \(error)\n", stderr)
            exit(1)
        }
    }

    func makeMaterializer(_ args: [String]) throws -> VolumeMaterializer {
        var excludes = TreeScanner.defaultExcludes
        for extra in flagValues("--exclude", args) { excludes.insert(extra) }
        let scanner = TreeScanner(excludes: excludes, alwaysHash: args.contains("--always-hash"))
        let manifests = try ManifestStore(
            root: URL(fileURLWithPath: cacheRoot).appendingPathComponent("manifests"))
        let ops = ContainerCLIVolumeOps(
            cliPath: flagValue("--cli", args) ?? "/usr/local/bin/container",
            helperImage: flagValue("--image", args) ?? "alpine:3.20")
        return VolumeMaterializer(ops: ops, manifests: manifests, scanner: scanner)
    }

    /// Bridges the async API into a top-level script. The semaphore is the
    /// whole point: without it `main.swift` returns before the Task has run.
    func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<T, Error>?
        Task {
            do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch outcome! {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    let arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first ?? "daemon"

    switch command {
    case "daemon":
        runDaemon()

    case "sync":
        guard let src = flagValue("--src", arguments),
            let volume = flagValue("--volume", arguments)
        else { usage() }
        let destination = flagValue("--dest", arguments) ?? "/"
        let source = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
        do {
            let materializer = try makeMaterializer(arguments)
            let stats = try blocking {
                try await materializer.sync(
                    source: source, volume: volume, destination: destination)
            }
            if arguments.contains("--json") {
                let payload: [String: Any] = [
                    "skipped": stats.skipped,
                    "filesShipped": stats.filesShipped,
                    "directoriesCreated": stats.directoriesCreated,
                    "pathsRemoved": stats.pathsRemoved,
                    "bytesShipped": stats.bytesShipped,
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } else if stats.skipped {
                print("up to date — nothing shipped")
            } else {
                print(
                    "shipped \(stats.filesShipped) file(s), \(stats.directoriesCreated) dir(s), "
                        + "removed \(stats.pathsRemoved), \(stats.bytesShipped) bytes")
            }
            exit(0)
        } catch {
            fputs("[sharedfs] sync failed: \(error)\n", stderr)
            exit(1)
        }

    case "invalidate":
        guard let src = flagValue("--src", arguments),
            let volume = flagValue("--volume", arguments)
        else { usage() }
        let destination = flagValue("--dest", arguments) ?? "/"
        let source = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
        do {
            let materializer = try makeMaterializer(arguments)
            try materializer.invalidate(
                source: source, volume: volume, destination: destination)
            print("sync history cleared for \(volume)")
            exit(0)
        } catch {
            fputs("[sharedfs] invalidate failed: \(error)\n", stderr)
            exit(1)
        }

    case "-h", "--help", "help":
        usage()

    default:
        fputs("[sharedfs] unknown command: \(command)\n", stderr)
        usage()
    }

#else

    fputs("[sharedfs] error: shared filesystem support is macOS-only\n", stderr)
    exit(1)

#endif
