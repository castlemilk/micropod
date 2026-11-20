import XCTest

@testable import MicropodCLI

final class CICommandsTests: XCTestCase {
    func testWorkerWideVolumesKeepTheirNamesAndCopyUp() throws {
        let flags = try CICommands.runArguments(["--cache", "go", "--cache", "go", "--cache", "npm", "builder"])
        XCTAssertEqual(flags.filter { $0 == "--mount" }.count, 3)
        for store in ["npm", "gomod", "gobuild"] {
            XCTAssertTrue(flags.contains("type=volume,src=micropod-ci-\(store),dst=/cache/\(store)"))
        }
    }

    func testScopedJobsReuseOnlyRequestedStoresAndPreserveDockerArguments() throws {
        let job = ["--user", "1000", "node", "echo", "--cache-scope", "literal", "--cache", "go"]
        let flags = try CICommands.runArguments(ArraySlice(["--cache", "npm", "--cache-scope", "team-1"] + job))
        XCTAssertEqual(
            flags,
            [
                "--mount", "type=volume,src=micropod-ci-scoped-team-1-npm,dst=/cache/npm,volume-nocopy",
                "-e", "npm_config_cache=/cache/npm",
            ] + job)
        XCTAssertEqual(try CICommands.runArguments(ArraySlice(job)), job)
    }

    func testScratchIsSizedAndPythonBytecodeIsScoped() throws {
        let argv = try CICommands.runArguments([
            "--scratch-mib", "128", "--cache", "python", "--cache-scope", "pinned", "build",
        ])
        XCTAssertTrue(argv.contains("/tmp:rw,exec,nosuid,nodev,size=128m,mode=1777"))
        XCTAssertTrue(
            argv.contains("type=volume,src=micropod-ci-scoped-pinned-pycache,dst=/cache/pycache,volume-nocopy"))
        XCTAssertTrue(argv.contains("PYTHONPYCACHEPREFIX=/cache/pycache"))
        XCTAssertEqual(
            try CICommands.runArguments(["image", "--scratch-mib", "bad"]), ["image", "--scratch-mib", "bad"])
    }

    func testSnapshotUsesTheWorkerBuilderAndLocalCheckout() throws {
        let directory = FileManager.default.temporaryDirectory
        let args = try CICommands.snapshotArguments(["toolchain:ci", directory.path])
        XCTAssertEqual(Array(args.prefix(4)), ["buildx", "build", "--builder", "default"])
        XCTAssertTrue(args.contains("--load"))
        XCTAssertTrue(args.contains("BASE_IMAGE=toolchain:ci"))
        XCTAssertEqual(args.last, directory.standardizedFileURL.path)
        XCTAssertTrue(CICommands.snapshotDockerfile.contains("COPY . /workspace/"))
        for invalid in [[], ["-"], ["image\nFROM other"], ["image", "/missing-setup-\(UUID())"], ["a", ".", "."]] {
            XCTAssertThrowsError(try CICommands.snapshotArguments(ArraySlice(invalid)))
        }
    }

    func testGoWarmUsesThePinnedImageAndTheJobsOwnCacheVolumes() throws {
        let image = "sha256:" + String(repeating: "a", count: 64)
        let base = ["--cache-scope", "team"]
        let args = try CICommands.warmGoArguments(
            ArraySlice(base + ["--offline", "--trace-tools", image, "./cmd/..."]))
        XCTAssertEqual(Array(args.prefix(2)), ["run", "--rm"])
        XCTAssertTrue(args.contains("type=volume,src=micropod-ci-scoped-team-gomod,dst=/cache/gomod,volume-nocopy"))
        XCTAssertTrue(args.contains("type=volume,src=micropod-ci-scoped-team-gobuild,dst=/cache/gobuild,volume-nocopy"))
        XCTAssertTrue(args.contains("--pull=never"))
        XCTAssertTrue(args.contains("none"))
        XCTAssertTrue(args.contains(image))
        XCTAssertEqual(Array(args.suffix(2)), ["1", "./cmd/..."])
        let defaults = try CICommands.warmGoArguments(ArraySlice(base + [image]))
        XCTAssertEqual(Array(defaults.suffix(2)), ["0", "./..."])
        for invalid in [
            base + ["floating:latest"], ["--cache-scope", "../tenant", image], base + [image, "-exec=x"],
            base + ["--offline", "--offline", image], [image],
        ] {
            XCTAssertThrowsError(try CICommands.warmGoArguments(ArraySlice(invalid)))
        }
    }

    func testInvalidCachePrefixFailsBeforeStartingAWorker() {
        for args in [
            ["--scratch-mib", "0", "alpine"], ["--scratch-mib", "1", "--scratch-mib", "2", "alpine"],
            ["--cache", "python", "alpine"], ["--cache-scope", "team", "alpine"], ["--cache", "go"],
            ["--cache", "unknown", "alpine"],
            ["--cache", "npm", "--cache-scope", "../other", "alpine"],
            ["--cache", "npm", "--cache-scope", "x,dst=/elsewhere", "alpine"],
            ["--cache", "npm", "--cache-scope", "one", "--cache-scope", "two", "alpine"],
        ] {
            XCTAssertThrowsError(try CICommands.runArguments(ArraySlice(args)), "\(args)")
        }
    }
}
