import CPtyShim
import Darwin
import Foundation
import MicropodCore
import Security

/// A vanished worker alone is insufficient: a CLI/launchctl descendant could
/// still deliver a late stop. Only the fixed Apple daemons, managed API and
/// Apple's platform services may remain when an action is reconciled.
public enum IsolatedRuntimeProcessInventory {
    public static func assertSettled(identity: IsolatedRuntimeIdentity, selection: ManagedRuntimeLocation.Selection)
        throws
    {
        guard geteuid() == 0 else { throw refused() }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = micropod_uid_processes(identity.serviceUID, &pids, Int32(pids.count))
        guard count >= 0 else { throw refused() }
        let root = RootRuntimeStorage.apple.appendingPathComponent("versions/" + selection.directoryName)
        let daemons = Set(
            AppleRuntimeRelease.payloadSHA256.keys.filter {
                $0 == "bin/container-apiserver" || ($0.hasPrefix("libexec/container/plugins/") && $0.contains("/bin/"))
            }.map { root.appendingPathComponent($0).path })
        let configuration = try? IsolatedRuntimeAPIConfiguration.read(identity: identity)
        let api = configuration.map {
            IsolatedRuntimePolicy.root.appendingPathComponent("tools/" + $0.toolDirectoryName + "/MicropodAPI").path
        }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let before = try RuntimeProcessBirth.read(pid) else { continue }
            guard before.uid == identity.serviceUID else { throw refused() }
            var path = [CChar](repeating: 0, count: 4096)
            let result = micropod_process_path(pid, &path, Int32(path.count))
            if result == 1 { continue }
            if result != 0 {
                if try before.hasExited() { continue }
                throw refused()
            }
            let executable = String(
                decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let after = try RuntimeProcessBirth.read(pid) else { continue }
            guard before == after else { throw refused() }
            if daemons.contains(executable) || executable == api { continue }
            if executable.hasPrefix("/System/Library/") || executable.hasPrefix("/usr/libexec/")
                || executable == "/usr/sbin/cfprefsd", isApplePlatformProcess(pid)
            {
                continue
            }
            throw refused()
        }
    }
    private static func isApplePlatformProcess(_ pid: pid_t) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), requirement)
            == errSecSuccess
    }
    private static func refused() -> Error {
        MicropodError.message(
            "A private runtime client or late action remains unconfirmed; no lifecycle action was retried")
    }
}
