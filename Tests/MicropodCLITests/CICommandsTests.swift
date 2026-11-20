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
