import Darwin
import Foundation
import MicropodCore
import MicropodRuntime
import SwiftProtobuf
import XCTest

@testable import MicropodAPI

final class RootlessHVFAndBinaryProtoTests: XCTestCase {
    private func makeHandlers(engineRegistry: EngineRegistry = .shared) async -> APIHandlers {
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let services = await RuntimeBackendResolver.resolveApple(
            client: client, environment: ["MICROPOD_RUNTIME": "cli"])
        let holder = RuntimeHolder(initial: services, resolve: { services }, managedSelectionPresent: { false })
        return APIHandlers(
            client: client,
            system: SystemService(client: client),
            images: ImageService(client: client),
            networks: NetworkService(client: client),
            compose: ComposeService(client: client),
            runtime: holder,
            engineRegistry: engineRegistry)
    }

    func testBinaryProtoConnectRoundTrip() async throws {
        let api = await makeHandlers()
        let reqBytes = try Micropod_V1_Empty().serializedData()
        let resp = await api.connectRPC(
            method: "GetVolumePolicy",
            body: reqBytes,
            headers: ["content-type": "application/proto"])
        guard case .data(let status, let contentType, let data) = resp else {
            return XCTFail("expected .data response, got \(String(describing: resp))")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(contentType, "application/proto")
        let decoded = try Micropod_V1_VolumePolicy(serializedBytes: data)
        XCTAssertNotEqual(decoded.cloneMode, .unspecified)
    }

    func testOwnerSocketAcceptsBinaryProtoWithoutLoopbackPortHost() async throws {
        let dir = URL(fileURLWithPath: "/tmp/mp-sock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sockPath = dir.appendingPathComponent("api.sock").path

        let api = await makeHandlers()
        let server = HTTPServer(port: 45454, handler: api.handle)
        try await server.startPrivateSocket(path: sockPath, admission: .ownerOnly)
        defer { server.stop() }

        let response: Data = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                done.resume(
                    with: Result {
                        let fd = try RuntimeUnixSocket.connect(sockPath, expectedUID: getuid())
                        defer { close(fd) }
                        try RuntimeUnixSocket.timeout(fd, seconds: 3)
                        let body = try Micropod_V1_Empty().serializedData()
                        let head =
                            "POST /api/micropod.v1.VolumeService/GetVolumePolicy HTTP/1.1\r\n"
                            + "Host: localhost\r\n"
                            + "Content-Type: application/proto\r\n"
                            + "Content-Length: \(body.count)\r\n\r\n"
                        try RuntimeUnixSocket.write(Data(head.utf8) + body, to: fd)
                        var out = Data()
                        var buf = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let n = Darwin.read(fd, &buf, buf.count)
                            guard n >= 0 else { throw CocoaError(.fileReadUnknown) }
                            if n == 0 { return out }
                            out.append(contentsOf: buf.prefix(n))
                        }
                    })
            }
        }
        let split = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        let headText = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        XCTAssertTrue(headText.contains("HTTP/1.1 200 OK"), headText)
        XCTAssertTrue(headText.contains("Content-Type: application/proto"), headText)
        XCTAssertTrue(headText.contains("X-Micropod-Codecs: json,proto"), headText)
        let protoBody = response[split.upperBound...]
        let policy = try Micropod_V1_VolumePolicy(serializedBytes: Data(protoBody))
        XCTAssertNotEqual(policy.cloneMode, .unspecified)
    }

    /// Installed stub assets and no VMM: hvf is the backend, but nothing
    /// runs, so neither call may say `running` or advertise live features.
    func testRootlessHVFPingAndGetSystemReportAnInstalledButStoppedMachineAsStopped() async throws {
        let dir = URL(fileURLWithPath: "/tmp/mp-hvfapi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let layout = HVFMachineLayout(root: dir)
        for asset in [layout.vmm, layout.kernel, layout.initrd, layout.disk] {
            try FileManager.default.createDirectory(
                at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: asset.path, contents: Data("stub".utf8))
            if asset == layout.vmm {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: asset.path)
            }
        }
        let startScript = layout.tools.appendingPathComponent("runner/start.sh")
        try FileManager.default.createDirectory(
            at: startScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: startScript.path, contents: Data("#!/bin/sh\n".utf8))

        let registry = EngineRegistry(environment: [
            "MICROPOD_HVF_ROOT": dir.path,
            "MICROPOD_DEFAULT_RUNTIME": "hvf",
            "MICROPOD_RUNTIMES_CONFIG": dir.appendingPathComponent("runtimes.json").path,
            // Stub assets: never start them on demand (HVFMachineReadinessTests covers that).
            "MICROPOD_HVF_AUTOSTART": "0",
        ])
        let api = await makeHandlers(engineRegistry: registry)
        let pingResp = await api.connectRPC(
            method: "Ping",
            body: try Micropod_V1_Empty().serializedData(),
            headers: ["content-type": "application/proto"])
        guard case .data(200, "application/proto", let pingBytes) = pingResp else {
            return XCTFail("unexpected Ping response: \(String(describing: pingResp))")
        }
        let ping = try Micropod_V1_PingResponse(serializedBytes: pingBytes)
        XCTAssertEqual(ping.status, "stopped")
        XCTAssertEqual(ping.runtimeBackend, "hvf")
        XCTAssertEqual(ping.defaultRuntime, "hvf")
        XCTAssertTrue(ping.features.contains("hvf"))
        XCTAssertTrue(ping.features.contains("rootless"))
        XCTAssertTrue(ping.features.contains("proto-binary"))
        XCTAssertFalse(ping.features.contains("buildkit"), "\(ping.features)")
        XCTAssertFalse(ping.features.contains("caches-v2"), "\(ping.features)")
        let component = try XCTUnwrap(ping.components.first { $0.name == "hvf-machine" })
        XCTAssertEqual(component.state, "stopped")
        XCTAssertTrue(component.detail.hasPrefix("stopped: "), component.detail)

        let sysResp = await api.connectRPC(
            method: "GetSystem",
            body: try Micropod_V1_Empty().serializedData(),
            headers: ["content-type": "application/proto"])
        guard case .data(200, "application/proto", let sysBytes) = sysResp else {
            return XCTFail("unexpected GetSystem response: \(String(describing: sysResp))")
        }
        let sys = try Micropod_V1_SystemSnapshot(serializedBytes: sysBytes)
        XCTAssertEqual(sys.status.status, "stopped")
        XCTAssertEqual(sys.status.runtimeBackend, "hvf")
        XCTAssertEqual(sys.status.installRoot, dir.path)
        XCTAssertEqual(sys.components.first { $0.name == "hvf-machine" }?.state, "stopped")
    }

    func testRigAndCacheControlRoutesAndPersistentCacheDisk() async throws {
        let dir = URL(fileURLWithPath: "/tmp/mp-rig-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let layout = HVFMachineLayout(root: dir)
        for asset in [layout.vmm, layout.kernel, layout.initrd, layout.disk] {
            try FileManager.default.createDirectory(
                at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: asset.path, contents: Data("stub".utf8))
            if asset == layout.vmm {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: asset.path)
            }
        }
        let startScript = layout.tools.appendingPathComponent("runner/start.sh")
        try FileManager.default.createDirectory(
            at: startScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: startScript.path, contents: Data("#!/bin/sh\n".utf8))

        // Create a real sparse journaled ext4 caches.ext4 and verify VMM argv wires --cache-disk.
        try HVFMachineInstaller.provisionCacheDisk(bytes: 256 << 20, into: layout.cacheDisk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.cacheDisk.path))
        let vmmArgs = try HVFVMMCommand.arguments(layout: layout, config: HVFMachineConfig(), parentPID: 1)
        XCTAssertTrue(vmmArgs.contains("--cache-disk"), "\(vmmArgs)")
        XCTAssertTrue(vmmArgs.contains(layout.cacheDisk.path), "\(vmmArgs)")

        // Verify canonical docker.sock atomic symlink helper.
        let canonical = dir.appendingPathComponent("canonical-docker.sock")
        let client = HVFMachineClient(layout: layout)
        let linked = try client.linkCanonicalDockerSocket(canonical: canonical)
        XCTAssertEqual(linked.path, canonical.path)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: canonical.path), layout.dockerSocket.path)

        let registry = EngineRegistry(environment: [
            "MICROPOD_HVF_ROOT": dir.path,
            "MICROPOD_DEFAULT_RUNTIME": "hvf",
            "MICROPOD_RUNTIMES_CONFIG": dir.appendingPathComponent("runtimes.json").path,
            "MICROPOD_HVF_AUTOSTART": "0",
        ])
        let api = await makeHandlers(engineRegistry: registry)

        // GET /v1/rig/mode
        let modeResp = await api.handle(
            HTTPRequest(method: .get, path: "/v1/rig/mode", query: [:], body: Data(), headers: [:]))
        guard case .json(200, let modeObj) = modeResp else {
            return XCTFail("unexpected /v1/rig/mode response: \(modeResp)")
        }
        XCTAssertEqual(modeObj["mode"] as? String, "container")
        XCTAssertEqual(modeObj["defaultRuntime"] as? String, "hvf")

        // GET /v1/rig/health
        let healthResp = await api.handle(
            HTTPRequest(method: .get, path: "/v1/rig/health", query: [:], body: Data(), headers: [:]))
        guard case .json(200, let healthObj) = healthResp,
            let hvfInfo = healthObj["hvf"] as? [String: Any]
        else {
            return XCTFail("unexpected /v1/rig/health response: \(healthResp)")
        }
        XCTAssertEqual(hvfInfo["installed"] as? Bool, true)
        // No guest runs here, so whether it mounted caches.ext4 is unknown:
        // a file on the host is no evidence (B12).
        XCTAssertEqual(hvfInfo["cacheDiskPresent"] as? Bool, false)
        let cacheDisk = hvfInfo["cacheDisk"] as? [String: Any] ?? [:]
        XCTAssertEqual(cacheDisk["configured"] as? Bool, true)
        XCTAssertEqual(cacheDisk["source"] as? String, "unknown")
        XCTAssertEqual(hvfInfo["sharedCaches"] as? String, "unknown", "a stopped machine has said nothing")

        // PUT /v1/caches/policy -> updates machine.json + live guest-config/cache-policy.json
        let policyBody = try JSONSerialization.data(withJSONObject: [
            "sharedL0": true,
            "goProxy": "http://10.42.0.1:7677/go|direct",
        ])
        let putPolicyResp = await api.handle(
            HTTPRequest(
                method: .put, path: "/v1/caches/policy", query: [:], body: policyBody,
                headers: ["content-type": "application/json"]))
        guard case .data(200, "application/json", let updatedBytes) = putPolicyResp else {
            return XCTFail("unexpected PUT /v1/caches/policy: \(putPolicyResp)")
        }
        let updatedPolicy = try JSONDecoder().decode(HVFMachineCachePolicy.self, from: updatedBytes)
        XCTAssertTrue(updatedPolicy.sharedL0)
        XCTAssertEqual(updatedPolicy.goProxy, "http://10.42.0.1:7677/go|direct")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.cachePolicyFile.path))
    }
}
