import XCTest

@testable import MicropodCore

/// `container system status --format json` changed shape in 1.5.0 (flat →
/// nested `client`/`server`/`host`/`paths`/`resources`); both read the same.
final class SystemStatusShapesTests: XCTestCase {
    private func decode(_ json: String) throws -> SystemStatusResponse {
        try MicropodJSON.decode(SystemStatusResponse.self, from: Data(json.utf8), context: "test")
    }

    func testFlatShapeThrough1_4() throws {
        let response = try decode(
            """
            {"apiServerAppName":"container-apiserver","apiServerBuild":"release","apiServerCommit":"a9a62e2b17c0ab1db4e1a3a59d23a5bd59ad6ddb","apiServerVersion":"container-apiserver version 1.3.1 (build: release, commit: a9a62e2)","appRoot":"/Users/me/Library/Application Support/com.apple.container/","installRoot":"/usr/local/","logRoot":"/Users/me/Library/Application Support/com.apple.container/logs/","status":"running"}
            """)
        let mapped = ModelMapper.systemStatus(from: response, cliVersion: "1.3.1")
        XCTAssertEqual(mapped.status, "running")
        XCTAssertEqual(mapped.apiServerVersion, "container-apiserver version 1.3.1 (build: release, commit: a9a62e2)")
        XCTAssertEqual(mapped.appRoot, "/Users/me/Library/Application Support/com.apple.container/")
        XCTAssertEqual(mapped.installRoot, "/usr/local/")
    }

    /// `StatusPayload` from apple/container 1.5.0's SystemStatus.swift, with
    /// its unescaped slashes (1.4.1 stopped escaping them).
    func testNestedShapeFrom1_5() throws {
        let response = try decode(
            """
            {"client":{"appName":"container","build":"release","commit":"5c1e0e4","version":"1.5.0"},"host":{"architecture":"arm64","cpus":18,"operatingSystem":"Version 26.5.1 (Build 25F80)"},"paths":{"appRoot":"/Users/me/Library/Application Support/com.apple.container/","installRoot":"/usr/local/","logRoot":"/Users/me/Library/Application Support/com.apple.container/logs/"},"resources":{"containersRunning":2,"containersTotal":5,"images":12},"server":{"appName":"container-apiserver","build":"release","commit":"5c1e0e4","version":"1.5.0"},"status":"running"}
            """)
        let mapped = ModelMapper.systemStatus(from: response, cliVersion: "1.5.0")
        XCTAssertEqual(mapped.status, "running")
        XCTAssertEqual(mapped.apiServerVersion, "1.5.0")
        XCTAssertEqual(mapped.appRoot, "/Users/me/Library/Application Support/com.apple.container/")
        XCTAssertEqual(mapped.installRoot, "/usr/local/")
        XCTAssertEqual(mapped.cliVersion, "1.5.0")
    }

    /// A stopped or unregistered runtime prints `{"status": …}` alone.
    func testStoppedRuntimeInEitherShape() throws {
        for status in ["not running", "unregistered"] {
            let response = try decode(#"{"status":"\#(status)"}"#)
            XCTAssertEqual(response.status, status)
            XCTAssertNil(response.apiServerVersion)
            XCTAssertNil(response.appRoot)
        }
    }

    func testEncodesTheFlatShape() throws {
        let response = SystemStatusResponse(
            status: "running", appRoot: "/a/", installRoot: "/usr/local/", apiServerVersion: "1.5.0")
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(
            object, ["status": "running", "appRoot": "/a/", "installRoot": "/usr/local/", "apiServerVersion": "1.5.0"])
        XCTAssertEqual(try decode(String(decoding: data, as: UTF8.self)).apiServerVersion, "1.5.0")
    }

    /// Containerization 0.47 (Apple `container` 1.5.0) can report per-mount
    /// filesystem statistics; a stats entry carrying them still decodes.
    func testStatsEntryToleratesFilesystemStatistics() throws {
        let entry = try MicropodJSON.decode(
            ContainerStatsEntry.self,
            from: Data(
                """
                {"id":"web","cpuUsageUsec":1200,"memoryUsageBytes":4096,"memoryLimitBytes":8192,"numProcesses":3,"filesystem":[{"mountPoint":"/","blockSize":4096,"blocks":100,"freeBlocks":40,"inodes":10,"freeInodes":4}]}
                """.utf8), context: "test")
        XCTAssertEqual(entry.id, "web")
        XCTAssertEqual(entry.cpuUsageUsec, 1200)
        XCTAssertEqual(entry.numProcesses, 3)
    }
}
