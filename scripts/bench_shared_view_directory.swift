// Compile this local workload alongside ChunkHash.swift, SharedView.swift and SharedViewSync.swift.
import Darwin
import Foundation

@main
struct DirectoryEventBenchmark {
    enum Failure: Error {
        case invalidFixture, failedQoS
    }

    static func main() throws {
        guard pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0,
            qos_class_self() == QOS_CLASS_BACKGROUND
        else { throw Failure.failedQoS }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("micropod-directory-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let view = root.appendingPathComponent("view")
        let nested = "work/pkg"
        let file = "a.swift"
        try fm.createDirectory(at: source.appendingPathComponent(nested), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("initial".utf8).write(to: source.appendingPathComponent(nested + "/" + file))
        for i in 0..<16 {
            let dir = source.appendingPathComponent("deps/package-\(i)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for j in 0..<16 {
                try Data("dependency \(i) \(j)".utf8).write(to: dir.appendingPathComponent("f-\(j)"))
            }
        }
        try SharedView.build(source: source, root: view)
        var sync = try SharedViewSync(source: source, view: view)
        var samples: [UInt64] = []
        for revision in 0..<14 {
            let fromView = revision % 2 == 1
            let origin = fromView ? view : source
            let other = fromView ? source : view
            let bytes = Data("editor revision \(revision)".utf8)
            try bytes.write(to: origin.appendingPathComponent(nested + "/" + file), options: .atomic)
            let start = DispatchTime.now().uptimeNanoseconds
            let changed = try sync.synchronize(
                changedPath: origin.appendingPathComponent(nested).path, fromView: fromView)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            guard changed == [nested + "/" + file],
                try Data(contentsOf: other.appendingPathComponent(nested + "/" + file)) == bytes
            else { throw Failure.invalidFixture }
            if revision >= 2 { samples.append(elapsed) }
        }
        let result: [String: Any] = [
            "qos": "background", "unrelated_files": 256, "warmups": 2, "scored_directory_event_ns": samples,
            "cross_view_payload_checks": 14, "first_scored_origin": "source", "origins_alternate": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
