import Foundation
import XCTest

@testable import MicropodCore

/// Pull platform default: a pull with no platform fetches only
/// `linux/<host arch>` — the platform CreateContainer defaults to — instead
/// of every platform in the index. An image that has no host variant still
/// pulls as it did before the default existed.
final class ImagePullPlatformTests: XCTestCase {
    #if arch(arm64)
        private let host = "linux/arm64"
    #else
        private let host = "linux/amd64"
    #endif

    /// How the scripted CLI answers `image pull`.
    private enum Registry: String {
        /// Every pull succeeds.
        case multiArch
        /// A single-manifest amd64 image: containerization's import refuses
        /// any `--platform` it does not match; an unset pull succeeds.
        case singleManifestForeign
        /// An index with no entry for the requested platform: the fetch
        /// succeeds, then the unpack for that platform fails.
        case indexWithoutPlatform
        /// The reference does not exist, whatever the platform.
        case missing
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pull-platform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A fixture `container` CLI that records each argv, one line per call,
    /// and answers `image pull` the way the real runtime does for `registry`
    /// (error texts are containerization 0.42.0's, as `container` prints them).
    private func service(_ registry: Registry) throws -> ImageService {
        let log = dir.appendingPathComponent("calls.log").path
        let script = """
            #!/bin/bash
            echo "$*" >> "\(log)"
            [ "$1 $2" = "image pull" ] || exit 0
            pinned=""
            for arg in "$@"; do [ "$arg" = "--platform" ] && pinned=1; done
            case "\(registry.rawValue)" in
              singleManifestForeign)
                if [ -n "$pinned" ]; then
                  echo '[1/2] Fetching image 100% (3 of 3 blobs, 1.9/1.9 MB)'
                  echo 'Error: unsupported: "image sha256:1111 does not support required platforms"' >&2
                  exit 1
                fi ;;
              indexWithoutPlatform)
                if [ -n "$pinned" ]; then
                  echo '[1/2] Fetching image 100% (1 of 1 blobs, 1.6/1.6 KB)'
                  echo 'Error: invalidArgument: "unsupported platform linux/arm64"' >&2
                  exit 1
                fi ;;
              missing)
                echo 'Error: notFound: "no such image"' >&2
                exit 1 ;;
            esac
            echo '[1/2] Fetching image 100% (4 of 4 blobs, 1.9/1.9 MB)'
            echo '[2/2] Unpacking image 100% (442 of 442 entries, 3.9 MB)'
            exit 0
            """
        let exe = dir.appendingPathComponent("container")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return ImageService(client: ContainerCLIClient(executableURL: exe))
    }

    private func pulls() -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("image pull ") }
    }

    private func drain(_ stream: AsyncThrowingStream<ProgressEvent, Error>) async throws -> [String] {
        var lines: [String] = []
        for try await event in stream { lines.append(event.line) }
        return lines
    }

    // MARK: - argv

    func testUnsetPlatformPinsHostPlatform() async throws {
        _ = try await drain(try service(.multiArch).pull("busybox:1.36.1"))
        let calls = pulls()
        guard calls.count == 1 else { return XCTFail("expected one pull: \(calls)") }
        XCTAssertTrue(calls[0].contains(" --platform \(host) "), calls[0])
        XCTAssertTrue(calls[0].hasSuffix(" busybox:1.36.1"), calls[0])
    }

    func testEmptyPlatformPinsHostPlatform() async throws {
        _ = try await drain(try service(.multiArch).pull("busybox:1.36.1", platform: ""))
        let calls = pulls()
        guard calls.count == 1 else { return XCTFail("expected one pull: \(calls)") }
        XCTAssertTrue(calls[0].contains(" --platform \(host) "), calls[0])
    }

    func testGivenPlatformIsPassedVerbatim() async throws {
        _ = try await drain(try service(.multiArch).pull("busybox:1.36.1", platform: "linux/amd64"))
        let calls = pulls()
        guard calls.count == 1 else { return XCTFail("expected one pull: \(calls)") }
        XCTAssertTrue(calls[0].contains(" --platform linux/amd64 "), calls[0])
        XCTAssertEqual(calls[0].components(separatedBy: "--platform").count, 2, calls[0])
    }

    // MARK: - images with no host variant

    /// A single-manifest foreign image refuses the pinned pull; the pull is
    /// retried once with no platform, which is what succeeded before.
    func testSingleManifestForeignImageFallsBackToUnsetPlatform() async throws {
        let lines = try await drain(try service(.singleManifestForeign).pull("amd64only:1"))
        let calls = pulls()
        guard calls.count == 2 else { return XCTFail("expected a pinned pull and one retry: \(calls)") }
        XCTAssertTrue(calls[0].contains(" --platform \(host) "), calls[0])
        XCTAssertFalse(calls[1].contains("--platform"), calls[1])
        XCTAssertTrue(calls[1].hasSuffix(" amd64only:1"), calls[1])
        XCTAssertTrue(lines.contains { $0.contains("no \(host) variant") }, "\(lines)")
        XCTAssertTrue(lines.last?.contains("Unpacking image 100%") == true, "\(lines)")
    }

    /// An index with no host entry fails at unpack; same single retry.
    func testIndexWithoutHostVariantFallsBackToUnsetPlatform() async throws {
        _ = try await drain(try service(.indexWithoutPlatform).pull("amd64index:1"))
        let calls = pulls()
        guard calls.count == 2 else { return XCTFail("expected a pinned pull and one retry: \(calls)") }
        XCTAssertTrue(calls[0].contains(" --platform \(host) "), calls[0])
        XCTAssertFalse(calls[1].contains("--platform"), calls[1])
    }

    /// A platform the caller asked for is never widened.
    func testGivenPlatformMismatchIsNotRetried() async throws {
        let images = try service(.singleManifestForeign)
        do {
            _ = try await drain(images.pull("amd64only:1", platform: "linux/arm64"))
            XCTFail("expected the pinned pull to fail")
        } catch MicropodError.cliFailure {}
        XCTAssertEqual(pulls().count, 1, "\(pulls())")
    }

    /// Only a missing platform widens the pull — any other failure is the
    /// caller's answer, after one attempt.
    func testOtherFailureUnderDefaultIsNotRetried() async throws {
        let images = try service(.missing)
        do {
            _ = try await drain(images.pull("ghost:1"))
            XCTFail("expected the pull to fail")
        } catch MicropodError.cliFailure {}
        XCTAssertEqual(pulls().count, 1, "\(pulls())")
    }
}
