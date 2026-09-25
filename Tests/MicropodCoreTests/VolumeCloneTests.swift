import XCTest

@testable import MicropodCore

/// `VolumeClone` is the file-level half of clone-backed volumes: an APFS
/// clonefile of a golden image, and the fsync + atomic-rename promotion of
/// a container's clone back over the golden. `VolumeLocks` serialises the
/// promotion against the container delete that removes clone images.
final class VolumeCloneTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A pseudo-random, incompressible payload so identical bytes prove a
    /// real copy (or CoW clone), not a coincidence of zero-filled images.
    private func payload(seed: UInt8, count: Int = 1 << 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var state = UInt32(seed) &+ 1
        for index in bytes.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return Data(bytes)
    }

    private func path(_ name: String) -> String {
        dir.appendingPathComponent(name).path
    }

    // MARK: - cloneImage

    func testCloneImageProducesIdenticalBytesAndAllocatedBlocks() throws {
        let golden = payload(seed: 1)
        try golden.write(to: URL(fileURLWithPath: path("golden.img")))

        try VolumeClone.cloneImage(from: path("golden.img"), to: path("clones/c1/golden.img"))

        let cloned = try Data(contentsOf: URL(fileURLWithPath: path("clones/c1/golden.img")))
        XCTAssertEqual(cloned.count, golden.count)
        XCTAssertEqual(cloned, golden)
        XCTAssertGreaterThan(VolumeClone.allocatedBytes(atPath: path("clones/c1/golden.img")), 0)
        XCTAssertGreaterThanOrEqual(
            VolumeClone.allocatedBytes(atPath: path("golden.img")), UInt64(golden.count),
            "st_blocks × 512 covers the written bytes")
    }

    func testCloneImageReplacesAnExistingTargetAndLeavesNoTempFile() throws {
        try payload(seed: 2).write(to: URL(fileURLWithPath: path("golden.img")))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path("clone.img")))

        try VolumeClone.cloneImage(from: path("golden.img"), to: path("clone.img"))

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path("clone.img"))), payload(seed: 2))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clone.img", "golden.img"])
    }

    func testCloneImageMissingSourceThrowsAndCreatesNothing() {
        XCTAssertThrowsError(try VolumeClone.cloneImage(from: path("absent.img"), to: path("out/clone.img")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("out/clone.img")))
    }

    /// The create path places a container's clone exclusively: a clone that
    /// is already there belongs to the container that won a replayed create
    /// (and may be its live block device), so it is never renamed over. The
    /// refusal is `already_exists` and leaves no staging file behind.
    func testExclusiveCloneImageRefusesAnExistingTargetAndKeepsItsBytes() throws {
        try payload(seed: 9).write(to: URL(fileURLWithPath: path("golden.img")))
        let live = payload(seed: 10)
        try live.write(to: URL(fileURLWithPath: path("clone.img")))

        XCTAssertThrowsError(
            try VolumeClone.cloneImage(from: path("golden.img"), to: path("clone.img"), placement: .exclusive)
        ) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "already_exists", "\(error)")
            XCTAssertTrue(error.localizedDescription.contains(path("clone.img")), "\(error)")
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path("clone.img"))), live, "the winner's clone is untouched")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clone.img", "golden.img"],
            "no staging file may survive a refused placement")
    }

    func testExclusiveCloneImagePlacesAFreshClone() throws {
        let golden = payload(seed: 11)
        try golden.write(to: URL(fileURLWithPath: path("golden.img")))

        try VolumeClone.cloneImage(from: path("golden.img"), to: path("clones/c2/golden.img"), placement: .exclusive)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("clones/c2/golden.img"))), golden)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("clones/c2")), ["golden.img"])
    }

    // MARK: - commit

    func testCommitReplacesGoldenAtomicallyAndReportsAllocatedBytes() throws {
        let before = payload(seed: 3)
        let after = payload(seed: 4)
        try before.write(to: URL(fileURLWithPath: path("golden.img")))
        try FileManager.default.createDirectory(atPath: path("clones/job-1"), withIntermediateDirectories: true)
        try after.write(to: URL(fileURLWithPath: path("clones/job-1/golden.img")))

        let allocated = try VolumeClone.commit(
            clonePath: path("clones/job-1/golden.img"), goldenPath: path("golden.img"))

        XCTAssertGreaterThan(allocated, 0)
        XCTAssertGreaterThanOrEqual(allocated, UInt64(after.count))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("golden.img"))), after)
        // The container's clone stays where its configuration points (it is
        // removed with the container); the golden is a CoW twin of it.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("clones/job-1/golden.img"))), after)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clones", "golden.img"],
            "no temp file may survive a commit")
    }

    func testCommitMissingCloneThrowsAndLeavesGoldenUntouched() throws {
        let before = payload(seed: 5)
        try before.write(to: URL(fileURLWithPath: path("golden.img")))

        XCTAssertThrowsError(
            try VolumeClone.commit(clonePath: path("clones/ghost/golden.img"), goldenPath: path("golden.img")))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("golden.img"))), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["golden.img"])
    }

    func testCommitMissingGoldenDirectoryThrows() throws {
        try payload(seed: 6).write(to: URL(fileURLWithPath: path("clone.img")))
        XCTAssertThrowsError(
            try VolumeClone.commit(clonePath: path("clone.img"), goldenPath: path("no-such-dir/golden.img")))
    }

    /// A crash between staging and rename leaves `.golden.img.tmp-*` next to
    /// the golden; the next commit sweeps such leftovers — and only those,
    /// the sweep is keyed to this golden's staging prefix.
    func testCommitSweepsStagingLeftByACrashedCommit() throws {
        try payload(seed: 7).write(to: URL(fileURLWithPath: path("golden.img")))
        try FileManager.default.createDirectory(atPath: path("clones/job-2"), withIntermediateDirectories: true)
        let after = payload(seed: 8)
        try after.write(to: URL(fileURLWithPath: path("clones/job-2/golden.img")))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path(".golden.img.tmp-dead0000")))
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path(".golden.img.tmp-cafe1111")))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path(".other.img.tmp-00000000")))

        _ = try VolumeClone.commit(clonePath: path("clones/job-2/golden.img"), goldenPath: path("golden.img"))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("golden.img"))), after)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
            [".other.img.tmp-00000000", "clones", "golden.img"],
            "stale staging files for this golden are swept; other names are untouched")
    }

    // MARK: - allocatedBytes / clone paths

    func testAllocatedBytesOfMissingFileIsZero() {
        XCTAssertEqual(VolumeClone.allocatedBytes(atPath: path("nope.img")), 0)
    }

    func testClonePathIsUnderTheOverriddenRoot() throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        XCTAssertEqual(VolumeClone.cloneRoot.path, dir.path)
        XCTAssertEqual(
            try VolumeClone.clonePath(containerID: "job-7", volume: "npm").path,
            dir.appendingPathComponent("job-7/npm.img").path)

        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: "job-7"), [])
        try FileManager.default.createDirectory(atPath: path("job-7"), withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: path("job-7/npm.img")))
        try Data().write(to: URL(fileURLWithPath: path("job-7/go-mod.img")))
        try Data().write(to: URL(fileURLWithPath: path("job-7/notes.txt")))
        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: "job-7"), ["go-mod", "npm"])
    }

    // MARK: - Path-component grammars (container ids and volume names)

    /// A container id is the directory component of a clone path
    /// (`<root>/<id>/`), so it must match the runtime's own container-ID
    /// grammar, `[A-Za-z0-9][A-Za-z0-9_.-]{0,62}`: no separator can pass, so
    /// neither `..` nor `a/b` can steer a clone-dir operation elsewhere.
    func testSafeComponentIsTheRuntimeIDGrammar() {
        for good in ["a", "7", "job-7", "A.b_c-9", "npm", "9foo", "foo.bar", String(repeating: "x", count: 63)] {
            XCTAssertTrue(VolumeClone.isSafeComponent(good), good)
            XCTAssertNoThrow(try VolumeClone.requireSafeComponent(good), good)
        }
        for bad in [
            "", ".", "..", "../x", "a/b", "/a", "a/", "-a", "_a", ".a", "a b", "a:b", "é", "a\u{0}b", "ab\n",
            String(repeating: "x", count: 64), "../../com.apple.container/volumes/golden",
        ] {
            XCTAssertFalse(VolumeClone.isSafeComponent(bad), bad.debugDescription)
            XCTAssertThrowsError(try VolumeClone.requireSafeComponent(bad), bad.debugDescription) { error in
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
                XCTAssertTrue(error.localizedDescription.contains(VolumeClone.componentGrammar), "\(error)")
            }
        }
    }

    /// A volume name is the file component (`<root>/<id>/<name>.img`) and
    /// must match the runtime's own *volume* grammar: the id grammar's
    /// characters and no cap of its own (`container` 1.3.1 creates a
    /// 64-character volume; `café`, `.h` and `a/b` are refused `must match
    /// ^[A-Za-z0-9][A-Za-z0-9_.-]*$`). The only bound is the filename
    /// limit, and the longest name the clone places is not `<name>.img` but
    /// its staging file `.<name>.img.tmp-<8 hex>` — 18 bytes more than the
    /// name — so on APFS (`NAME_MAX` 255) 237 characters fit and 238 do
    /// not. The id cap does not apply to volume names, and the volume bound
    /// does not loosen ids.
    func testSafeVolumeNameIsTheRuntimeVolumeGrammar() {
        XCTAssertEqual(VolumeClone.stagingOverhead, 18, "`.` + `.img` + `.tmp-` + 8 hex")
        XCTAssertEqual(VolumeClone.maxVolumeNameLength, Int(NAME_MAX) - VolumeClone.stagingOverhead)
        XCTAssertEqual(VolumeClone.maxVolumeNameLength, 237)
        XCTAssertEqual(VolumeClone.volumeNameGrammar, "[A-Za-z0-9][A-Za-z0-9_.-]{0,236}")
        for good in [
            "a", "7", "npm", "A.b_c-9", "9foo", "foo.bar", String(repeating: "v", count: 63),
            String(repeating: "v", count: 64), "cf-cache-" + String(repeating: "k", count: 120),
            String(repeating: "v", count: 237),
        ] {
            XCTAssertTrue(VolumeClone.isSafeVolumeName(good), good)
            XCTAssertNoThrow(try VolumeClone.requireSafeVolumeName(good), good)
        }
        for bad in [
            "", ".", "..", "../x", "a/b", "/a", "a/", "-a", "_a", ".a", "a b", "a:b", "é", "a\u{0}b", "ab\n",
            String(repeating: "v", count: 238), String(repeating: "v", count: 252),
            "../../com.apple.container/volumes/golden",
        ] {
            XCTAssertFalse(VolumeClone.isSafeVolumeName(bad), bad.debugDescription)
            XCTAssertThrowsError(try VolumeClone.requireSafeVolumeName(bad), bad.debugDescription) { error in
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
                XCTAssertTrue(error.localizedDescription.contains(VolumeClone.volumeNameGrammar), "\(error)")
            }
        }
        XCTAssertTrue(VolumeClone.isSafeComponent(String(repeating: "v", count: 63)), "the id cap stays 63")
        XCTAssertFalse(VolumeClone.isSafeComponent(String(repeating: "v", count: 64)), "the id cap stays 63")
    }

    /// A 64-character volume name (cuttlefish's `cf-cache-<project>-<node>-
    /// <path>-<key>` names have no length bound) is a clone-path component
    /// like any other: `clonePath` names `<root>/<id>/<name>.img`,
    /// `clonedVolumes` lists it, `requireClone` finds it and both
    /// `removeClones` unlink it — a pre-guard build placed such clones, and
    /// a dir left behind with the file in it would never be reclaimed. A
    /// name past the filename limit (the staging name must fit `NAME_MAX`)
    /// is refused before any look at the filesystem.
    func testLongVolumeNamesAreClonePathComponents() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        let long = String(repeating: "v", count: 64)
        let longest = String(repeating: "w", count: 237)
        let tooLong = String(repeating: "x", count: 238)

        let clone = try VolumeClone.clonePath(containerID: "job-long", volume: long)
        XCTAssertEqual(clone.path, path("job-long/\(long).img"))
        XCTAssertEqual(
            try VolumeClone.clonePath(containerID: "job-long", volume: longest).path, path("job-long/\(longest).img"))
        XCTAssertThrowsError(try VolumeClone.clonePath(containerID: "job-long", volume: tooLong)) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertThrowsError(try VolumeClone.requireClone(containerID: "job-long", volume: tooLong)) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }

        try FileManager.default.createDirectory(atPath: path("job-long"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: clone)
        try Data("y".utf8).write(to: URL(fileURLWithPath: path("job-long/\(longest).img")))
        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: "job-long"), [long, longest])
        XCTAssertEqual(try VolumeClone.requireClone(containerID: "job-long", volume: long), clone.path)
        XCTAssertEqual(
            try VolumeClone.requireClone(containerID: "job-long", volume: longest), path("job-long/\(longest).img"))

        await VolumeClone.removeClones(containerID: "job-long", volumes: [long])
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path), "the named 64-character clone is unlinked")
        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: "job-long"), [longest], "only the named one")
        await VolumeClone.removeClones(containerID: "job-long")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-long")), "every clone and the dir are gone")
    }

    /// The longest name the volume grammar admits is placed for real, not
    /// just named: `cloneImage` stages the clone as `.<name>.img.tmp-<8
    /// hex>` beside its destination before the rename, so that staging name
    /// — 18 bytes more than the volume name — is what must fit `NAME_MAX`.
    /// A 237-character name (255 bytes staged on APFS) is placed exclusively
    /// at its `clonePath`, leaves no staging file, and commits back over the
    /// golden. One more character is refused `invalid_argument` by the
    /// grammar before any filesystem work — the bound is tight: past the
    /// grammar, the placement itself fails `File name too long`, which would
    /// surface as `internal` from a create that passed every guard.
    func testTheLongestVolumeNameIsPlacedAndCommitted() throws {
        let root = dir.appendingPathComponent("clones", isDirectory: true)
        setenv("MICROPOD_VOLUME_CLONE_ROOT", root.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        let store = dir.appendingPathComponent("store/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let golden = store.appendingPathComponent("volume.img").path
        try payload(seed: 30, count: 4096).write(to: URL(fileURLWithPath: golden))

        let longest = String(repeating: "w", count: VolumeClone.maxVolumeNameLength)
        XCTAssertEqual(longest.utf8.count, 237)
        let clone = try VolumeClone.clonePath(containerID: "job-max", volume: longest)
        let staging = URL(fileURLWithPath: VolumeClone.tempPath(nextTo: clone)).lastPathComponent
        XCTAssertTrue(staging.hasPrefix(".\(longest).img.tmp-"), staging)
        XCTAssertEqual(staging.utf8.count, longest.utf8.count + VolumeClone.stagingOverhead, staging)
        XCTAssertEqual(staging.utf8.count, Int(NAME_MAX), "the staging name just fits")
        try VolumeClone.cloneImage(from: golden, to: clone.path, placement: .exclusive)
        XCTAssertEqual(try Data(contentsOf: clone), payload(seed: 30, count: 4096))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("job-max").path),
            ["\(longest).img"], "no staging file left beside the clone")

        // The container wrote into its clone; the commit promotes those bytes.
        let written = payload(seed: 31, count: 4096)
        let handle = try FileHandle(forWritingTo: clone)
        try handle.write(contentsOf: written)
        try handle.close()
        XCTAssertGreaterThan(try VolumeClone.commit(clonePath: clone.path, goldenPath: golden), 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: golden)), written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), ["volume.img"])

        let tooLong = longest + "w"
        XCTAssertThrowsError(try VolumeClone.clonePath(containerID: "job-over", volume: tooLong)) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertThrowsError(try VolumeClone.requireClone(containerID: "job-over", volume: tooLong)) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), ["job-max"], "nothing placed for 238")

        let unguarded = dir.appendingPathComponent("unguarded/\(tooLong).img").path
        XCTAssertThrowsError(try VolumeClone.cloneImage(from: golden, to: unguarded, placement: .exclusive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("File name too long"), "\(error)")
        }
    }

    /// The clone root's sibling store holds a golden, exactly where
    /// `<root>/../../com.apple.container/volumes/<golden>/volume.img` points
    /// (Apple's volume store next to micropod's clone root under Application
    /// Support). A request's name reaches the clone-dir lifecycle before the
    /// runtime validates it, so every function that builds a path from an id
    /// or a volume name must refuse an unsafe one without touching the
    /// filesystem: the golden's image and directory survive, nothing is
    /// placed, and the refusal is `invalid_argument`.
    func testTraversalIDsAndVolumeNamesNeverReachTheFilesystem() async throws {
        let store = dir.appendingPathComponent("com.apple.container/volumes/golden", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let golden = payload(seed: 12, count: 4096)
        try golden.write(to: store.appendingPathComponent("volume.img"))
        let root = dir.appendingPathComponent("micropod/volume-clones", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("MICROPOD_VOLUME_CLONE_ROOT", root.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        let traversal = "../../com.apple.container/volumes/golden"
        let traversalVolume = "../../../com.apple.container/volumes/golden/volume"
        // What a naive join would produce — the golden itself.
        XCTAssertEqual(
            root.appendingPathComponent(traversal).appendingPathComponent("volume.img").standardizedFileURL.path,
            store.appendingPathComponent("volume.img").path)
        XCTAssertEqual(
            root.appendingPathComponent("job").appendingPathComponent("\(traversalVolume).img").standardizedFileURL
                .path,
            store.appendingPathComponent("volume.img").path)

        XCTAssertThrowsError(try VolumeClone.clonePath(containerID: traversal, volume: "volume")) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertThrowsError(try VolumeClone.clonePath(containerID: "job", volume: traversalVolume)) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertEqual(VolumeClone.clonedVolumes(containerID: traversal), [])
        let reclaimed = await VolumeClone.reclaimStaleCloneDir(containerID: traversal, live: [])
        XCTAssertFalse(reclaimed, "a traversal id is never reclaimed")
        await VolumeClone.removeClones(containerID: traversal)
        await VolumeClone.removeClones(containerID: traversal, volumes: ["volume"])
        await VolumeClone.removeClones(containerID: "job", volumes: [traversalVolume])
        XCTAssertThrowsError(try VolumeClone.requireClone(containerID: traversal, volume: "volume")) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertThrowsError(try VolumeClone.requireClone(containerID: "job", volume: traversalVolume)) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }

        XCTAssertEqual(
            try Data(contentsOf: store.appendingPathComponent("volume.img")), golden, "the golden's bytes survive")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.path), ["volume.img"],
            "the golden's directory survives, with nothing staged next to it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "nothing was placed")
    }

    /// Only the container that mounts a clone may promote it: a clone file
    /// under a container's id that the container's configuration does not
    /// mount is a leftover of an earlier container of that name (a raw
    /// `container delete` keeps the dir), not this container's writes.
    func testRequireMountedNeedsAMountWhoseSourceIsTheClone() throws {
        let clone = path("clones/job-8/g.img")
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self,
            from: Data(
                """
                [{"id":"job-8","configuration":{"mounts":[
                    {"destination":"/x","source":"\(clone)","options":[],"type":{"block":{}}},
                    {"destination":"/y","source":"g","options":[],"type":{"volume":{"name":"g"}}}]},
                  "status":{"state":"stopped"}},
                 {"id":"job-9","configuration":{"mounts":[
                    {"destination":"/x","source":"g","options":[],"type":{"virtiofs":{}}}]},
                  "status":{"state":"stopped"}},
                 {"id":"job-10","configuration":{},"status":{"state":"stopped"}}]
                """.utf8), context: "test entries")

        XCTAssertNoThrow(try VolumeClone.requireMounted(clone: clone, containerID: "job-8", volume: "g", in: entries))
        for id in ["job-9", "job-10", "ghost"] {
            XCTAssertThrowsError(
                try VolumeClone.requireMounted(clone: clone, containerID: id, volume: "g", in: entries), id
            ) { error in
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "not_found", "\(id): \(error)")
                XCTAssertTrue(error.localizedDescription.contains("'\(id)'"), "\(error)")
                XCTAssertTrue(error.localizedDescription.contains("mount"), "\(error)")
            }
        }
    }

    // MARK: - removeClones / sweepOrphanClones (shared by the CLI and native container services)

    /// A container's clone dir goes with the container: every clone image,
    /// any staging file a crashed placement left, and the dir itself. Other
    /// containers' dirs are untouched.
    func testRemoveClonesDeletesTheContainerDirAndNothingElse() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        for name in ["job-1/npm.img", "job-1/go-mod.img", "job-1/.npm.img.tmp-dead0000", "job-2/npm.img"] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        await VolumeClone.removeClones(containerID: "job-1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-1")), "job-1's clone dir is gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("job-2")), ["npm.img"])
        // Idempotent: a container without a clone dir is a no-op.
        await VolumeClone.removeClones(containerID: "job-1")
        await VolumeClone.removeClones(containerID: "never-existed")
    }

    /// Each clone image is unlinked under its volume's lock, so a commit
    /// holding that lock finishes its rename before the file goes away.
    func testRemoveClonesWaitsForTheVolumeLock() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        try FileManager.default.createDirectory(atPath: path("job-3"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path("job-3/npm.img")))

        let held = AsyncGate()
        let release = AsyncGate()
        let holder = Task {
            await VolumeLocks.shared.withLock("npm") {
                await held.open()
                await release.wait()
            }
        }
        await held.wait()

        let removal = Task { await VolumeClone.removeClones(containerID: "job-3") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path("job-3/npm.img")),
            "the clone was unlinked while its volume's lock was held")

        await release.open()
        await holder.value
        await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-3")))
    }

    /// A failed create removes exactly the clones it placed — the others
    /// under the same id were placed by a replay that won the name (and may
    /// be running on them) — and the dir only once that leaves it empty.
    func testRemoveClonesOfNamedVolumesLeavesTheOthersAndTheDir() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        try FileManager.default.createDirectory(atPath: path("job-4"), withIntermediateDirectories: true)
        for name in ["job-4/a.img", "job-4/b.img", "job-4/.b.img.tmp-cafe1111"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: path(name)))
        }

        await VolumeClone.removeClones(containerID: "job-4", volumes: ["a"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: path("job-4")).sorted(),
            [".b.img.tmp-cafe1111", "b.img"],
            "only the named clone goes; another create's staging file is not swept")

        await VolumeClone.removeClones(containerID: "job-4", volumes: [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: path("job-4")).sorted(),
            [".b.img.tmp-cafe1111", "b.img"],
            "nothing named, nothing removed; a non-empty dir stays")

        unlink(path("job-4/.b.img.tmp-cafe1111"))
        await VolumeClone.removeClones(containerID: "job-4", volumes: ["b", "never-placed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-4")), "the dir goes once it is empty")

        // A placement that failed before its copy leaves an empty dir; the
        // failed create removes it with nothing named.
        try FileManager.default.createDirectory(atPath: path("job-5"), withIntermediateDirectories: true)
        await VolumeClone.removeClones(containerID: "job-5", volumes: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("job-5")))
    }

    /// A clone dir younger than the grace period is reclaimed when no
    /// container has its id and the caller vouches that no create of that
    /// id is in flight — it is the leftover of a create that died with its
    /// process. A live id's dir is never touched; no dir is not an error.
    func testReclaimStaleCloneDirIgnoresTheGraceButNotALiveID() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        for name in ["dead", "live"] {
            try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path("\(name)/npm.img")))
        }

        let reclaimedLive = await VolumeClone.reclaimStaleCloneDir(containerID: "live", live: ["live", "other"])
        XCTAssertFalse(reclaimedLive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("live/npm.img")))

        let reclaimed = await VolumeClone.reclaimStaleCloneDir(containerID: "dead", live: ["live", "other"])
        XCTAssertTrue(reclaimed, "a young dir with no container behind it is reclaimed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("dead")))

        let absent = await VolumeClone.reclaimStaleCloneDir(containerID: "absent", live: [])
        XCTAssertFalse(absent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["live"])
    }

    func testRequireDistinctRefusesACloneOntoItself() {
        XCTAssertThrowsError(try VolumeClone.requireDistinct(source: "g", name: "g")) { error in
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument", "\(error)")
        }
        XCTAssertNoThrow(try VolumeClone.requireDistinct(source: "g", name: "g-2"))
    }

    /// The orphan sweep removes clone dirs of containers that no longer
    /// exist — except dirs younger than the grace period, which may belong
    /// to a create that has not reached the runtime yet.
    func testSweepOrphanClonesKeepsLiveAndYoungDirs() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        for name in ["live", "ghost", "young"] {
            try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path("\(name)/npm.img")))
        }
        let old = Date().addingTimeInterval(-(VolumeClone.orphanGrace + 60))
        for name in ["live", "ghost"] {
            try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: path(name))
        }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path("stray-file")))

        await VolumeClone.sweepOrphanClones(live: ["live"])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["live", "stray-file", "young"])
    }

    /// A dir under the clone root whose name is outside the id grammar
    /// (only a pre-guard build or a hand can put one there) was never
    /// built by this code: the sweep leaves it — and everything in it —
    /// where it is whatever its age, and says so on stderr, while an
    /// orphan next to it is still swept.
    func testSweepOrphanClonesLeavesADirOutsideTheGrammar() async throws {
        setenv("MICROPOD_VOLUME_CLONE_ROOT", dir.path, 1)
        defer { unsetenv("MICROPOD_VOLUME_CLONE_ROOT") }
        let old = Date().addingTimeInterval(-(VolumeClone.orphanGrace + 60))
        for name in ["-not-an-id", "ghost"] {
            try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path("\(name)/npm.img")))
            try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: path(name))
        }

        await VolumeClone.sweepOrphanClones(live: [])

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["-not-an-id"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("-not-an-id")), ["npm.img"])
    }

    // MARK: - VolumeLocks

    func testVolumeLocksSerialisePerNameAndRunOtherNamesConcurrently() async throws {
        let locks = VolumeLocks()
        let log = EventLog()

        // Hold "a" until released.
        let release = AsyncGate()
        let holder = Task {
            await locks.withLock("a") {
                await log.record("a-held")
                await release.wait()
                await log.record("a-released")
            }
        }
        await log.waitFor("a-held")

        // A second "a" must queue behind the holder …
        let contender = Task {
            await locks.withLock("a") { await log.record("a-second") }
        }
        // … while "b" proceeds immediately.
        await locks.withLock("b") { await log.record("b-ran") }
        await log.waitFor("b-ran")
        try await Task.sleep(for: .milliseconds(100))
        var events = await log.events
        XCTAssertFalse(events.contains("a-second"), "second holder ran while the lock was held: \(events)")

        await release.open()
        await holder.value
        await contender.value
        events = await log.events
        XCTAssertEqual(events.firstIndex(of: "a-released")! < events.firstIndex(of: "a-second")!, true, "\(events)")
    }

    func testVolumeLocksReleaseWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let locks = VolumeLocks()
        do {
            try await locks.withLock("x") { throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {}
        // Still acquirable — the failed body released it.
        let ran = await locks.withLock("x") { true }
        XCTAssertTrue(ran)
    }

    /// `withLocks` holds every named lock for the body (a volume prune
    /// touches all volumes), acquiring them in sorted order so two holders
    /// of overlapping sets cannot deadlock, and queues behind any single
    /// holder of one of the names.
    func testWithLocksWaitsForEveryNameAndReleasesAll() async throws {
        let locks = VolumeLocks()
        let log = EventLog()

        let release = AsyncGate()
        let holder = Task {
            await locks.withLock("b") {
                await log.record("b-held")
                await release.wait()
                await log.record("b-released")
            }
        }
        await log.waitFor("b-held")

        let sweeper = Task {
            await locks.withLocks(["c", "a", "b", "a"]) { await log.record("all-held") }
        }
        try await Task.sleep(for: .milliseconds(100))
        var events = await log.events
        XCTAssertFalse(events.contains("all-held"), "ran while 'b' was held: \(events)")
        // "a" is already taken by the sweeper (sorted acquisition: a, then b
        // blocks), so a single-lock caller for "a" queues behind it …
        let aCaller = Task { await locks.withLock("a") { await log.record("a-ran") } }
        try await Task.sleep(for: .milliseconds(100))
        events = await log.events
        XCTAssertFalse(events.contains("a-ran"), "\(events)")

        await release.open()
        await holder.value
        await sweeper.value
        await aCaller.value
        events = await log.events
        XCTAssertEqual(events.firstIndex(of: "b-released")! < events.firstIndex(of: "all-held")!, true, "\(events)")
        XCTAssertEqual(events.firstIndex(of: "all-held")! < events.firstIndex(of: "a-ran")!, true, "\(events)")
        // … and every name is free again afterwards.
        let free = await locks.withLocks(["a", "b", "c"]) { true }
        XCTAssertTrue(free)
    }

    func testWithLocksReleasesEveryNameWhenTheBodyThrows() async throws {
        struct Boom: Error {}
        let locks = VolumeLocks()
        do {
            try await locks.withLocks(["p", "q"]) { throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {}
        let p = await locks.withLock("p") { true }
        let q = await locks.withLock("q") { true }
        XCTAssertTrue(p && q)
        let none = await locks.withLocks([]) { true }
        XCTAssertTrue(none, "an empty set is a plain call")
    }
}

private actor EventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func waitFor(_ event: String) async {
        while !events.contains(event) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
