import Darwin
import Foundation
import MicropodCore

/// Fault injection for the VM release gate (docs/vm-release-gate.md), so the
/// gate can exercise crash loops, hangs and interrupted installs with the
/// real signed release. Both hooks are armed only by root-owned files in
/// `RuntimeHost`, name the exact code they affect, and expire; absent (always,
/// outside the gate) they do nothing.
public enum RuntimeGateHooks {
    /// `RuntimeHost/gate-fault.json`: `{"version", "helperSHA256", "fault":
    /// "crash" | "hang", "expiresAt": <epoch seconds>}`. Only the helper of
    /// exactly that release and executable digest crashes, or hangs until its
    /// start watchdog fires, after its launch is counted and before it
    /// serves. Status reports `gateFaultArmed` while the file exists.
    public static var faultFile: URL { IsolatedRuntimePolicy.root.appendingPathComponent("gate-fault.json") }
    /// `RuntimeHost/gate-kill.json`: `{"checkpoint", "cdhash", "expiresAt"}`.
    /// The install-authority CLI with that CDHash removes it and dies at that
    /// checkpoint exactly as a SIGKILL would end it, once.
    public static var killFile: URL { IsolatedRuntimePolicy.root.appendingPathComponent("gate-kill.json") }
    /// An arming that claims to last longer than this is refused.
    public static let maximumLifetime: TimeInterval = 6 * 3600

    struct Fault: Decodable {
        let version: String
        let helperSHA256: String
        let fault: String
        let expiresAt: Double
    }

    struct Kill: Decodable {
        let checkpoint: String
        let cdhash: String
        let expiresAt: Double
    }

    static func live(_ expiresAt: Double, now: Date) -> Bool {
        let seconds = now.timeIntervalSince1970
        return expiresAt > seconds && expiresAt - seconds <= maximumLifetime
    }

    /// The fault `data` arms for this exact helper, or nil.
    static func fault(in data: Data?, version: String, helperSHA256: () -> String?, now: Date = Date()) -> String? {
        guard let data, let fault = try? JSONDecoder().decode(Fault.self, from: data), fault.version == version,
            ["crash", "hang"].contains(fault.fault), live(fault.expiresAt, now: now),
            fault.helperSHA256 == helperSHA256()
        else { return nil }
        return fault.fault
    }

    /// Whether `data` arms a kill at `checkpoint` for the CLI with `cdhash`.
    static func kill(in data: Data?, checkpoint: String, cdhash: () -> String?, now: Date = Date()) -> Bool {
        guard let data, let kill = try? JSONDecoder().decode(Kill.self, from: data), kill.checkpoint == checkpoint,
            live(kill.expiresAt, now: now)
        else { return false }
        return kill.cdhash == cdhash()
    }

    /// A fault file is present (reported whatever it names).
    public static func faultArmed() -> Bool {
        var info = stat()
        return lstat(faultFile.path, &info) == 0
    }

    public static func applyFault(version: String, executable: URL) {
        guard let data = try? RuntimeDurableFile.read(faultFile, maximumBytes: 1024, ownerUID: 0) else { return }
        switch fault(in: data, version: version, helperSHA256: { try? ManagedRuntimeInstaller.sha256(executable) }) {
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

    public static func killIfRequested(at checkpoint: String, cli: URL) {
        guard let data = try? RuntimeDurableFile.read(killFile, maximumBytes: 1024, ownerUID: 0),
            kill(in: data, checkpoint: checkpoint, cdhash: { RuntimeCodeIdentity.cdhash(cli) })
        else { return }
        // One shot: the re-run that finishes must not die here again.
        try? RuntimeDurableFile.remove(killFile)
        fputs("Release-gate kill at \(checkpoint)\n", stderr)
        Darwin.kill(getpid(), SIGKILL)
    }
}
