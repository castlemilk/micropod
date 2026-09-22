import Foundation
import MicropodCore
import MicropodSharedFS

// `micropod-sharedfs` daemon entry point. In main.swift the top-level code
// IS the entry point — no @main needed, no struct wrapper. We park forever
// in RunLoop after installing SIGTERM/SIGINT handlers. macOS-only — uses
// FSEvents for live source-tree invalidation.

#if canImport(CoreServices)

    // When spawned by the app, die with it — no orphaned sharedfs.
    ParentDeathWatch.install()

    let env = ProcessInfo.processInfo.environment
    let socketPath =
        env["MICROPOD_SHAREDFS_SOCKET"]
        ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
    let cacheRoot =
        env["MICROPOD_SHAREDFS_CACHE"]
        ?? NSString("~/micropod/share-cache").expandingTildeInPath

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
        let sint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sint.setEventHandler(handler: stop)
        sint.resume()

        RunLoop.main.run()
    } catch {
        fputs("[sharedfs] fatal: \(error)\n", stderr)
        exit(1)
    }

#else

    fputs("[sharedfs] error: FSEvents-based shared filesystem is macOS-only\n", stderr)

#endif
