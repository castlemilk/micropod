import Darwin
import Foundation
import Synchronization

/// Compile with the SharedView sources (README, "Benchmarking"). Run each
/// case in a fresh process so peak RSS is attributable to that case.
@main
struct SharedViewBenchmark {
    struct Counts {
        var directoryClones = 0
        var fileClones = 0
        var fallbackFiles = 0
        var fallbackBytes: Int64 = 0
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, ["native", "copy"].contains(args[0]) else {
            fputs("usage: bench-sharedfs-view <native|copy> <source> <new-view>\n", stderr)
            throw POSIXError(.EINVAL)
        }
        let counts = Mutex(Counts())
        let native = args[0] == "native"
        let operations = SharedFileOperations(
            clone: { source, destination in
                guard native, SharedFileOperations.native.clone(source, destination) else { return false }
                var info = stat()
                if lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    counts.withLock { $0.directoryClones += 1 }
                } else {
                    counts.withLock { $0.fileClones += 1 }
                }
                return true
            },
            copy: { source, destination in
                try SharedFileOperations.native.copy(source, destination)
                var info = stat()
                guard lstat(destination.path, &info) == 0 else { throw POSIXError(.EIO) }
                let payload = info.st_mode & S_IFMT == S_IFREG ? info.st_size : 0
                counts.withLock {
                    $0.fallbackFiles += 1
                    $0.fallbackBytes += payload
                }
            })
        let start = DispatchTime.now().uptimeNanoseconds
        try SharedView.build(
            source: URL(fileURLWithPath: args[1]), root: URL(fileURLWithPath: args[2]), files: operations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        let result = counts.withLock { $0 }
        print(
            "directory_clones=\(result.directoryClones) file_clones=\(result.fileClones) fallback_files=\(result.fallbackFiles) fallback_payload_bytes=\(result.fallbackBytes) elapsed_ms=\(Double(elapsed) / 1e6) peak_rss_bytes=\(usage.ru_maxrss)"
        )
    }
}
