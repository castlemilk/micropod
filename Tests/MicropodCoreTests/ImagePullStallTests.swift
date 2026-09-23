import Foundation
import XCTest

@testable import MicropodCore

/// Pull-stall watchdog: the runtime can wedge mid-fetch emitting only
/// elapsed-time ticker lines — Micropod must bound that to an error and
/// recover by clearing the stored registry credential.
final class ImagePullStallTests: XCTestCase {

    // MARK: - stallMarker

    func testStallMarkerStripsElapsedTicker() {
        XCTAssertEqual(
            ImageService.stallMarker("[1/2] Fetching image [5s]"),
            ImageService.stallMarker("[1/2] Fetching image [12s]"))
    }

    func testStallMarkerStripsTransferRate() {
        // Same bytes, different rate display → same marker (no progress).
        XCTAssertEqual(
            ImageService.stallMarker(
                "[1/2] Fetching image 48% (13 of 21 blobs, 17.0/34.9 MB, 12.8 MB/s) [7s]"),
            ImageService.stallMarker(
                "[1/2] Fetching image 48% (13 of 21 blobs, 17.0/34.9 MB, 9.1 MB/s) [9s]"))
    }

    func testStallMarkerStripsWordRate() {
        // The CLI prints "Zero KB/s" (a word) when a transfer is frozen —
        // that must still collapse to the same marker as a live rate.
        XCTAssertEqual(
            ImageService.stallMarker(
                "[2/2] Unpacking image for platform linux/arm64 100% (514 of 514 entries, 8.3/8.3 MB, 39 KB/s) [23s]"),
            ImageService.stallMarker(
                "[2/2] Unpacking image for platform linux/arm64 100% (514 of 514 entries, 8.3/8.3 MB, Zero KB/s) [24s]")
        )
    }

    func testStallMarkerDetectsRealProgress() {
        XCTAssertNotEqual(
            ImageService.stallMarker(
                "[1/2] Fetching image 48% (13 of 21 blobs, 17.0/34.9 MB, 12.8 MB/s) [7s]"),
            ImageService.stallMarker(
                "[1/2] Fetching image 70% (16 of 21 blobs, 24.7/34.9 MB, 9.5 MB/s) [8s]"))
    }

    // MARK: - registryHost

    func testRegistryHostExplicit() {
        XCTAssertEqual(
            ImageService.registryHost(of: "cuttlefish-registry.benebsworth.com/pipeline/x:1.0"),
            "cuttlefish-registry.benebsworth.com")
        XCTAssertEqual(
            ImageService.registryHost(of: "localhost:5000/img:tag"), "localhost:5000")
        XCTAssertEqual(ImageService.registryHost(of: "localhost/img"), "localhost")
    }

    func testRegistryHostImplicitDockerIO() {
        XCTAssertEqual(
            ImageService.registryHost(of: "alpine:latest"), "registry-1.docker.io")
        XCTAssertEqual(
            ImageService.registryHost(of: "user/repo:1.0"), "registry-1.docker.io")
    }

    func testRegistryHostStripsDigest() {
        XCTAssertEqual(
            ImageService.registryHost(
                of: "ghcr.io/org/img@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "ghcr.io")
    }

    // MARK: - end-to-end stall recovery

    /// A fixture `container` CLI that wedges the pull (ticker lines, no
    /// progress) until `registry logout` has run — mimicking the stored-
    /// credential deadlock — then succeeds.
    func testStalledPullClearsCredentialAndRetries() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logoutMarker = dir.appendingPathComponent("logged-out").path

        let script = """
            #!/bin/bash
            case "$1 $2" in
              "image pull")
                if [ -f "\(logoutMarker)" ]; then
                  echo "[1/2] Fetching image 100% (1 of 1 blobs, 1.0/1.0 MB, 1.0 MB/s)"
                  echo "[2/2] Unpacking image 100% (1 of 1 entries, 1.0 MB)"
                  exit 0
                fi
                for i in $(seq 1 300); do
                  echo "[1/2] Fetching image [${i}s]"
                  sleep 1
                done
                ;;
              "registry list")
                echo '[{"name":"wedged.local","username":"x"}]'
                ;;
              "registry logout")
                touch "\(logoutMarker)"
                exit 0
                ;;
              *) exit 0 ;;
            esac
            """
        let exe = dir.appendingPathComponent("container")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        setenv("MICROPOD_PULL_STALL_TIMEOUT", "1", 1)
        defer { unsetenv("MICROPOD_PULL_STALL_TIMEOUT") }

        let service = ImageService(client: ContainerCLIClient(executableURL: exe))
        var events: [ProgressEvent] = []
        for try await event in service.pull("wedged.local/img:1.0") {
            events.append(event)
        }
        // Recovery path: logout marker created, retry succeeded.
        XCTAssertTrue(FileManager.default.fileExists(atPath: logoutMarker))
        XCTAssertTrue(events.contains { $0.line.contains("Fetching image") })
    }

    /// When the registry has no stored credential, a stall surfaces as
    /// `pullStalled` — bounded failure, no hang, no bogus logout.
    func testStalledPullWithoutCredentialFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logoutMarker = dir.appendingPathComponent("logged-out").path

        let script = """
            #!/bin/bash
            case "$1 $2" in
              "image pull")
                for i in $(seq 1 300); do
                  echo "[1/2] Fetching image [${i}s]"
                  sleep 1
                done
                ;;
              "registry list") echo '[]' ;;
              "registry logout") touch "\(logoutMarker)" ;;
              *) exit 0 ;;
            esac
            """
        let exe = dir.appendingPathComponent("container")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        setenv("MICROPOD_PULL_STALL_TIMEOUT", "1", 1)
        defer { unsetenv("MICROPOD_PULL_STALL_TIMEOUT") }

        let service = ImageService(client: ContainerCLIClient(executableURL: exe))
        do {
            for try await _ in service.pull("wedged.local/img:1.0") {}
            XCTFail("expected pullStalled")
        } catch MicropodError.pullStalled(let reference) {
            XCTAssertEqual(reference, "wedged.local/img:1.0")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: logoutMarker))
    }
}
