import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class DockerExecTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/mp-exec-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testDetachedHVFExecReturnsLaunchSuccessForAnAlreadyExitedProcess() async throws {
        let engine = HVFEngine(root: root)
        let layout = engine.machine.layout
        try HVFMachineState(phase: .running, supervisorPID: getpid()).save(to: layout.state)
        let lock = try XCTUnwrap(HVFFileLock.acquire(layout.supervisorLock, wait: .zero))
        defer { lock.release() }
        let server = try DockerExecFixture(
            path: layout.dockerSocket.path, startReply: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))

        let result = try await engine.execDetailed(
            ContainerExecRequest(
                containerID: "web", arguments: ["sh", "-c", "exit 37"], detach: true,
                workdir: "/work", env: ["CI=1"]))

        XCTAssertEqual(result, ContainerExecResult(output: "", error: "", exitCode: 0))
        let requests = try server.requests()
        XCTAssertEqual(
            requests.map(\.line),
            [
                "POST /v1.44/containers/web/exec HTTP/1.1", "POST /v1.44/exec/exec-fixture/start HTTP/1.1",
            ])
        let create = try XCTUnwrap(requests.first).json()
        XCTAssertEqual(create["Cmd"] as? [String], ["sh", "-c", "exit 37"])
        XCTAssertEqual(create["Env"] as? [String], ["CI=1"])
        XCTAssertEqual(create["WorkingDir"] as? String, "/work")
        XCTAssertEqual(create["AttachStdin"] as? Bool, false)
        XCTAssertEqual(create["AttachStdout"] as? Bool, false)
        XCTAssertEqual(create["AttachStderr"] as? Bool, false)
        let start = try XCTUnwrap(requests.last).json()
        XCTAssertEqual(start["Detach"] as? Bool, true)
        XCTAssertEqual(start["Tty"] as? Bool, false)

        // The fixture finishes before acknowledging start. An explicit inspection
        // can still read its exit code after the adapter has returned success.
        let inspection = try await engine.machine.docker.request("GET", "/exec/exec-fixture/json")
        XCTAssertEqual((try inspection.json() as? [String: Any])?["ExitCode"] as? Int, 37)
    }

    func testDetachedDockerExecAcceptsJSONAcknowledgement() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let server = try DockerExecFixture(path: path, startReply: DockerExecFixture.json("200 OK", "{}"))
        let result = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).exec(
            ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true))
        XCTAssertEqual(result, "")
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testDetachedExecPropagatesStartRejectionFromAnOlderGuest() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply = DockerExecFixture.json("400 Bad Request", #"{"message":"unsupported Docker option Detach"}"#)
        let server = try DockerExecFixture(path: path, startReply: reply)

        do {
            _ = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).exec(
                ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true))
            XCTFail("A rejected start must throw")
        } catch {
            XCTAssertEqual(ConnectCodeMapping.code(for: error), "invalid_argument")
            XCTAssertTrue(error.localizedDescription.contains("unsupported Docker option Detach"))
        }
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testDetachedExecRejectsAttachedResponsesWithoutWaitingForEOF() async throws {
        let replies = [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: Application/Vnd.Docker.Multiplexed-Stream; charset=binary\r\n\r\n",
        ]
        for (index, reply) in replies.enumerated() {
            let path = root.appendingPathComponent("docker-\(index).sock").path
            let server = try DockerExecFixture(path: path, startReply: Data(reply.utf8), holdStartOpen: true)
            do {
                _ = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).exec(
                    ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true))
                XCTFail("An attached stream must not be treated as a detached start")
            } catch {
                XCTAssertEqual(ConnectCodeMapping.code(for: error), "unimplemented")
                XCTAssertTrue(error.localizedDescription.contains("returned an attached stream"))
            }
            XCTAssertTrue(server.clientClosedStart, "The adapter should close the connection after the headers")
            XCTAssertEqual(try server.requests().count, 2)
        }
    }

    func testAttachedExecStillCollectsBothStreamsAndInspectsTheExitCode() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply =
            Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
            + Data([1, 0, 0, 0, 0, 0, 0, 3]) + Data("out".utf8)
            + Data([2, 0, 0, 0, 0, 0, 0, 4]) + Data("err\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: reply)

        let result = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execDetailed(
            ContainerExecRequest(containerID: "web", arguments: ["sh"]))

        XCTAssertEqual(result, ContainerExecResult(output: "out", error: "err\n", exitCode: 37))
        let requests = try server.requests()
        XCTAssertEqual(
            requests.map(\.line),
            [
                "POST /v1.43/containers/web/exec HTTP/1.1", "POST /v1.43/exec/exec-fixture/start HTTP/1.1",
                "GET /v1.43/exec/exec-fixture/json HTTP/1.1",
            ])
        let create = try XCTUnwrap(requests.first).json()
        XCTAssertEqual(create["AttachStdin"] as? Bool, false)
        XCTAssertEqual(create["AttachStdout"] as? Bool, true)
        XCTAssertEqual(create["AttachStderr"] as? Bool, true)
    }

    func testTTYExecWritesUnframedBytesIncludingFrameLikePrefixes() async throws {
        let path = root.appendingPathComponent("tty.sock").path
        let bytes = Data([1, 0, 0, 0, 0, 0, 0, 1, 0xff, 0x0d, 0x0a, 0x00])
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8) + bytes
        let server = try DockerExecFixture(path: path, startReply: reply)
        let output = Pipe(), errors = Pipe()
        let rc = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.44"]).execAttached(
            ContainerExecRequest(containerID: "web", arguments: ["sh"], tty: true),
            stdin: .nullDevice, stdout: output.fileHandleForWriting, stderr: errors.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        XCTAssertEqual(rc, 37)
        XCTAssertEqual(try output.fileHandleForReading.readToEnd(), bytes)
        XCTAssertTrue((try errors.fileHandleForReading.readToEnd() ?? Data()).isEmpty)
        let calls = try server.requests()
        XCTAssertEqual(try calls[0].json()["Tty"] as? Bool, true)
        XCTAssertEqual(try calls[0].json()["AttachStdin"] as? Bool, false)
        XCTAssertEqual(try calls[1].json()["Tty"] as? Bool, true)
    }

    func testInteractiveTTYRejectsPipedInputBeforeCreatingAnExec() async throws {
        let path = root.appendingPathComponent("tty.sock").path
        let server = try DockerExecFixture(path: path, startReply: Data())
        let input = Pipe()
        do {
            _ = try await DockerEngine(endpoint: path, environment: [:]).execAttached(
                ContainerExecRequest(containerID: "web", arguments: ["sh"], interactive: true, tty: true),
                stdin: input.fileHandleForReading, stdout: .nullDevice, stderr: .nullDevice)
            XCTFail("Expected a terminal error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("terminal on stdin"))
        }
        XCTAssertTrue(try server.requests().isEmpty)
    }

    func testRawTerminalRestoresAllLocalFlagsAfterAnError() throws {
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { Darwin.close(master) }
        let terminal = try DockerExecTerminal(input: handle, output: handle)
        var before = termios(), during = termios(), after = termios()
        XCTAssertEqual(tcgetattr(slave, &before), 0)
        XCTAssertThrowsError(try terminal.withRawInput {
            XCTAssertEqual(tcgetattr(slave, &during), 0)
            XCTAssertEqual(during.c_lflag & tcflag_t(ICANON | ECHO | ISIG), 0)
            XCTAssertEqual(during.c_oflag & tcflag_t(OPOST), 0)
            var typed: UInt8 = 0x78
            XCTAssertEqual(Darwin.write(master, &typed, 1), 1)
            throw POSIXError(.ECANCELED)
        })
        // Canonical input on Darwin reprocesses the pending character on the
        // next input. Verify it survives the restore before comparing settings.
        var newline: UInt8 = 0x0a
        XCTAssertEqual(Darwin.write(master, &newline, 1), 1)
        var event = pollfd(fd: slave, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&event, 1, 1000), 1)
        if event.revents & Int16(POLLIN) != 0 {
            var line = [UInt8](repeating: 0, count: 2)
            XCTAssertEqual(Darwin.read(slave, &line, line.count), 2)
            XCTAssertEqual(line, [0x78, 0x0a])
        }
        XCTAssertEqual(tcgetattr(slave, &after), 0)
        XCTAssertEqual(before.c_iflag, after.c_iflag)
        XCTAssertEqual(before.c_oflag, after.c_oflag)
        XCTAssertEqual(before.c_cflag, after.c_cflag)
        XCTAssertEqual(before.c_lflag, after.c_lflag)
        XCTAssertEqual(cfgetispeed(&before), cfgetispeed(&after))
        XCTAssertEqual(cfgetospeed(&before), cfgetospeed(&after))
        XCTAssertEqual(withUnsafeBytes(of: before.c_cc) { Data($0) }, withUnsafeBytes(of: after.c_cc) { Data($0) })
    }

    func testPipedExecForwardsBinaryInputAndHalfClosesBeforeReadingFinalOutput() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let bytes = Data([0xff, 0x00, 0x80])
        let reply =
            Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
            + Data([2, 0, 0, 0, 0, 0, 0, 1, 0xa4])
        let server = try DockerExecFixture(
            path: path, startReply: reply,
            afterStart: { fd in
                let peer = FileHandle(fileDescriptor: fd)
                let received = try peer.readToEnd() ?? Data()
                guard received == bytes else { throw CocoaError(.fileReadCorruptFile) }
                try peer.write(contentsOf: Data([1, 0, 0, 0, 0, 0, 0, 3]) + received)
            })
        let input = Pipe(), output = Pipe(), errors = Pipe()
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        let code = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
            ContainerExecRequest(containerID: "web", arguments: ["cat"], interactive: true),
            stdin: input.fileHandleForReading, stdout: output.fileHandleForWriting, stderr: errors.fileHandleForWriting)
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        XCTAssertEqual(try output.fileHandleForReading.readToEnd(), bytes)
        XCTAssertEqual(try errors.fileHandleForReading.readToEnd(), Data([0xa4]))
        XCTAssertEqual(code, 37)
        let requests = try server.requests()
        XCTAssertEqual(try requests[0].json()["AttachStdin"] as? Bool, true)
        XCTAssertTrue(requests[1].headers.contains("Connection: Upgrade"))
        XCTAssertTrue(requests[1].headers.contains("Upgrade: tcp"))
    }

    func testPipedExecReturnsWhenGuestExitsWithStdinStillOpen() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: reply)
        let input = Pipe()
        // The timer also bounds a regression that waits for the caller to close stdin.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { try? input.fileHandleForWriting.close() }
        let start = ContinuousClock.now
        let code = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
            ContainerExecRequest(containerID: "web", arguments: ["true"], interactive: true),
            stdin: input.fileHandleForReading, stdout: .nullDevice, stderr: .nullDevice)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(code, 37)
        XCTAssertEqual(try server.requests().count, 3)
    }

    func testPipedExecReassemblesSplitFramesAcrossHTTPChunks() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        var response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
                .utf8)
        let frames = Data([1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 3, 0, 128, 255])
        for byte in frames { response += Data([49, 13, 10, byte, 13, 10]) }
        response += Data("0\r\nX-Note: complete\r\n\r\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: response)
        let errors = Pipe()
        let code = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
            ContainerExecRequest(containerID: "web", arguments: ["cat"]),
            stdin: .nullDevice, stdout: .nullDevice, stderr: errors.fileHandleForWriting)
        try errors.fileHandleForWriting.close()
        XCTAssertEqual(try errors.fileHandleForReading.readToEnd(), Data([0, 128, 255]))
        XCTAssertEqual(code, 37)
        XCTAssertEqual(try server.requests().count, 3)
    }

    func testUnterminatedChunkTrailersCannotReportSuccessfulExec() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: reply)
        do {
            _ = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
                ContainerExecRequest(containerID: "web", arguments: ["true"]),
                stdin: .nullDevice, stdout: .nullDevice, stderr: .nullDevice)
            XCTFail("Truncated final HTTP chunk returned success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("truncated HTTP"))
        }
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testCancellingAnAttachedExecClosesThePeerWithStdinOpen() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let started = expectation(description: "server started")
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
        let server = try DockerExecFixture(
            path: path, startReply: reply, holdStartOpen: true, afterStart: { _ in started.fulfill() })
        let input = Pipe()
        let exec = Task {
            try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
                ContainerExecRequest(containerID: "web", arguments: ["cat"], interactive: true),
                stdin: input.fileHandleForReading, stdout: .nullDevice, stderr: .nullDevice)
        }
        await fulfillment(of: [started], timeout: 2)
        exec.cancel()
        do {
            _ = try await exec.value
            XCTFail("Cancelled exec returned success")
        } catch is CancellationError {}
        XCTAssertTrue(server.clientClosedStart)
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testExternalEngineNegotiatesOnceBeforePipedExec() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let version = DockerExecFixture.json("200 OK", #"{"ApiVersion":"1.55","MinAPIVersion":"1.44"}"#)
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: reply, versionReply: version)
        let engine = DockerEngine(endpoint: path, environment: [:])
        let code = try await engine.execAttached(
            ContainerExecRequest(containerID: "web", arguments: ["true"]),
            stdin: .nullDevice, stdout: .nullDevice, stderr: .nullDevice)
        XCTAssertEqual(code, 37)
        XCTAssertEqual(
            try server.requests().map(\.line),
            [
                "GET /version HTTP/1.1", "POST /v1.47/containers/web/exec HTTP/1.1",
                "POST /v1.47/exec/exec-fixture/start HTTP/1.1", "GET /v1.47/exec/exec-fixture/json HTTP/1.1",
            ])
    }

    func testOutputOnlyExecSendsEOFAfterTheUpgradeAndStillReadsOutput() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
        let server = try DockerExecFixture(
            path: path, startReply: reply,
            afterStart: { fd in
                var byte: UInt8 = 0
                guard Darwin.read(fd, &byte, 1) == 0 else { throw POSIXError(.ETIMEDOUT) }
                try FileHandle(fileDescriptor: fd).write(contentsOf: Data([1, 0, 0, 0, 0, 0, 0, 1, 255]))
            })
        let output = Pipe()
        let code = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
            ContainerExecRequest(containerID: "web", arguments: ["true"]),
            stdin: .nullDevice, stdout: output.fileHandleForWriting, stderr: .nullDevice)
        try output.fileHandleForWriting.close()
        XCTAssertEqual(try output.fileHandleForReading.readToEnd(), Data([255]))
        XCTAssertEqual(code, 37)
        XCTAssertEqual(try server.requests().count, 3)
    }

    func testCancelledExecDoesNotCreateAnExec() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let server = try DockerExecFixture(path: path, startReply: Data())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DockerEngine(endpoint: path, environment: [:]).execAttached(
                ContainerExecRequest(containerID: "web", arguments: ["true"]),
                stdin: .nullDevice, stdout: .nullDevice, stderr: .nullDevice)
        }
        do {
            _ = try await task.value
            XCTFail("A pre-cancelled call returned success")
        } catch is CancellationError {}
        XCTAssertTrue(try server.requests().isEmpty)
    }

    func testCancellationWhileWaitingForExitInspection() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
        let inspecting = expectation(description: "inspect connection accepted")
        let server = try DockerExecFixture(
            path: path, startReply: reply,
            inspectHandler: { fd in
                inspecting.fulfill()
                var byte: UInt8 = 0
                guard Darwin.read(fd, &byte, 1) == 0 else { throw POSIXError(.ETIMEDOUT) }
            })
        let task = Task {
            try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
                ContainerExecRequest(containerID: "web", arguments: ["true"]),
                stdin: .nullDevice, stdout: .nullDevice, stderr: .nullDevice)
        }
        await fulfillment(of: [inspecting], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled inspection returned success")
        } catch is CancellationError {}
        XCTAssertEqual(try server.requests().count, 3)
    }

    func testCancellingAFullOutputPipePreservesBorrowedFileFlags() async throws {
        let path = root.appendingPathComponent("docker.sock").path
        let output = Pipe()
        let fd = output.fileHandleForWriting.fileDescriptor
        let originalFlags = fcntl(fd, F_GETFL)
        XCTAssertEqual(fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK), 0)
        let fill = [UInt8](repeating: 0, count: 512)
        while fill.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) > 0 {}
        XCTAssertEqual(errno, EAGAIN)
        XCTAssertEqual(fcntl(fd, F_SETFL, originalFlags), 0)
        let flags = fcntl(fd, F_GETFL)
        let sent = expectation(description: "frame sent")
        let reply =
            Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8)
            + Data([1, 0, 0, 0, 0, 0, 0, 1, 42])
        let server = try DockerExecFixture(path: path, startReply: reply, afterStart: { _ in sent.fulfill() })
        let task = Task {
            try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
                ContainerExecRequest(containerID: "web", arguments: ["echo"]),
                stdin: .nullDevice, stdout: output.fileHandleForWriting, stderr: .nullDevice)
        }
        await fulfillment(of: [sent], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fcntl(fd, F_GETFL), flags)
        // Release a regressed writer eventually so a failed assertion cannot hang the suite.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            _ = try? output.fileHandleForReading.read(upToCount: 8192)
        }
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled output writer returned success")
        } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(fcntl(fd, F_GETFL), flags)
        XCTAssertEqual(try server.requests().count, 2)
    }

    func testVersionSelectionBeforeAnyMutation() async throws {
        let versions = [
            (#"{"ApiVersion":"1.43"}"#, "v1.43"),
            (#"{"ApiVersion":"1.44","MinAPIVersion":"1.43"}"#, "v1.44"),
            (#"{"ApiVersion":"1.57","MinAPIVersion":"1.52"}"#, ""),
        ]
        for (index, item) in versions.enumerated() {
            let path = root.appendingPathComponent("version-\(index).sock").path
            let server = try DockerExecFixture(
                path: path, startReply: DockerExecFixture.json("200 OK", "{}"),
                versionReply: DockerExecFixture.json("200 OK", item.0))
            let engine = DockerEngine(endpoint: path, environment: [:])
            let request = ContainerExecRequest(containerID: "web", arguments: ["true"], detach: true)
            if item.1.isEmpty {
                do {
                    _ = try await engine.exec(request)
                    XCTFail("Incompatible version was accepted")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("no overlap"))
                }
                XCTAssertEqual(try server.requests().map(\.line), ["GET /version HTTP/1.1"])
            } else {
                _ = try await engine.exec(request)
                XCTAssertEqual(
                    try server.requests().map(\.line),
                    [
                        "GET /version HTTP/1.1", "POST /\(item.1)/containers/web/exec HTTP/1.1",
                        "POST /\(item.1)/exec/exec-fixture/start HTTP/1.1",
                    ])
            }
        }
        let invalid = DockerEngine(endpoint: "/unused", environment: ["DOCKER_API_VERSION": "1.44/path"])
        XCTAssertThrowsError(try invalid.api())
    }

    func testExecRequiresCompleteHeadersAndAFinalExitCode() async throws {
        let cases: [(String, Data, String)] = [
            (
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n", DockerExecFixture.json("200 OK", "{}"),
                "truncated HTTP headers"
            ),
            (
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n", DockerExecFixture.json("200 OK", "{}"),
                "final exit code"
            ),
            (
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n",
                DockerExecFixture.json("200 OK", #"{"Running":true,"ExitCode":0}"#), "final exit code"
            ),
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n", DockerExecFixture.json("200 OK", #"{"Running":false,"ExitCode":false}"#), "final exit code"),
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n", DockerExecFixture.json("200 OK", #"{"ExitCode":0}"#), "final exit code"),
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n", DockerExecFixture.json("200 OK", #"{"Running":0,"ExitCode":0}"#), "final exit code"),
        ]
        for (index, item) in cases.enumerated() {
            let path = root.appendingPathComponent("exit-\(index).sock").path
            let server = try DockerExecFixture(path: path, startReply: Data(item.0.utf8), inspectReply: item.1)
            do {
                _ = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
                    ContainerExecRequest(containerID: "web", arguments: ["true"]),
                    stdin: .nullDevice, stdout: .nullDevice, stderr: .nullDevice)
                XCTFail("An incomplete response reported success")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(item.2), "\(error)")
            }
            XCTAssertEqual(try server.requests().count, index == 0 ? 2 : 3)
        }
    }

    func testHEADHonorsTheAdvertisedGETLengthWithoutReadingABody() async throws {
        let path = root.appendingPathComponent("head.sock").path
        let head = Data("HTTP/1.1 200 OK\r\nContent-Length: 2048\r\n\r\n".utf8)
        let server = try DockerExecFixture(path: path, startReply: head)
        let response = try await DockerClient(endpoint: .unix(path)).request("HEAD", "/start")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(try server.requests().count, 1)
    }

    func testPipedExecFailsOnIncompleteFramesAndDaemonErrors() async throws {
        let cases: [(Data, String)] = [
            (Data([1, 0]), "truncated stream"),
            (Data([1, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 1]), "truncated stream"),
            (Data([4, 0, 0, 0, 0, 0, 0, 0]), "invalid stream header"),
            (Data([3, 0, 0, 0, 0, 0, 0, 4]) + Data("boom".utf8), "boom"),
        ]
        for (index, item) in cases.enumerated() {
            let path = root.appendingPathComponent("docker-\(index).sock").path
            let reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: tcp\r\n\r\n".utf8) + item.0
            let server = try DockerExecFixture(path: path, startReply: reply)
            do {
                _ = try await DockerEngine(endpoint: path, environment: ["DOCKER_API_VERSION": "1.43"]).execAttached(
                    ContainerExecRequest(containerID: "web", arguments: ["cat"]),
                    stdin: .nullDevice, stdout: .nullDevice, stderr: .nullDevice)
                XCTFail("Expected \(item.1)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(item.1), "\(error)")
            }
            XCTAssertEqual(try server.requests().count, 2)
        }
    }
}

/// A local Unix socket with only the endpoints needed for the exec exchange.
private final class DockerExecFixture: @unchecked Sendable {
    struct Request {
        let line: String
        let headers: [String]
        let body: Data

        func json() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    private let queue = DispatchQueue(label: "docker-exec-fixture")
    private let listener: any DispatchSourceRead
    private let startReply: Data
    private let holdStartOpen: Bool
    private let versionReply: Data?
    private let inspectReply: Data
    private let inspectHandler: (@Sendable (Int32) throws -> Void)?
    private let afterStart: (@Sendable (Int32) throws -> Void)?
    private var received: [Request] = []
    private var failure: Error?
    private var closedStart = false

    var clientClosedStart: Bool { queue.sync { closedStart } }

    func requests() throws -> [Request] {
        try queue.sync {
            if let failure { throw failure }
            return received
        }
    }

    init(
        path: String, startReply: Data, holdStartOpen: Bool = false, versionReply: Data? = nil,
        inspectReply: Data = DockerExecFixture.json("200 OK", #"{"Running":false,"ExitCode":37}"#),
        inspectHandler: (@Sendable (Int32) throws -> Void)? = nil,
        afterStart: (@Sendable (Int32) throws -> Void)? = nil
    ) throws {
        self.startReply = startReply
        self.holdStartOpen = holdStartOpen
        self.versionReply = versionReply
        self.inspectReply = inspectReply
        self.inspectHandler = inspectHandler
        self.afterStart = afterStart
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setCancelHandler { Darwin.close(fd) }
        listener.setEventHandler { [weak self] in self?.respond(to: fd) }
        listener.activate()
    }

    deinit { listener.cancel() }

    private func respond(to listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        do {
            let request = try Self.read(from: fd)
            received.append(request)
            let reply: Data
            switch request.line.split(separator: " ").dropFirst().first?.split(separator: "/").last {
            case "version": reply = versionReply ?? Self.json("404 Not Found", "{}")
            case "exec": reply = Self.json("201 Created", #"{"Id":"exec-fixture"}"#)
            case "start": reply = startReply
            case "json":
                if let inspectHandler {
                    try inspectHandler(fd)
                    return
                }
                reply = inspectReply
            default: reply = Self.json("404 Not Found", #"{"message":"unexpected request"}"#)
            }
            try FileHandle(fileDescriptor: fd).write(contentsOf: reply)
            if reply == startReply { try afterStart?(fd) }
            if holdStartOpen, reply == startReply {
                var byte: UInt8 = 0
                closedStart = Darwin.read(fd, &byte, 1) == 0
            }
        } catch {
            failure = error
        }
    }

    private static func read(from fd: Int32) throws -> Request {
        var request = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            request.append(contentsOf: bytes.prefix(count))
            guard let boundary = request.range(of: separator) else { continue }
            let headers = String(decoding: request[..<boundary.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n")
            let length =
                headers.first { $0.lowercased().hasPrefix("content-length:") }?
                .split(separator: ":", maxSplits: 1).last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            let end = boundary.upperBound + length
            guard request.count >= end else { continue }
            return Request(line: headers[0], headers: headers, body: Data(request[boundary.upperBound..<end]))
        }
    }

    static func json(_ status: String, _ body: String) -> Data {
        Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                .utf8)
    }
}
