import Foundation
import MicropodCore
import MicropodSharedFS

/// `micropod build-cache` — inspect the content-addressed build-context
/// cache (the virtualFS-backed "cache re-use" half of fast rebuilds).
///
/// Read-only: scans `~/.micropod/builds/cache` directly, so it works
/// whether or not any shim is running. See `BuildCacheStore`.
enum BuildCacheCommands {
    static func run(_ args: [String]) async throws {
        guard let sub = args.first else {
            printHelp()
            return
        }
        switch sub {
        case "stats":
            stats(Array(args.dropFirst()))
        case "inspect":
            try inspect(Array(args.dropFirst()))
        case "help", "--help", "-h":
            printHelp()
        default:
            fputs("unknown build-cache subcommand: \(sub)\n", stderr)
            printHelp()
            throw MicropodError.message("unknown build-cache subcommand: \(sub)")
        }
    }

    static func printHelp() {
        print(
            """
            Usage: micropod build-cache <command> [options]

            Commands:
              stats                    Retained contexts, bytes, cross-context shared bytes, cap
              inspect <hash-prefix>    List a retained context's files + sharing

            The build-context cache keys extracted build contexts by content
            tree-hash (paths + bytes, mtime-insensitive). Identical rebuilds
            reuse the retained extraction; manifests record per-file content
            digests in chunk-store addressing so sharing between different
            contexts is measurable. Retained under ~/.micropod/builds/cache,
            LRU-capped (MICROPOD_BUILD_CACHE_MAX_BYTES, default 5 GiB).
            """)
    }

    private static func root(args: [String]) -> URL {
        if let index = args.firstIndex(of: "--root"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        return BuildCacheStore.standardRoot()
    }

    private static func stats(_ args: [String]) {
        let (_, stats) = BuildCacheStore.scan(root: root(args: args))
        print("entries: \(stats.entries)")
        print("content-bytes: \(stats.contentBytes)")
        print("shared-bytes: \(stats.sharedBytes)")
        print("cap-bytes: \(stats.capBytes)")
    }

    private static func inspect(_ args: [String]) throws {
        guard let prefix = args.first(where: { !$0.hasPrefix("--") }) else {
            throw MicropodError.message("micropod build-cache inspect <hash-prefix>")
        }
        let (manifests, _) = BuildCacheStore.scan(root: root(args: args))
        let matches = manifests.filter { $0.treeHash.hasPrefix(prefix.lowercased()) }
        guard let manifest = matches.first else {
            throw MicropodError.message("no cached context matching '\(prefix)'")
        }
        if matches.count > 1 {
            fputs("warning: \(matches.count) entries match, showing \(manifest.treeHash.prefix(12))\n", stderr)
        }
        let others = manifests.filter { $0.treeHash != manifest.treeHash }
        let otherHashes = Set(others.flatMap { $0.files.map(\.sha256) })
        var shared: UInt64 = 0
        var seen = Set<String>()
        for file in manifest.files where seen.insert(file.sha256).inserted {
            if otherHashes.contains(file.sha256) { shared += file.size }
        }
        print("tree: \(manifest.treeHash)")
        print("files: \(manifest.files.count)")
        print("content-bytes: \(manifest.contentBytes)")
        print("shared-with-others-bytes: \(shared)")
        print("tar-bytes: \(manifest.tarBytes)")
        for file in manifest.files.sorted(by: { $0.path < $1.path }).prefix(50) {
            let mark = otherHashes.contains(file.sha256) ? "*" : " "
            print("\(mark) \(file.path)  \(file.size)B  \(file.sha256.prefix(12))")
        }
        if manifest.files.count > 50 {
            print("… (\(manifest.files.count - 50) more)")
        }
    }
}
