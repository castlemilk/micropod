import MicropodCore
import XCTest

@testable import MicropodRuntime

/// Wire-shape tests for the apiserver DTO layer — no live XPC needed.
final class RuntimeDTOTests: XCTestCase {

    // MARK: SnapshotTransform

    /// A `ContainerSnapshot` element as the apiserver encodes it (default
    /// JSONEncoder → dates are timeIntervalSinceReferenceDate numbers).
    private func snapshotJSON(id: String, state: String) -> String {
        """
        [{
          "configuration": {
            "id": "\(id)",
            "creationDate": 785000000.5,
            "image": {"reference": "docker.io/library/alpine:latest"},
            "labels": {"app": "test"},
            "initProcess": {
              "executable": "/bin/sleep",
              "arguments": ["30"],
              "environment": ["PATH=/usr/bin"],
              "workingDirectory": "/",
              "terminal": false,
              "user": {"id": {"uid": 0, "gid": 0}},
              "supplementalGroups": [],
              "rlimits": []
            }
          },
          "status": "\(state)",
          "networks": [{"network": "default", "options": {"hostname": "c1"}}],
          "startedDate": 785000001.0
        }]
        """
    }

    func testSnapshotToManagedDecodesAsListEntry() throws {
        let snapshots = Data(snapshotJSON(id: "abc123", state: "running").utf8)
        let managed = try SnapshotTransform.toManagedArrayData(snapshots)
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: managed, context: "test")
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry.id, "abc123")
        XCTAssertEqual(entry.status.state, "running")
        XCTAssertEqual(entry.configuration.image?.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(entry.configuration.initProcess?.executable, "/bin/sleep")
        // creationDate must be an ISO string now (decodes String? cleanly).
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: managed) as? [[String: Any]])
        let config = try XCTUnwrap(obj[0]["configuration"] as? [String: Any])
        let created = try XCTUnwrap(config["creationDate"] as? String)
        XCTAssertTrue(created.hasPrefix("20"), "expected ISO date, got \(created)")
        let status = try XCTUnwrap(obj[0]["status"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "running")
        XCTAssertNotNil(status["networks"])
        XCTAssertNotNil(status["startedDate"])
    }

    func testSnapshotTransformPreservesStoppedState() throws {
        let snapshots = Data(snapshotJSON(id: "zzz", state: "stopped").utf8)
        let managed = try SnapshotTransform.toManagedArrayData(snapshots)
        let entries = try MicropodJSON.decodeArray(
            ContainerListEntry.self, from: managed, context: "test")
        XCTAssertEqual(entries.first?.status.state, "stopped")
    }

    // MARK: ProcessConfigPatch

    private func managedJSON() throws -> JSONValue {
        let data = Data(
            """
            {
              "id": "abc123",
              "configuration": {
                "initProcess": {
                  "executable": "/bin/sleep",
                  "arguments": ["30"],
                  "environment": ["PATH=/usr/bin", "TERM=xterm"],
                  "workingDirectory": "/",
                  "terminal": false,
                  "user": {"id": {"uid": 0, "gid": 0}},
                  "supplementalGroups": [10, 20],
                  "rlimits": [{"limit": "RLIMIT_NOFILE", "soft": 1024, "hard": 4096}]
                }
              }
            }
            """.utf8)
        return try MicropodJSON.decoder.decode(JSONValue.self, from: data)
    }

    func testPatchExecFieldsAndPreservesRest() throws {
        let patched = try ProcessConfigPatch.patch(
            managedJSON: try managedJSON(),
            executable: "/bin/echo",
            arguments: ["hello"],
            appendEnvironment: ["FOO=bar"],
            workingDirectory: "/tmp",
            terminal: false
        )
        guard case .object(let obj) = patched else { return XCTFail("not object") }
        XCTAssertEqual(obj["executable"], .string("/bin/echo"))
        XCTAssertEqual(obj["arguments"], .array([.string("hello")]))
        XCTAssertEqual(obj["workingDirectory"], .string("/tmp"))
        XCTAssertEqual(
            obj["environment"],
            .array([.string("PATH=/usr/bin"), .string("TERM=xterm"), .string("FOO=bar")]))
        // Untouched fields round-trip verbatim.
        XCTAssertEqual(
            obj["supplementalGroups"], .array([.number(10), .number(20)]))
        XCTAssertEqual(
            obj["rlimits"],
            .array([
                .object([
                    "limit": .string("RLIMIT_NOFILE"),
                    "soft": .number(1024),
                    "hard": .number(4096),
                ])
            ]))
        XCTAssertEqual(
            obj["user"], .object(["id": .object(["uid": .number(0), "gid": .number(0)])]))
    }

    func testPatchUserNumericAndNamed() {
        let numeric = ProcessConfigPatch.encodeUser("1000:100")
        XCTAssertEqual(
            numeric,
            .object(["id": .object(["uid": .number(1000), "gid": .number(100)])]))
        let named = ProcessConfigPatch.encodeUser("root")
        XCTAssertEqual(
            named, .object(["raw": .object(["userString": .string("root")])]))
    }

    func testPatchMissingInitProcessThrows() {
        XCTAssertThrowsError(
            try ProcessConfigPatch.patch(
                managedJSON: .object(["configuration": .object([:])]),
                executable: "/bin/echo", arguments: []))
    }

    // MARK: Wire request payloads

    func testListFiltersEncode() throws {
        let data = try JSONEncoder().encode(
            APIListFilters(ids: ["a", "b"], status: "running", labels: ["k": "v"]))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["ids"] as? [String], ["a", "b"])
        XCTAssertEqual(obj["status"] as? String, "running")
        XCTAssertEqual(obj["labels"] as? [String: String], ["k": "v"])
    }

    func testStopOptionsEncode() throws {
        let data = try JSONEncoder().encode(
            APIStopOptions(timeoutInSeconds: 10, signal: "TERM"))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["timeoutInSeconds"] as? Int, 10)
        XCTAssertEqual(obj["signal"] as? String, "TERM")
    }

    func testContainerStatsDecodeShape() throws {
        // Same field names as `container stats --format json`.
        let data = Data(
            """
            {
              "id": "c1",
              "memoryUsageBytes": 1234,
              "memoryLimitBytes": 1073741824,
              "cpuUsageUsec": 999,
              "networkRxBytes": 100,
              "networkTxBytes": 50,
              "blockReadBytes": 10,
              "blockWriteBytes": 20,
              "numProcesses": 3
            }
            """.utf8)
        let stats = try MicropodJSON.decode(
            APIContainerStats.self, from: data, context: "test")
        XCTAssertEqual(stats.id, "c1")
        XCTAssertEqual(stats.memoryUsageBytes, 1234)
        XCTAssertEqual(stats.cpuUsageUsec, 999)
        XCTAssertEqual(stats.numProcesses, 3)
    }

    // MARK: execDetailed default impl

    private struct FakeExec: ContainerServing {
        var output = ""
        var failure: MicropodError?

        func list() async throws -> [Micropod_V1_Container] { [] }
        func inspect(_ id: String) async throws -> Data { Data() }
        func create(_ request: ContainerRunRequest) async throws -> String { "" }
        func run(_ request: ContainerRunRequest) async throws -> String { "" }
        func exec(_ request: ContainerExecRequest) async throws -> String {
            if let failure { throw failure }
            return output
        }
        func start(_ id: String) async throws {}
        func stop(_ id: String, timeout: Int) async throws {}
        func restart(_ id: String) async throws {}
        func stopAll() async throws {}
        func kill(_ id: String, signal: String) async throws {}
        func delete(_ id: String, force: Bool) async throws {}
        func deleteAll(force: Bool) async throws {}
        func prune() async throws -> String { "" }
        func export(_ id: String, to outputPath: String) async throws {}
        func copy(from: String, to: String) async throws {}
    }

    func testExecDetailedDefaultSuccess() async throws {
        var fake = FakeExec()
        fake.output = "ok"
        let res = try await fake.execDetailed(
            ContainerExecRequest(containerID: "c", arguments: ["true"]))
        XCTAssertEqual(res.output, "ok")
        XCTAssertEqual(res.exitCode, 0)
    }

    func testExecDetailedDefaultRecoverExitCode() async throws {
        var fake = FakeExec()
        fake.failure = .cliFailure(command: "exec", exitCode: 42, stderr: "boom")
        let res = try await fake.execDetailed(
            ContainerExecRequest(containerID: "c", arguments: ["false"]))
        XCTAssertEqual(res.exitCode, 42)
        XCTAssertTrue(res.error.contains("boom"))
    }
}
