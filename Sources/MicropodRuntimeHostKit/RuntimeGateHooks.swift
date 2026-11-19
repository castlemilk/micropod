import Darwin
import Foundation
import MicropodCore

/// Fault injection for the VM release gate (docs/vm-release-gate.md), so the
/// gate can exercise crash loops, hangs and interrupted installs with the
/// real signed release. Both hooks are inert unless root asks for them: the
/// fault file is root-only, and the kill variable only matters to a process
/// that already runs as root.
public enum RuntimeGateHooks {
    /// `RuntimeHost/gate-fault.json`: `{"version": "<release>", "fault":
    /// "crash" | "hang"}`. A helper of exactly that release crashes, or hangs
    /// until its start watchdog fires, after its launch is counted and before
    /// it serves.
    public static var faultFile: URL { IsolatedRuntimePolicy.root.appendingPathComponent("gate-fault.json") }

    struct Fault: Decodable {
        let version: String
        let fault: String
    }

    /// The fault `data` asks of `version`, or nil.
    static func fault(in data: Data?, version: String) -> String? {
        guard let data, let fault = try? JSONDecoder().decode(Fault.self, from: data), fault.version == version,
            ["crash", "hang"].contains(fault.fault)
        else { return nil }
        return fault.fault
    }

    public static func applyFault(version: String) {
        let data = try? RuntimeDurableFile.read(faultFile, maximumBytes: 1024, ownerUID: 0)
        switch fault(in: data, version: version) {
        case "crash":
            fputs("Release-gate fault: helper \(version) crashes\n", stderr)
            abort()
        case "hang":
            fputs("Release-gate fault: helper \(version) hangs\n", stderr)
            while true { sleep(3600) }
        default:
            return
        }
    }

    /// `MICROPOD_GATE_KILL_AT=<checkpoint>`: install-authority dies at that
    /// checkpoint exactly as a SIGKILL would end it.
    public static func killIfRequested(at checkpoint: String) {
        guard ProcessInfo.processInfo.environment["MICROPOD_GATE_KILL_AT"] == checkpoint else { return }
        fputs("Release-gate kill at \(checkpoint)\n", stderr)
        kill(getpid(), SIGKILL)
    }
}
