import XCTest

@testable import MicropodRuntime

/// Pure-logic coverage for `SandboxVM` — no VM boots here. The live boot
/// path is exercised by `scripts/bench_runtimes.py`.
final class SandboxVMTests: XCTestCase {
    func testMergeEnvOverridesByKey() {
        let merged = SandboxVM.mergeEnv(["PATH=/bin", "A=1"], ["A=2", "B=3"])
        XCTAssertEqual(merged, ["PATH=/bin", "A=2", "B=3"])
    }

    func testMergeEnvBareKeyCopiesHostValue() {
        let merged = SandboxVM.mergeEnv([], ["HOME", "MICROPOD_SANDBOX_DEFINITELY_UNSET"])
        XCTAssertEqual(merged, ["HOME=\(NSHomeDirectory())"])
    }

    /// ro/rw shares never touch the run directory; only overlays clone into it.
    private let runDir = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-unused")

    func testShareMountParsesReadOnly() throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let ro = try SandboxVM.shareMount("\(tmp):/data:ro", runDir: runDir, index: 0)
        XCTAssertEqual(ro.destination, "/data")
        XCTAssertEqual(ro.options, ["ro"])
        XCTAssertEqual(ro.type, "virtiofs")
        XCTAssertEqual(try SandboxVM.shareMount("\(tmp):/data", runDir: runDir, index: 0).options, [])
        XCTAssertEqual(try SandboxVM.shareMount("\(tmp):/data:rw", runDir: runDir, index: 0).options, [])
    }

    func testShareMountRejectsBadSpecs() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertThrowsError(try SandboxVM.shareMount("\(tmp)", runDir: runDir, index: 0))
        XCTAssertThrowsError(try SandboxVM.shareMount("\(tmp):relative", runDir: runDir, index: 0))
        XCTAssertThrowsError(try SandboxVM.shareMount("\(tmp):/data:bogus", runDir: runDir, index: 0))
        XCTAssertThrowsError(try SandboxVM.shareMount("/no/such/dir/for/sandbox:/data", runDir: runDir, index: 0))
    }

    func testNormalizeDefaultsRegistryAndTag() throws {
        XCTAssertEqual(try SandboxVM.normalize("alpine"), "docker.io/library/alpine:latest")
        XCTAssertEqual(try SandboxVM.normalize("golang:1"), "docker.io/library/golang:1")
        XCTAssertEqual(try SandboxVM.normalize("ghcr.io/a/b:v1"), "ghcr.io/a/b:v1")
    }

    func testCheckpointNameValidation() {
        let disk = URL(fileURLWithPath: "/nonexistent.ext4")
        for bad in ["", "../escape", "a/b", "-flag", ".hidden"] {
            XCTAssertThrowsError(
                try SandboxVM.saveCheckpoint(name: bad, disk: disk, image: "x", diskBytes: 1),
                "expected '\(bad)' to be rejected")
        }
    }
}
