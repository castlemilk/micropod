import Darwin
import Foundation

@main
struct ChunkRoundTrip {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, ["raw", "lz4"].contains(args[0]) else { throw POSIXError(.EINVAL) }
        let source = URL(fileURLWithPath: args[1])
        let work = URL(fileURLWithPath: args[2])
        let cache = work.appendingPathComponent("store")
        let target = work.appendingPathComponent("restored")
        let start = DispatchTime.now().uptimeNanoseconds
        let store = try ChunkStore(root: cache, transcodeEnabled: args[0] == "lz4")
        let manifest = try store.ingestFileManifest(source)
        let ingested = DispatchTime.now().uptimeNanoseconds
        let reopened = try ChunkStore(root: cache, transcodeEnabled: false)
        try reopened.materialise(.file(manifest), into: target)
        let restored = DispatchTime.now().uptimeNanoseconds
        // Damage the last chunk in this private store. A partial replacement must never escape.
        if let last = manifest.chunks.last {
            try Data("corrupted".utf8).write(to: reopened.chunkPath(last), options: .atomic)
            let sentinel = Data("previous content".utf8)
            let existing = work.appendingPathComponent("existing")
            try sentinel.write(to: existing)
            var rejected = false
            do { try reopened.materialise(.file(manifest), into: existing) } catch { rejected = true }
            guard rejected, try Data(contentsOf: existing) == sentinel else { throw POSIXError(.EIO) }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(.EIO) }
        let result: [String: Any] = [
            "ingest_ms": Double(ingested - start) / 1e6, "reopen_restore_ms": Double(restored - ingested) / 1e6,
            "chunks": manifest.chunks.count, "unique_chunks": Set(manifest.chunks).count,
            "stored_representation_bytes": store.indexedSize, "logical_bytes": manifest.byteCount,
            "sha256": manifest.digest.value, "peak_rss_bytes": usage.ru_maxrss,
        ]
        print(
            String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
