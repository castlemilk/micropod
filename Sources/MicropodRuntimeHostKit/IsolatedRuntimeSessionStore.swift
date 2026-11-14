import Darwin
import Foundation
import MicropodCore
import Security

public enum IsolatedRuntimeSessionStore {
    public static func hasExistingRig(ownerUID: UInt32) throws -> Bool {
        var user = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bytes = [CChar](repeating: 0, count: 65536)
        guard getpwuid_r(ownerUID, &user, &bytes, bytes.count, &result) == 0,
            result != nil, let home = user.pw_dir
        else { throw MicropodError.message("The runtime owner's home is unavailable") }
        let root = URL(fileURLWithPath: String(cString: home))
        return [
            ".cuttlefish/runner-state/micropod-maintenance.sock", ".cuttlefish/agent-desktop-state.json",
            ".cuttlefish/desktop-state.json", "Library/LaunchAgents/dev.cuttlefish.agent.desktop.plist",
            "Library/LaunchAgents/dev.cuttlefish.agent.hostlocal.plist",
        ].contains {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }
    public static func issue(identity: IsolatedRuntimeIdentity, subject: RuntimeProcessBirth) throws
        -> IsolatedRuntimeAPISession
    {
        guard geteuid() == 0, subject.uid == identity.ownerUID, try RuntimeProcessBirth.read(subject.pid) == subject
        else {
            throw MicropodError.message("The API client process identity is unavailable")
        }
        try RootRuntimeStorage.ensureRootDirectory(IsolatedRuntimeAPIConfiguration.sessionsRoot)
        let session = IsolatedRuntimeAPISession(
            id: UUID(), instance: identity.instance, token: try secret(), subject: subject,
            expiresAt: Date().addingTimeInterval(3600))
        let file = IsolatedRuntimeAPIConfiguration.sessionsRoot.appendingPathComponent(session.id.uuidString + ".json")
        try RuntimeDurableFile.write(IsolatedRuntimeAPISessionRecord(session: session), to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        return session
    }
    public static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MicropodError.message("Could not create an API client capability")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
    }
}
