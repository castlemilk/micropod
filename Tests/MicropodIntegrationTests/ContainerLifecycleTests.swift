import MicropodCore
import XCTest

final class ContainerLifecycleTests: XCTestCase {
    func testRunProducesListingWithMappedFields() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(
                name: "web",
                env: ["FOO=bar", "BAZ=qux"],
                ports: [PortSpec(hostPort: 8080, containerPort: 80)],
                volumes: ["myvol:/data"],
                labels: [LabelSpec(key: "app", value: "web")],
                cpus: 0.5,
                memory: "64M")
            XCTAssertFalse(id.isEmpty)

            let containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 1)
            let container = containers[0]
            XCTAssertEqual(container.id, id)
            XCTAssertEqual(container.state, "running")
            XCTAssertEqual(container.image, "nginx:1.27")
            XCTAssertEqual(container.resources.cpus, 0.5)
            XCTAssertEqual(container.resources.memoryBytes, 67_108_864)
            XCTAssertEqual(container.env, ["FOO=bar", "BAZ=qux"])
            XCTAssertEqual(container.labels["app"], "web")
            XCTAssertEqual(container.publishedPorts.count, 1)
            XCTAssertEqual(container.publishedPorts[0].hostPort, 8080)
            XCTAssertEqual(container.publishedPorts[0].containerPort, 80)
            XCTAssertEqual(container.publishedPorts[0].protocol, "tcp")
            XCTAssertEqual(container.mounts.count, 1)
            XCTAssertEqual(container.mounts[0].source, "myvol")
            XCTAssertEqual(container.mounts[0].destination, "/data")
            XCTAssertEqual(container.networks, ["default"])
            XCTAssertFalse(container.ipv4Address.isEmpty, "running container should have an IP")
        }
    }

    func testLifecycleStartStopKillDelete() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")

            try await mock.containers.stop(id)
            var containers = try await mock.containers.list()
            XCTAssertEqual(containers.first?.state, "stopped")

            try await mock.containers.start(id)
            containers = try await mock.containers.list()
            XCTAssertEqual(containers.first?.state, "running")

            try await mock.containers.kill(id)
            containers = try await mock.containers.list()
            XCTAssertEqual(containers.first?.state, "stopped", "real CLI reports stopped after kill")

            try await mock.containers.delete(id, force: true)
            containers = try await mock.containers.list()
            XCTAssertTrue(containers.isEmpty)
        }
    }

    func testStopAndDeleteByName() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")
            try await mock.containers.stop("web")
            var containers = try await mock.containers.list()
            XCTAssertEqual(containers.first?.state, "stopped")
            try await mock.containers.delete("web", force: true)
            containers = try await mock.containers.list()
            XCTAssertTrue(containers.isEmpty)
            _ = id
        }
    }

    func testStopAllThenDeleteAll() async throws {
        try await withMockServices { mock in
            for n in 1...3 {
                _ = try await mock.runContainer(name: "box\(n)")
            }
            var containers = try await mock.containers.list()
            XCTAssertEqual(containers.count, 3)

            try await mock.containers.stopAll()
            containers = try await mock.containers.list()
            XCTAssertTrue(containers.allSatisfy { $0.state == "stopped" })

            try await mock.containers.deleteAll(force: true)
            containers = try await mock.containers.list()
            XCTAssertTrue(containers.isEmpty)
        }
    }

    func testPruneRemovesOnlyStopped() async throws {
        try await withMockServices { mock in
            let keepID = try await mock.runContainer(name: "keep")
            let stale = try await mock.runContainer(name: "stale")
            try await mock.containers.stop(stale)

            let report = try await mock.containers.prune()
            XCTAssertFalse(report.isEmpty)

            let remaining = try await mock.containers.list()
            XCTAssertEqual(remaining.count, 1)
            XCTAssertEqual(remaining[0].id, keepID)
        }
    }

    func testInspectReturnsContainerJSON() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")
            let data = try await mock.containers.inspect(id)
            let json = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(json.contains(id))
            XCTAssertTrue(json.contains("nginx:1.27"))
        }
    }

    func testExecReturnsOutput() async throws {
        try await withMockServices { mock in
            _ = try await mock.runContainer(name: "web")
            let output = try await mock.containers.exec(
                ContainerExecRequest(containerID: "web", arguments: ["echo", "hi"]))
            XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        }
    }

    func testExportWritesTarball() async throws {
        try await withMockServices { mock in
            let id = try await mock.runContainer(name: "web")
            let output = mock.stateDir.appendingPathComponent("export.tar")
            try await mock.containers.export(id, to: output.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCopyCreatesDestination() async throws {
        try await withMockServices { mock in
            _ = try await mock.runContainer(name: "web")
            let destination = mock.stateDir.appendingPathComponent("copied.txt")
            try await mock.containers.copy(from: "web:/etc/hosts", to: destination.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testUnknownContainerThrowsCLIError() async throws {
        try await withMockServices { mock in
            do {
                try await mock.containers.stop("does-not-exist")
                XCTFail("expected stop to throw")
            } catch let error as MicropodError {
                guard case .cliFailure(let command, let exitCode, let stderr) = error else {
                    return XCTFail("expected cliFailure, got \(error)")
                }
                XCTAssertEqual(exitCode, 1)
                XCTAssertTrue(command.contains("stop"))
                XCTAssertTrue(stderr.contains("no such container"))
            }
        }
    }
}
