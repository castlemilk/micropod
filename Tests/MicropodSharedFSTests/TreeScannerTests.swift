import XCTest

@testable import MicropodSharedFS

final class TreeScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func testScanRecordsFilesAndDirectories() throws {
        try write("a.txt", "alpha")
        try write("pkg/b.txt", "bravo")

        let manifest = try TreeScanner().scan(root)

        XCTAssertEqual(manifest.entries["a.txt"]?.kind, .file)
        XCTAssertEqual(manifest.entries["pkg"]?.kind, .directory)
        XCTAssertEqual(manifest.entries["pkg/b.txt"]?.kind, .file)
        XCTAssertEqual(manifest.entries["a.txt"]?.size, 5)
    }

    /// `.git` churns on every command and would dominate every diff.
    func testGitDirectoryIsExcludedAtAnyDepth() throws {
        try write(".git/config", "[core]")
        try write("nested/.git/HEAD", "ref")
        try write("keep.txt")

        let manifest = try TreeScanner().scan(root)

        XCTAssertNil(manifest.entries[".git/config"])
        XCTAssertNil(manifest.entries["nested/.git/HEAD"])
        XCTAssertNotNil(manifest.entries["keep.txt"])
    }

    func testCustomExcludeIsHonored() throws {
        try write("target/big.o")
        try write("src/main.swift")

        let manifest = try TreeScanner(excludes: ["target"]).scan(root)

        XCTAssertNil(manifest.entries["target/big.o"])
        XCTAssertNotNil(manifest.entries["src/main.swift"])
    }

    /// A symlink must be recorded as a link, not followed — following it both
    /// duplicates content and can escape the tree entirely.
    func testSymlinkIsRecordedNotFollowed() throws {
        try write("real.txt", "payload")
        // Path API, not the URL one: URL(fileURLWithPath:) resolves a bare
        // name against the CWD, producing a link to a path that does not exist.
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link.txt").path,
            withDestinationPath: "real.txt")

        let manifest = try TreeScanner().scan(root)

        XCTAssertEqual(manifest.entries["link.txt"]?.kind, .symlink)
        XCTAssertNotEqual(
            manifest.entries["link.txt"]?.digest, manifest.entries["real.txt"]?.digest,
            "a symlink's digest is its target, not the target's contents")
    }

    func testIdenticalContentProducesIdenticalDigest() throws {
        try write("one.txt", "same")
        try write("two.txt", "same")

        let manifest = try TreeScanner().scan(root)

        XCTAssertEqual(manifest.entries["one.txt"]?.digest, manifest.entries["two.txt"]?.digest)
    }

    /// The reuse path is the whole reason a no-op sync is a stat walk. If the
    /// stat signature matches, the recorded digest must be carried over rather
    /// than recomputed.
    func testUnchangedFileReusesRecordedDigest() throws {
        try write("a.txt", "alpha")
        let first = try TreeScanner().scan(root)

        // Poison the recorded digest: if the scanner re-hashes, it will
        // disagree; if it reuses (as intended), the poison survives.
        var poisoned = first
        poisoned.entries["a.txt"]?.digest = String(repeating: "9", count: 64)

        let second = try TreeScanner().scan(root, reusing: poisoned)
        XCTAssertEqual(second.entries["a.txt"]?.digest, String(repeating: "9", count: 64))
    }

    func testAlwaysHashIgnoresRecordedDigest() throws {
        try write("a.txt", "alpha")
        let first = try TreeScanner().scan(root)
        var poisoned = first
        poisoned.entries["a.txt"]?.digest = String(repeating: "9", count: 64)

        let second = try TreeScanner(alwaysHash: true).scan(root, reusing: poisoned)
        XCTAssertEqual(second.entries["a.txt"]?.digest, first.entries["a.txt"]?.digest)
    }

    func testMissingSourceThrows() {
        let missing = root.appendingPathComponent("nope")
        XCTAssertThrowsError(try TreeScanner().scan(missing))
    }
}

final class FileManifestDiffTests: XCTestCase {
    private func entry(_ digest: String, kind: ManifestEntry.Kind = .file) -> ManifestEntry {
        ManifestEntry(kind: kind, size: 1, mtimeNanos: 0, digest: digest, mode: 0o644)
    }

