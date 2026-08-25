import Foundation
import MicropodCore
import MicropodSharedFS

/// `micropod share` — synchronized file shares (virtual + synchronized).
///
/// The daemon (`micropod-sharedfs`) is macOS-only. These commands are
/// identical whether they talk to the live daemon over its unix socket or
/// drive an in-process daemon (for tests). The shim auto-discovers the
/// daemon at `~/micropod/share-cache/socket` and routes directory binds
/// through it.
enum SharedCommands {
    static func run(_ args: [String]) async throws {
        guard let sub = args.first else {
            printHelp()
            return
        }
        switch sub {
        case "mount":
            try await mount(Array(args.dropFirst()))
        case "unmount", "umount":
            try await unmount(Array(args.dropFirst()))
        case "list", "ls":
            try await list(Array(args.dropFirst()))
        case "inspect":
            try await inspect(Array(args.dropFirst()))
        case "sync":
            try await sync(Array(args.dropFirst()))
        case "gc":
            try await gc(Array(args.dropFirst()))
        case "daemon":
            try await daemon(Array(args.dropFirst()))
        case "help", "--help", "-h":
            printHelp()
        default:
            fputs("unknown share subcommand: \(sub)\n", stderr)
            printHelp()
            throw MicropodError.message("unknown share subcommand: \(sub)")
        }
    }

    static func printHelp() {
        print(
            """
            Usage: micropod share <command> [options]

            Commands:
              mount <src> [--ro] [--shared]  Expose a host directory as a synchronized share
                                             (--shared: single live view shared by all
                                              containers mounting the same src)
              unmount <id>                   Remove a shared view
              list                           List active shared views
              inspect <id>                   Show a view's details
              sync <id>                      Flush a view's writes back to its source
              gc                             Remove unreferenced chunks
              daemon [--foreground]          Start the shared-fs daemon

            The daemon is macOS-only (FSEvents, 0.1s). When running, every
            directory bind is served through the shared cache (APFS clonefile +
            256 KiB chunk dedup) with live bidirectional FSEvents sync
            (host ↔ view ↔ sibling views via host hub, per-file hash-checked).
            Without the daemon, binds fall back to plain virtiofs.
            Env: MICROPOD_SHAREDFS_LIVE=0 disables live shared views (isolated).
            """
        )
    }

    // MARK: - Helpers

    private static var client: any SharedFSClient {
        let socket =
            ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_SOCKET"]
            ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
        return UnixSocketClient(socketPath: socket)
    }

    private static func mount(_ args: [String]) async throws {
        guard let src = args.first(where: { !$0.hasPrefix("-") }) else {
            throw MicropodError.message("micropod share mount <src> [--ro] [--shared]")
        }
        let readonly = args.contains("--ro") || args.contains("--readonly")
        let shared = args.contains("--shared")
        let url = URL(fileURLWithPath: src).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            throw MicropodError.message("source is not a directory: \(src)")
        }
        let info: MountInfo
        if shared {
            info = try await client.mountShared(src: url, readonly: readonly)
        } else {
            info = try await client.mount(src: url, readonly: readonly)
        }
        print("\(info.id.value)  \(info.src) -> \(info.viewPath)  (\(info.sizeBytes) bytes)")
    }

    private static func unmount(_ args: [String]) async throws {
        guard let id = args.first else {
            throw MicropodError.message("micropod share unmount <id>")
        }
        try await client.unmount(id: ViewID(id))
        print("unmounted \(id)")
    }

    private static func list(_ args: [String]) async throws {
        _ = args
        let mounts = try await client.list()
        if mounts.isEmpty {
            print("no shared views")
            return
        }
        for info in mounts {
            print("\(info.id.value)\t\(info.src) -> \(info.viewPath)  \(info.sizeBytes)B")
        }
    }

    private static func inspect(_ args: [String]) async throws {
        guard let id = args.first else {
            throw MicropodError.message("micropod share inspect <id>")
        }
        let info = try await client.inspect(id: ViewID(id))
        print("id: \(info.id.value)")
        print("src: \(info.src)")
        print("view: \(info.viewPath)")
        print("size: \(info.sizeBytes)")
        print("readonly: \(info.readonly)")
        print("created: \(info.createdAt)")
    }

    private static func sync(_ args: [String]) async throws {
        guard let id = args.first else {
            throw MicropodError.message("micropod share sync <id>")
        }
        let result = try await client.sync(id: ViewID(id))
        if result.synced.isEmpty {
            print("nothing to sync for \(id)")
        } else {
            print("synced \(result.synced.count) file(s), \(result.bytesWritten) bytes")
            for path in result.synced { print("  \(path)") }
        }
    }

    private static func gc(_ args: [String]) async throws {
        _ = args
        let result = try await client.gc()
        print("removed \(result.chunksRemoved) chunks, reclaimed \(result.bytesReclaimed) bytes")
    }

    private static func daemon(_ args: [String]) async throws {
        let foreground = args.contains("--foreground") || args.contains("-f")
        let socket =
            ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_SOCKET"]
            ?? NSString("~/micropod/share-cache/socket").expandingTildeInPath
        if FileManager.default.fileExists(atPath: socket) {
            print("daemon already running at \(socket) (remove the socket to restart)")
            return
        }
        let exe =
            ProcessInfo.processInfo.environment["MICROPOD_SHAREDFS_BIN"]
            ?? Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("micropod-sharedfs").path
            ?? "./.build/debug/micropod-sharedfs"
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw MicropodError.message("micropod-sharedfs not found at \(exe)")
        }
        if foreground {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exe)
            try proc.run()
            proc.waitUntilExit()
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            proc.arguments = [exe]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            print("daemon started at \(socket)")
        }
    }
}
