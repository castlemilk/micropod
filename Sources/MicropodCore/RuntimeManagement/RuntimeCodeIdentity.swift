import Darwin
import Foundation
import Security

public enum RuntimeCodeIdentity {
    /// Compare the running code directory with the payload on disk. A valid
    /// signature at the same path alone could name a replacement file while
    /// the process still executes an earlier build.
    public static func processMatchesExecutable(
        _ pid: Int32, url: URL, identifier: String,
        team: String = IsolatedRuntimePolicy.teamIdentifier
    ) -> Bool {
        guard verifyProcess(pid, identifier: identifier, team: team) else { return false }
        var dynamic: SecCode?
        var running: SecStaticCode?
        var disk: SecStaticCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary,
                [], &dynamic) == errSecSuccess, let dynamic,
            SecCodeCopyStaticCode(dynamic, [], &running) == errSecSuccess, let running,
            SecStaticCodeCreateWithPath(url as CFURL, [], &disk) == errSecSuccess, let disk
        else { return false }
        func hash(_ code: SecStaticCode) -> Data? {
            var information: CFDictionary?
            guard
                SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                    == errSecSuccess
            else { return nil }
            return (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        }
        guard let liveHash = hash(running), let diskHash = hash(disk) else { return false }
        return liveHash == diskHash
    }
    /// XPC verifies every message against this requirement, including replies.
    /// This public API binds live code identity without a racy PID/path check.
    public static func require(_ connection: xpc_connection_t, identifiers: [String]) throws {
        let names = identifiers.map { "identifier \"" + $0 + "\"" }.joined(separator: " or ")
        let rule =
            "anchor apple generic and certificate leaf[subject.OU] = \"" + IsolatedRuntimePolicy.teamIdentifier
            + "\" and (" + names + ")"
        guard xpc_connection_set_peer_code_signing_requirement(connection, rule) == 0 else {
            throw MicropodError.message("Could not configure runtime helper peer authentication")
        }
    }

    public static func verifyProcess(
        _ pid: Int32, identifier: String, team: String = IsolatedRuntimePolicy.teamIdentifier
    ) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let rule =
            "anchor apple generic and certificate leaf[subject.OU] = \"" + team
            + "\" and identifier \"" + identifier + "\""
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), requirement)
            == errSecSuccess
    }

    public static func verifyExecutable(
        _ url: URL, identifier: String, team: String = IsolatedRuntimePolicy.teamIdentifier
    ) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule =
            "anchor apple generic and certificate leaf[subject.OU] = \"" + team
            + "\" and identifier \"" + identifier + "\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)), requirement)
                == errSecSuccess
        else {
            throw MicropodError.message("Micropod's runtime helper code signature could not be verified")
        }
    }
}
