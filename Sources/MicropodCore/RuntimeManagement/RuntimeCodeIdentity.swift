import Darwin
import Foundation
import Security

public enum RuntimeCodeIdentity {
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

    public static func verifyProcess(_ pid: Int32, identifier: String) -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let rule =
            "anchor apple generic and certificate leaf[subject.OU] = \"" + IsolatedRuntimePolicy.teamIdentifier
            + "\" and identifier \"" + identifier + "\""
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), requirement)
            == errSecSuccess
    }

    public static func verifyExecutable(_ url: URL, identifier: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule =
            "anchor apple generic and certificate leaf[subject.OU] = \"" + IsolatedRuntimePolicy.teamIdentifier
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
