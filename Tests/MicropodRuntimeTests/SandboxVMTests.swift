import XCTest

@testable import MicropodRuntime

/// Pure-logic coverage for `SandboxVM` — no VM boots here. The live boot
/// path is exercised by `scripts/bench_sandbox.py`.
final class SandboxVMTests: XCTestCase {
    func testMergeEnvOverridesByKey() {
        let merged = SandboxVM.mergeEnv(["PATH=/bin", "A=1"], ["A=2", "B=3"])
        XCTAssertEqual(merged, ["PATH=/bin", "A=2", "B=3"])
    }

    func testMergeEnvBareKeyCopiesHostValue() {
        let merged = SandboxVM.mergeEnv([], ["HOME", "MICROPOD_SANDBOX_DEFINITELY_UNSET"])
        XCTAssertEqual(merged, ["HOME=\(NSHomeDirectory())"])
    }

    func testShareMountParsesReadOnly() throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let ro = try SandboxVM.shareMount("\(tmp):/data:ro")
        XCTAssertEqual(ro.destination, "/data")
        XCTAssertEqual(ro.options, ["ro"])
        XCTAssertEqual(ro.type, "virtiofs")
        XCTAssertEqual(try SandboxVM.shareMount("\(tmp):/data").options, [])
        XCTAssertEqual(try SandboxVM.shareMount("\(tmp):/data:rw").options, [])
    }

    func testShareMountRejectsBadSpecs() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertThrowsError(try SandboxVM.shareMount("\(tmp)"))
        XCTAssertThrowsError(try SandboxVM.shareMount("\(tmp):relative"))
        XCTAssertThrowsError(try SandboxVM.shareMount("\(tmp):/data:bogus"))
        XCTAssertThrowsError(try SandboxVM.shareMount("/no/such/dir/for/sandbox:/data"))
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
