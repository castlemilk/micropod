import Darwin
import Foundation
import Security

public enum RuntimeCodeIdentity {
    /// Developer ID Application, issued under Apple's Developer ID CA, for
    /// `team`. Without the two certificate markers any Apple-anchored
    /// certificate with that team's OU (an Apple Development certificate, for
    /// one) would satisfy the requirement.
    public static func developerID(_ team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \""
            + team + "\""
    }

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
            developerID(IsolatedRuntimePolicy.teamIdentifier) + " and (" + names + ")"
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
            developerID(team) + " and identifier \"" + identifier + "\""
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), requirement)
            == errSecSuccess
    }

    /// A whole bundle: Micropod's Developer ID, `identifier`, every nested
    /// executable and sealed resource (strict), and, when `notarized`, Apple's
    /// notarization ticket (stapled, or looked up online for nested code).
    public static func verifyBundle(
        _ url: URL, identifier: String, notarized: Bool, team: String = IsolatedRuntimePolicy.teamIdentifier
    ) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule =
            developerID(team) + " and identifier \"" + identifier + "\"" + (notarized ? " and notarized" : "")
        let flags = kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(flags)), requirement) == errSecSuccess
        else {
            throw MicropodError.message(
                "\(url.lastPathComponent) is not Micropod's sealed\(notarized ? ", notarized" : "") release")
        }
    }

    /// The code directory hash (`codesign -dvvv` CDHash) of a bundle or
    /// executable, as lowercase hex.
    public static func cdhash(_ url: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyExecutable(
        _ url: URL, identifier: String, team: String = IsolatedRuntimePolicy.teamIdentifier
    ) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule =
            developerID(team) + " and identifier \"" + identifier + "\""
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
