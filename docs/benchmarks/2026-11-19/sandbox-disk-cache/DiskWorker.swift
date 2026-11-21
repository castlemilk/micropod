import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import ContainerizationOS
import Crypto
import Darwin
import Foundation
import MicropodCore
import SystemPackage

enum Disks {
    struct Options {
        enum Base { case image(String), checkpoint(String) }
        let base: Base
        let diskBytes: UInt64
    }
    static var root: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    static var imagesDir: URL { root.appendingPathComponent("images") }
    static var checkpointsDir: URL { root.appendingPathComponent("checkpoints") }
    static func loadCheckpoint(_ name: String) throws -> (image: String, diskBytes: UInt64) {
        throw MicropodError.message("only OCI images are used in this benchmark")
    }
    // INSERT_DISK_FUNCTIONS
}

@main
enum DiskProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("disk probe: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { throw MicropodError.message("cache worker image store barrier") }
        let root = Disks.root, worker = args[2], imageRef = args[3]
        let store = try ImageStore(path: URL(fileURLWithPath: args[4]))
        let barrier = URL(fileURLWithPath: args[5])
        let fm = FileManager.default
        try Data().write(to: barrier.appendingPathComponent("ready-" + worker))
        while !fm.fileExists(atPath: barrier.appendingPathComponent("go").path) {
            try await Task.sleep(for: .milliseconds(1))
        }
        let opts = Disks.Options(base: .image(imageRef), diskBytes: 256 << 20)
        let report: @Sendable (String) -> Void = { print($0) }
        let (base, _, _) = try await Disks.resolveBase(opts, store: store, progress: report)
        let clone = root.appendingPathComponent("clone-" + worker + ".ext4")
        try Disks.clone(base, to: clone)
        let initfs = try await Disks.initfs(store: store, progress: report)
        let guest = try EXT4.EXT4Reader(blockDevice: FilePath(clone.path))
        let initDisk = try EXT4.EXT4Reader(blockDevice: FilePath(initfs.source))
        let digest = SHA256.hash(data: try guest.readFile(at: "/bin/busybox"))
        let alpine = try guest.readFile(at: "/etc/alpine-release")
        let count = ProcessInfo.processInfo.environment["MICROPOD_BENCH_FULL_AGENT"] == "1" ? nil : Optional(4096)
        let agent = SHA256.hash(data: try initDisk.readFile(at: "/sbin/vminitd", count: count))
        func hex(_ value: SHA256.Digest) -> String { value.map { String(format: "%02x", $0) }.joined() }
        print(
            "verified \(String(decoding: alpine, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) \(hex(digest)) \(hex(agent))"
        )
    }
}
