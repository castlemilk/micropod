import Containerization
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

final class CIWorkerBridgeTests: XCTestCase {
    /// Run in a virtualization-entitled test host on a physical Mac. The test removes only the
    /// two attachments it owns. It never deletes a macOS route or changes another VM's network.
    func testRecoverMissingHostGatewayOnLiveKernel() async throws {
        guard let output = ProcessInfo.processInfo.environment["MICROPOD_CI_BRIDGE_RECEIPT"] else {
            throw XCTSkip("Set MICROPOD_CI_BRIDGE_RECEIPT in a signed physical Mac test host")
        }
        let home = URL(fileURLWithPath: "/tmp/mp-bridge-" + UUID().uuidString.prefix(8))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path])
        try worker.prepareDirectory()
        let id = UUID()
        var options = SandboxVM.Options(base: .image(CIWorker.dockerImage))
        options.network = true
        options.env = ["MICROPOD_CI_WORKER_ID=" + id.uuidString, "MICROPOD_CI_INSTANCE=" + id.uuidString]
        options.entrypoint = ["/bin/sh", "-c"]
        options.arguments = [CIWorker.bootstrap]
        let prepared = try await SandboxVM.prepare(
            options, id: "ci-bridge-" + id.uuidString.lowercased(), runDir: home,
            stdout: FileHandleWriter(.standardError), stderr: FileHandleWriter(.standardError), progress: { _ in },
            ciWorker: worker)
        let network = try XCTUnwrap(prepared.network)
        let gateway = try XCTUnwrap(prepared.gateway)
        func shell(_ script: String) async throws -> String {
            let capture = CollectingWriter()
            let process = try await prepared.container.exec(UUID().uuidString) { cfg in
                cfg.arguments = ["/bin/sh", "-ec", script]
                cfg.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
                cfg.stdout = capture
                cfg.stderr = FileHandleWriter(.standardError)
            }
            try await process.start()
            let status = try await process.wait()
            try await process.delete()
            guard status.exitCode == 0 else { throw MicropodError.message("Guest probe exited \(status.exitCode)") }
            return capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try await prepared.container.create()
            try await prepared.container.start()
            _ = try await shell(
                "for i in $(seq 1 100); do if docker info >/dev/null 2>&1; then exit 0; fi; sleep .1; done; exit 1")
            let alpine = "alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
            let cid = try await shell(
                "docker run -d --name sentinel \(alpine) sh -c 'echo warm >/tmp/proof; exec sleep 240'")
            let probe =
                "docker exec sentinel sh -ec 'timeout 4 nslookup registry-1.docker.io >/dev/null; timeout 6 wget -qO /dev/null https://example.org; cat /tmp/proof /proc/sys/kernel/random/boot_id'"
            let before = try await shell(probe)
            let daemon = try await shell("docker info -f '{{.ID}}'")
            XCTAssertTrue(try CIWorker.hasLocalGateway(gateway))
            try await prepared.container.withVirtualMachineInstance { instance in
                let vm = try XCTUnwrap(instance as? VZVirtualMachineInstance)
                try await CIWorker.attachNIC(false, vm: vm, network: network)
            }
            try network.stop()
            let deadline = ContinuousClock.now + .seconds(8)
            while try CIWorker.hasLocalGateway(gateway), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard try !CIWorker.hasLocalGateway(gateway) else {
                throw MicropodError.message("The physical fault did not remove the worker's gateway")
            }
            _ = try await shell("if " + probe + "; then exit 1; fi")
            let watch = CIWorker.NetworkWatch()
            let repair = await watch.inspect(prepared, gateway: gateway, instance: id, request: nil)
            let result = try XCTUnwrap(repair)
            XCTAssertEqual(result.cause, "host-gateway-missing")
            XCTAssertNil(result.error)
            let after = try await shell(probe)
            let active = try await shell("docker inspect -f '{{.Id}}' sentinel")
            let afterDaemon = try await shell("docker info -f '{{.ID}}'")
            guard before == after, afterDaemon == daemon, active == cid, result.error == nil,
                result.cause == "host-gateway-missing"
            else { throw MicropodError.message("Network repair did not preserve the live workload") }
            let record: [String: Any] = [
                "passed": true, "cause": "host-gateway-missing", "absent_on_mac": true, "gateway": gateway,
                "kernel_and_sentinel": after, "daemon": daemon, "container": cid, "repair_seconds": result.seconds,
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
            _ = try await shell("docker rm -f sentinel && sync")
        } catch {
            try await prepared.stop()
            try FileManager.default.removeItem(at: home)
            throw error
        }
        try await prepared.stop()
        try FileManager.default.removeItem(at: home)
    }

    /// Keep a fresh, working published connection available for longer than the relay's
    /// handshake deadline while the worker's private egress bridge is physically absent.
    func testPublishedLinkSurvivesMissingEgressBridge() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["MICROPOD_CI_PUBLISHED_LINK_RECEIPT"], let tools = env["MICROPOD_CI_OCI_TOOLS"],
            let fixture = env["MICROPOD_CI_NETBENCH_LINUX"]
        else {
            throw XCTSkip("Requires native runner tools, Linux netbench and a signed physical Mac test host")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mp-links-" + UUID().uuidString.prefix(8))
        let worker = CIWorker(environment: ["MICROPOD_CI_HOME": home.path, "MICROPOD_CI_ENGINE": "containerd"])
        try worker.prepareDirectory()
        let id = UUID()
        var options = SandboxVM.Options(base: .image(CIWorker.Engine.containerd.image))
        options.network = true
        options.cpus = 4
        options.memoryMiB = 4096
        options.ciOCITools = URL(fileURLWithPath: tools)
        let binary = URL(fileURLWithPath: fixture)
        options.mounts = [binary.deletingLastPathComponent().path + ":/mp-fixture:ro"]
        options.entrypoint = ["/mp-fixture/" + binary.lastPathComponent]
        options.arguments = ["-listen", ":38085", "-marker", id.uuidString]
        let prepared = try await SandboxVM.prepare(
            options, id: "ci-link-" + id.uuidString.lowercased(), runDir: home,
            stdout: FileHandleWriter(.standardError),
            stderr: FileHandleWriter(.standardError), progress: { _ in }, ciWorker: worker)
        do {
            let primary = try XCTUnwrap(prepared.network)
            let data = try XCTUnwrap(prepared.publishedNetwork)
            let gateway = primary.gateway.description
            let peer = data.gateway.description
            XCTAssertNotEqual(gateway, peer)
            let relay = try NativeLoopbackRelay(guest: data.interface.ipv4Address.address.description, gateway: peer)
            defer { relay.stop() }
            let port = try relay.bind(host: 0, guest: 38085)
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/id"))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            func marker() async throws {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
                request.setValue("close", forHTTPHeaderField: "Connection")
                let (body, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, body == Data(id.uuidString.utf8)
                else { throw MicropodError.message("Wrong service on published link") }
            }
            try await prepared.container.create()
            try await prepared.container.start()
            let readyBy = ContinuousClock.now + .seconds(10)
            while (try? await marker()) == nil {
                guard ContinuousClock.now < readyBy else {
                    throw MicropodError.message("Published HTTP fixture did not start")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            // An external client can establish its streams before the fault
            // and verify their identities and byte counts through recovery.
            let loadDir = env["MICROPOD_CI_PUBLISHED_LOAD_DIR"].map { URL(fileURLWithPath: $0) }
            defer {
                if let loadDir { try? Data().write(to: loadDir.appendingPathComponent("finish"), options: .atomic) }
            }
            func waitForClient(_ file: URL) async throws {
                let deadline = ContinuousClock.now + .seconds(40)
                while !FileManager.default.fileExists(atPath: file.path) {
                    guard ContinuousClock.now < deadline else {
                        throw MicropodError.message("Load client timed out waiting for " + file.lastPathComponent)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            if let loadDir {
                let endpoint = ["url": "http://127.0.0.1:\(port)", "marker": id.uuidString]
                try JSONEncoder().encode(endpoint).write(
                    to: loadDir.appendingPathComponent("endpoint.json"), options: .atomic)
                try await waitForClient(loadDir.appendingPathComponent("ready"))
            }
            try await prepared.container.withVirtualMachineInstance { instance in
                let vm = try XCTUnwrap(instance as? VZVirtualMachineInstance)
                try await CIWorker.attachNIC(false, vm: vm, network: primary)
            }
            try primary.stop()
            let absentBy = ContinuousClock.now + .seconds(10)
            while try CIWorker.hasLocalGateway(gateway), ContinuousClock.now < absentBy {
                try await Task.sleep(for: .milliseconds(50))
            }
            let start = ContinuousClock.now
            var count = 0
            repeat {
                guard try !CIWorker.hasLocalGateway(gateway), try CIWorker.hasLocalGateway(peer) else {
                    throw MicropodError.message("Physical egress outage was not isolated")
                }
                try await marker()
                count += 1
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < start + .seconds(32)
            let held = start.duration(to: .now).components
            try await CIWorker.reconnect(prepared)
            try await marker()
            if let loadDir {
                try Data().write(to: loadDir.appendingPathComponent("finish"), options: .atomic)
                try await waitForClient(loadDir.appendingPathComponent("drained"))
            }
            let record: [String: Any] = [
                "egress_gateway": gateway, "published_gateway": peer,
                "absence_seconds": Double(held.seconds) + Double(held.attoseconds) / 1e18,
                "fresh_requests_during_absence": count, "marker": id.uuidString,
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(
                to: URL(fileURLWithPath: output))
        } catch {
            try await prepared.stop()
            try FileManager.default.removeItem(at: home)
            throw error
        }
        try await prepared.stop()
        try FileManager.default.removeItem(at: home)
    }
}