    func testAddedFileIsChanged() {
        let previous = FileManifest(entries: ["a": entry("1")])
        let current = FileManifest(entries: ["a": entry("1"), "b": entry("2")])
        XCTAssertEqual(current.diff(against: previous).changed, ["b"])
    }

    func testModifiedFileIsChanged() {
        let previous = FileManifest(entries: ["a": entry("1")])
        let current = FileManifest(entries: ["a": entry("2")])
        XCTAssertEqual(current.diff(against: previous).changed, ["a"])
    }

    func testRemovedFileIsReported() {
        let previous = FileManifest(entries: ["a": entry("1"), "b": entry("2")])
        let current = FileManifest(entries: ["a": entry("1")])
        XCTAssertEqual(current.diff(against: previous).removed, ["b"])
    }

    /// A chmod changes nothing about content but everything about whether a
    /// script runs.
    func testModeChangeIsChanged() {
        let previous = FileManifest(entries: ["run.sh": entry("1")])
        var executable = entry("1")
        executable.mode = 0o755
        let current = FileManifest(entries: ["run.sh": executable])
        XCTAssertEqual(current.diff(against: previous).changed, ["run.sh"])
    }

    func testIdenticalManifestsProduceEmptyDiff() {
        let manifest = FileManifest(entries: ["a": entry("1"), "d": entry("", kind: .directory)])
        XCTAssertTrue(manifest.diff(against: manifest).isEmpty)
    }

    /// An unreadable or older-format history must ship everything rather than
    /// assume the volume already matches.
    func testStaleVersionForcesFullReship() {
        let previous = FileManifest(version: 0, entries: ["a": entry("1")])
        let current = FileManifest(entries: ["a": entry("1"), "b": entry("2")])
        let diff = current.diff(against: previous)
        XCTAssertEqual(diff.changed, ["a", "b"])
    }

    func testOutputIsSortedForReproducibility() {
        let previous = FileManifest()
        let current = FileManifest(
            entries: ["z": entry("1"), "a": entry("2"), "m": entry("3")])
        XCTAssertEqual(current.diff(against: previous).changed, ["a", "m", "z"])
    }

    func testNewDirectoryIsReportedSeparately() {
        let previous = FileManifest()
        let current = FileManifest(entries: ["empty": entry("", kind: .directory)])
        let diff = current.diff(against: previous)
        XCTAssertEqual(diff.directories, ["empty"])
        XCTAssertTrue(diff.changed.isEmpty, "a directory has no content to ship")
    }
}

final class ManifestStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRoundTrip() throws {
        let store = try ManifestStore(root: root)
        let source = URL(fileURLWithPath: "/tmp/src")
        let manifest = FileManifest(entries: [
            "a": ManifestEntry(kind: .file, size: 3, mtimeNanos: 7, digest: "d", mode: 0o644)
        ])
        try store.save(manifest, source: source, volume: "vol", destination: "/")
        XCTAssertEqual(store.load(source: source, volume: "vol", destination: "/"), manifest)
    }

    /// Sharing one history between volumes would make the second volume's
    /// first sync a no-op and leave it empty.
    func testKeyIsPerSourceVolumeAndDestination() throws {
        let store = try ManifestStore(root: root)
        let source = URL(fileURLWithPath: "/tmp/src")
        let a = store.url(source: source, volume: "one", destination: "/")
        let b = store.url(source: source, volume: "two", destination: "/")
        let c = store.url(source: source, volume: "one", destination: "/sub")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMissingManifestLoadsAsStale() throws {
        let store = try ManifestStore(root: root)
        let loaded = store.load(
            source: URL(fileURLWithPath: "/tmp/never"), volume: "vol", destination: "/")
        XCTAssertEqual(loaded.version, 0, "an absent history must force a full ship")
    }

    func testForgetRemovesHistory() throws {
        let store = try ManifestStore(root: root)
        let source = URL(fileURLWithPath: "/tmp/src")
        try store.save(FileManifest(), source: source, volume: "vol", destination: "/")
        try store.forget(source: source, volume: "vol", destination: "/")
        XCTAssertEqual(
            store.load(source: source, volume: "vol", destination: "/").version, 0)
    }
}
