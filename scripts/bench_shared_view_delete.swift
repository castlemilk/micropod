// Compile together with the production ChunkHash.swift, SharedView.swift and SharedViewSync.swift.
import Darwin
import Foundation

@main
struct DeleteEventBenchmark {
    enum Failure: Error { case invalidFixture, invalidArguments, failedQoS }

    static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw Failure.invalidFixture }
        return info.phys_footprint
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2, let count = Int(CommandLine.arguments[1]), [8, 2048].contains(count)
        else { throw Failure.invalidArguments }
        guard pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, qos_class_self() == QOS_CLASS_BACKGROUND
        else { throw Failure.failedQoS }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("micropod-delete-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let view = root.appendingPathComponent("view")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<count {
            let directory = source.appendingPathComponent("deps/package-\(i / 64)")
            if i % 64 == 0 { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
            try Data().write(to: directory.appendingPathComponent("f-\(i)"))
        }
        try SharedView.build(source: source, root: view)
        let beforeIndex = try footprint()
        let start = DispatchTime.now().uptimeNanoseconds
        var sync = try SharedViewSync(source: source, view: view)
        let startup = DispatchTime.now().uptimeNanoseconds - start
        let afterIndex = try footprint()
        var samples: [[String: UInt64]] = []
        for round in 0..<18 {
            let fromView = round % 2 == 1
            let origin = fromView ? view : source
            let peer = fromView ? source : view
            let relative = "active/drafts/a.json"
            let file = origin.appendingPathComponent(relative)
            let other = peer.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = Data("revision \(round)".utf8)
            try contents.write(to: file, options: .atomic)
            let create = DispatchTime.now().uptimeNanoseconds
            let inserted = try sync.synchronize(changedPath: file.path, fromView: fromView)
            let createElapsed = DispatchTime.now().uptimeNanoseconds - create
            guard inserted == [relative], try Data(contentsOf: other) == contents else { throw Failure.invalidFixture }
            try fm.removeItem(at: file)
            let deletion = DispatchTime.now().uptimeNanoseconds
            let removed = try sync.synchronize(changedPath: file.path, fromView: fromView)
            let deletionElapsed = DispatchTime.now().uptimeNanoseconds - deletion
            guard removed == [relative], !fm.fileExists(atPath: other.path) else { throw Failure.invalidFixture }
            let duplicate = DispatchTime.now().uptimeNanoseconds
            let stale = try sync.synchronize(changedPath: file.path, fromView: fromView)
            let duplicateElapsed = DispatchTime.now().uptimeNanoseconds - duplicate
            guard stale.isEmpty else { throw Failure.invalidFixture }
            if round >= 2 {
                samples.append([
                    "insert_ns": createElapsed, "delete_ns": deletionElapsed, "duplicate_ns": duplicateElapsed,
                ])
            }
        }
        let result: [String: Any] = [
            "unrelated_files": count, "qos": "background", "warmups": 2, "samples": samples, "init_ns": startup,
            "footprint_before_init_bytes": beforeIndex, "footprint_after_init_bytes": afterIndex,
            "verified_edit_delete_duplicate_rounds": 18,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
        FileHandle.standardOutput.write(Data([10]))
    }
}
