import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodAPI

final class IsolatedRuntimeGatewayTests: XCTestCase {
    func testPrivateHTTPStreamDeliversCompletionThroughGateway() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gw-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: getuid(), serviceUID: getuid(), serviceGID: getgid(), accountGUID: UUID(),
            groupGUID: UUID())
        let session = IsolatedRuntimeAPISession(
            id: UUID(), instance: identity.instance, token: String(repeating: "a", count: 43),
            subject: try XCTUnwrap(RuntimeProcessBirth.read(getpid())), expiresAt: Date().addingTimeInterval(60))
        try RuntimeDurableFile.write(
            IsolatedRuntimeAPISessionRecord(session: session),
            to: root.appendingPathComponent(session.id.uuidString + ".json"))
        let path = root.appendingPathComponent("a.sock").path
        let internalPath = root.appendingPathComponent("b.sock").path
        let server = HTTPServer(port: 45454) { _ in
            .stream(
                200, "application/x-ndjson",
                AsyncStream { continuation in
                    let task = Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        continuation.yield(Data("{\"chunk\":\"b2s=\"}\n".utf8))
                        continuation.yield(Data("{\"complete\":true}\n".utf8))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                })
        }
        try await server.startPrivateSocket(path: internalPath)
        defer { server.stop() }
        let gateway = IsolatedRuntimeGateway(
            identity: identity, socketPath: path, internalSocketPath: internalPath, sessionsRoot: root,
            registryOwnerUID: getuid())
        try gateway.start()
        defer { gateway.stop() }
        let response: Data = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                done.resume(
                    with: Result {
                        let client = try RuntimeUnixSocket.connect(path, expectedUID: getuid())
                        defer { close(client) }
                        try RuntimeUnixSocket.timeout(client, seconds: 3)
                        try RuntimeUnixSocket.write(
                            Data(
                                ("POST /stream HTTP/1.1\r\nHost: localhost:45454\r\nContent-Type: application/json\r\n"
                                    + "Authorization: \(session.authorization)\r\nContent-Length: 2\r\n\r\n{}").utf8),
                            to: client)
                        var response = Data()
                        var bytes = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let count = Darwin.read(client, &bytes, bytes.count)
                            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
                            if count == 0 { return response }
                            response.append(contentsOf: bytes.prefix(count))
                        }
                    })
            }
        }
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("{\"chunk\":\"b2s=\"}\n"), text)
        XCTAssertTrue(text.hasSuffix("{\"complete\":true}\n"), text)
    }

    private func listener(_ path: String) throws -> Int32 {
        let fd = try RuntimeUnixSocket.open()
        var address = try RuntimeUnixSocket.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
        return fd
    }
    func testAuthorizedConnectionRelaysBytesAndStripsCapability() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gw-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: getuid(), serviceUID: getuid(), serviceGID: getgid(), accountGUID: UUID(),
            groupGUID: UUID())
        let session = IsolatedRuntimeAPISession(
            id: UUID(), instance: identity.instance, token: String(repeating: "a", count: 43),
            subject: try XCTUnwrap(RuntimeProcessBirth.read(getpid())), expiresAt: Date().addingTimeInterval(60))
        try RuntimeDurableFile.write(
            IsolatedRuntimeAPISessionRecord(session: session),
            to: root.appendingPathComponent(session.id.uuidString + ".json"))
        let path = root.appendingPathComponent("a.sock").path
        let internalPath = root.appendingPathComponent("b.sock").path
        let fd = try listener(internalPath)
        defer { close(fd) }
        let upstream = expectation(description: "Authenticated request reached private listener")
        DispatchQueue.global().async {
            let peer = accept(fd, nil, nil)
            defer {
                if peer >= 0 { close(peer) }
                upstream.fulfill()
            }
            guard peer >= 0 else { return }
            try? RuntimeUnixSocket.timeout(peer, seconds: 2)
            var data = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(peer, &data, data.count)
            guard count > 0 else { return }
            let head = String(decoding: data.prefix(count), as: UTF8.self)
            XCTAssertFalse(head.lowercased().contains("authorization"))
            XCTAssertFalse(head.contains(session.token))
            try? RuntimeUnixSocket.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8), to: peer)
        }
        let gateway = IsolatedRuntimeGateway(
            identity: identity, socketPath: path, internalSocketPath: internalPath, sessionsRoot: root,
            registryOwnerUID: getuid())
        try gateway.start()
        defer { gateway.stop() }
        let client = try RuntimeUnixSocket.connect(path, expectedUID: getuid())
        defer { close(client) }
        try RuntimeUnixSocket.timeout(client, seconds: 2)
        try RuntimeUnixSocket.write(
            Data("GET /health HTTP/1.1\r\nHost: localhost\r\nAuthorization: \(session.authorization)\r\n\r\n".utf8),
            to: client)
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(client, &bytes, bytes.count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertTrue(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).hasSuffix("ok"))
        wait(for: [upstream], timeout: 3)
    }
    func testCapabilityForAnotherProcessCannotReachPrivateListener() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("gw-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: getuid(), serviceUID: getuid(), serviceGID: getgid(), accountGUID: UUID(),
            groupGUID: UUID())
        let session = IsolatedRuntimeAPISession(
            id: UUID(), instance: identity.instance, token: String(repeating: "a", count: 43),
            subject: try XCTUnwrap(RuntimeProcessBirth.read(child.processIdentifier)),
            expiresAt: Date().addingTimeInterval(60))
        try RuntimeDurableFile.write(
            IsolatedRuntimeAPISessionRecord(session: session),
            to: root.appendingPathComponent(session.id.uuidString + ".json"))
        let path = root.appendingPathComponent("a.sock").path
        let internalPath = root.appendingPathComponent("b.sock").path
        let fd = try listener(internalPath)
        defer { close(fd) }
        let gateway = IsolatedRuntimeGateway(
            identity: identity, socketPath: path, internalSocketPath: internalPath, sessionsRoot: root,
            registryOwnerUID: getuid())
        try gateway.start()
        defer { gateway.stop() }
        let client = try RuntimeUnixSocket.connect(path, expectedUID: getuid())
        defer { close(client) }
        try RuntimeUnixSocket.timeout(client, seconds: 2)
        try RuntimeUnixSocket.write(
            Data("GET /health HTTP/1.1\r\nAuthorization: \(session.authorization)\r\n\r\n".utf8), to: client)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(client, &byte, 1), 0)
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&event, 1, 0), 0, "Stolen capability opened an upstream connection")
    }
}
