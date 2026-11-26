import Foundation
import Testing

@testable import MicropodRuntime

@Suite("CI worker launchd selection")
struct CIWorkerServiceTests {
    private let home = "/private/tmp/worker home"
    private let target = "gui/501/com.skunkworq.micropod.ci-worker"
    private let binary = URL(fileURLWithPath: "/usr/local/bin/micropod")

    private func worker(vmm: String? = nil, engine: String = "containerd") -> CIWorker {
        var environment = ["MICROPOD_CI_HOME": home, "MICROPOD_CI_ENGINE": engine]
        environment["MICROPOD_CI_VMM"] = vmm
        return CIWorker(environment: environment)
    }

    @Test func renderedAgentPreservesTheRecordedVMMUnlessExplicitlyOverridden() throws {
        let cases: [(selection: String?, recorded: String?, expected: String?)] = [
            (nil, nil, nil), ("HVF", nil, "hvf"), (nil, "hvf", "hvf"), ("vz", "hvf", "vz"),
        ]
        for (selection, recorded, expected) in cases {
            let registration = recorded.map { ["MICROPOD_CI_VMM": $0] }
            let installed = worker(vmm: selection).workerForServiceInstallation(recordedEnvironment: registration)
            let data = try installed.launchAgent(executable: binary)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let environment = plist?["EnvironmentVariables"] as? [String: String]
            #expect(environment?["MICROPOD_CI_VMM"] == expected)
            #expect(environment?["MICROPOD_CI_HOME"] == home)
        }
        #expect(throws: Error.self) { try worker(vmm: "qemu").launchAgent(executable: binary) }
        #expect(throws: Error.self) { try worker(vmm: "hvf", engine: "docker").launchAgent(executable: binary) }
        let invalid = worker().workerForServiceInstallation(recordedEnvironment: ["MICROPOD_CI_VMM": "qemu"])
        #expect(throws: Error.self) { try invalid.launchAgent(executable: binary) }
    }

    @Test func repairedAgentRetainsTrustedBootResourcesAndAppliesCallerOverrides() throws {
        let recorded = [
            "MICROPOD_CI_HOME": home,
            "MICROPOD_CI_ENGINE": "containerd",
            "MICROPOD_CI_VMM": "hvf",
            "MICROPOD_CI_HVF_BIN": "/opt/rig/micropod-vmm",
            "MICROPOD_CI_HVF_INITRD": "/opt/rig/init.cpio",
            "MICROPOD_CI_KERNEL": "/opt/rig/Image",
            "MICROPOD_CI_OCI_TOOLS": "/opt/rig/oci-tools",
            "MICROPOD_CI_CPUS": "6",
            "MICROPOD_CI_MAX_STARTING": "8",
            "CI_JOB_ID": "unrelated",
        ]
        let requested = CIWorker(environment: [
            "MICROPOD_CI_HOME": home, "MICROPOD_CI_MAX_STARTING": "4",
        ])
        let installed = requested.workerForServiceInstallation(recordedEnvironment: recorded)
        #expect(installed.isNativeRunner)
        #expect(try installed.selectedVMM() == .hvf)
        let data = try installed.launchAgent(executable: binary)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        var expected = recorded
        expected["CI_JOB_ID"] = nil
        expected["MICROPOD_CI_MAX_STARTING"] = "4"
        #expect(plist?["EnvironmentVariables"] as? [String: String] == expected)
    }

    @Test func reinstallingAnOrdinaryVZAgentPreservesItsKernelEnvironment() throws {
        let kernelArgs = #"loglevel=4  panic=20 note="kept  from the existing agent""#
        let recorded = ["MICROPOD_CI_HOME": home, "MICROPOD_SANDBOX_KERNEL_ARGS": kernelArgs]
        let installed = worker().workerForServiceInstallation(recordedEnvironment: recorded)
        #expect(try installed.selectedVMM() == .vz)
        let data = try installed.launchAgent(executable: binary)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let environment = plist?["EnvironmentVariables"] as? [String: String]
        #expect(environment?["MICROPOD_SANDBOX_KERNEL_ARGS"] == kernelArgs)
    }

    @Test func anExplicitSelectionChecksTheLoadedService() throws {
        let legacy = CIWorker.LoadedService(
            target: target, environment: ["MICROPOD_CI_HOME": home, "MICROPOD_CI_ENGINE": "containerd"])
        #expect(try worker(vmm: "vz").serviceTarget(registeredHome: home, loadService: { legacy }) == target)
        do {
            _ = try worker(vmm: "hvf").serviceTarget(registeredHome: home, loadService: { legacy })
            Issue.record("A VZ service could be kicked off for an explicit HVF request")
        } catch {
            #expect(error.localizedDescription.contains("the loaded CI service uses vz"))
        }
        let hvf = CIWorker.LoadedService(
            target: target,
            environment: ["MICROPOD_CI_HOME": home, "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "hvf"])
        #expect(try worker().serviceTarget(registeredHome: home, loadService: { hvf }) == target)
        #expect(try worker(vmm: "hvf").serviceTarget(registeredHome: home, loadService: { hvf }) == target)
    }

    @Test func neverSelectsAnUnrelatedOrUnconfirmedLoadedService() throws {
        let otherHome = "/private/tmp/another-worker"
        let other = CIWorker.LoadedService(target: target, environment: ["MICROPOD_CI_HOME": otherHome])
        for registration in [nil, otherHome] {
            let result = try worker().serviceTarget(registeredHome: registration, loadService: {
                Issue.record("An unrelated worker triggered a launchd lookup")
                return other
            })
            #expect(result == nil)
        }
        #expect(throws: Error.self) { try worker().serviceTarget(registeredHome: home, loadService: { other }) }
        #expect(throws: Error.self) { try worker().serviceTarget(registeredHome: home, loadService: { nil }) }
        let unknown = CIWorker.LoadedService(target: target, environment: nil)
        #expect(throws: Error.self) {
            try worker(vmm: "hvf").serviceTarget(registeredHome: home, loadService: { unknown })
        }
    }

    @Test func readsTheLoadedJobEnvironmentWithLaunchdPrecedence() throws {
        let printed = """
            \(target) = {
                inherited environment = {
                    MICROPOD_CI_ENGINE => docker
                    MICROPOD_CI_VMM => hvf
                }
                default environment = {
                    MICROPOD_CI_VMM => vz
                }
                environment = {
                    MICROPOD_CI_HOME => \(home)
                    MICROPOD_CI_ENGINE => containerd
                    MICROPOD_CI_VMM => vz
                    XPC_SERVICE_NAME => com.skunkworq.micropod.ci-worker
                }
            }
            """
        let environment = try #require(CIWorker.loadedEnvironment(from: printed))
        #expect(environment == ["MICROPOD_CI_HOME": home, "MICROPOD_CI_ENGINE": "containerd", "MICROPOD_CI_VMM": "vz"])
        #expect(CIWorker.loadedEnvironment(from: "state = running") == nil)
        let inherited = "inherited environment = {\n\tMICROPOD_CI_HOME => \(home)\n}"
        #expect(CIWorker.loadedEnvironment(from: inherited) == nil)
    }
}
