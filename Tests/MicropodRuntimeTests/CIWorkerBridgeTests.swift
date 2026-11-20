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
        var options = SandboxVM.Options(base: .image(CIWorker.image))
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
            var watch = CIWorker.NetworkWatch()
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
}
