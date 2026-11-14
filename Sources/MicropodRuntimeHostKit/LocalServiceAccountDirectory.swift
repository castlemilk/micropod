import Darwin
import Foundation
import MicropodCore
import OpenDirectory

/// Local Directory Services only. It never assigns a password, login shell,
/// administrator membership, or access to the desktop user's home directory.
public struct LocalServiceAccountDirectory: ServiceAccountDirectory {
    public init() {}
    private func node() throws -> ODNode {
        guard geteuid() == 0 else {
            throw MicropodError.message("Approve Micropod's runtime helper in macOS Settings before setup")
        }
        return try ODNode(session: ODSession.default(), name: "/Local/Default")
    }
    private func record(type: String) throws -> ODRecord? {
        let query = try ODQuery(
            node: node(), forRecordTypes: type, attribute: kODAttributeTypeRecordName,
            matchType: ODMatchType(kODMatchEqualTo), queryValues: IsolatedRuntimePolicy.accountName,
            returnAttributes: kODAttributeTypeAllAttributes, maximumResults: 2)
        guard let records = try query.resultsAllowingPartial(false) as? [ODRecord], records.count <= 1 else {
            throw MicropodError.message("Service account lookup was ambiguous")
        }
        return records.first
    }
    private func text(_ record: ODRecord, _ attribute: String) throws -> String {
        guard let values = try record.values(forAttribute: attribute) as? [String], values.count == 1 else {
            throw MicropodError.message("Service account metadata is incomplete")
        }
        return values[0]
    }
    public func user() throws -> ServiceAccountRecord? {
        guard let record = try record(type: kODRecordTypeUsers) else { return nil }
        guard let uid = UInt32(try text(record, kODAttributeTypeUniqueID)),
            let gid = UInt32(try text(record, kODAttributeTypePrimaryGroupID)),
            let guid = UUID(uuidString: try text(record, kODAttributeTypeGUID))
        else {
            throw MicropodError.message("Service account identity is malformed")
        }
        let authority = try record.values(forAttribute: kODAttributeTypeAuthenticationAuthority) as? [String] ?? []
        return ServiceAccountRecord(
            name: try text(record, kODAttributeTypeRecordName), uid: uid, gid: gid, guid: guid,
            home: try text(record, kODAttributeTypeNFSHomeDirectory),
            shell: try text(record, kODAttributeTypeUserShell),
            comment: try text(record, kODAttributeTypeComment),
            hidden: try text(record, "dsAttrTypeNative:IsHidden") == "1",
            loginDisabled: authority == [";DisabledUser;"])
    }
    public func group() throws -> ServiceGroupRecord? {
        guard let record = try record(type: kODRecordTypeGroups) else { return nil }
        guard let gid = UInt32(try text(record, kODAttributeTypePrimaryGroupID)),
            let guid = UUID(uuidString: try text(record, kODAttributeTypeGUID))
        else {
            throw MicropodError.message("Service group identity is malformed")
        }
        return ServiceGroupRecord(
            name: try text(record, kODAttributeTypeRecordName), gid: gid, guid: guid,
            comment: try text(record, kODAttributeTypeComment))
    }
    public func occupiedIDs() throws -> (users: Set<UInt32>, groups: Set<UInt32>) {
        _ = try node()
        var users = Set<UInt32>()
        var groups = Set<UInt32>()
        for id in IsolatedRuntimePolicy.userIDs {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: 65536)
            guard getpwuid_r(id, &entry, &buffer, buffer.count, &result) == 0 else {
                throw MicropodError.message("macOS user identity inventory is unavailable")
            }
            if result != nil { users.insert(id) }
            var groupEntry = Darwin.group()
            var groupResult: UnsafeMutablePointer<Darwin.group>?
            guard getgrgid_r(id, &groupEntry, &buffer, buffer.count, &groupResult) == 0 else {
                throw MicropodError.message("macOS group identity inventory is unavailable")
            }
            if groupResult != nil { groups.insert(id) }
        }
        return (users, groups)
    }
    public func createGroup(identity: IsolatedRuntimeIdentity) throws {
        _ = try node().createRecord(
            withRecordType: kODRecordTypeGroups, name: IsolatedRuntimePolicy.accountName,
            attributes: [
                kODAttributeTypePrimaryGroupID: [String(identity.serviceGID)],
                kODAttributeTypeGUID: [identity.groupGUID.uuidString],
                kODAttributeTypeComment: [identity.accountComment], kODAttributeTypePassword: ["*"],
                kODAttributeTypeGroupMembership: [IsolatedRuntimePolicy.accountName],
                kODAttributeTypeGroupMembers: [identity.accountGUID.uuidString],
            ])
    }
    public func createUser(identity: IsolatedRuntimeIdentity) throws {
        _ = try node().createRecord(
            withRecordType: kODRecordTypeUsers, name: IsolatedRuntimePolicy.accountName,
            attributes: [
                kODAttributeTypeUniqueID: [String(identity.serviceUID)],
                kODAttributeTypePrimaryGroupID: [String(identity.serviceGID)],
                kODAttributeTypeGUID: [identity.accountGUID.uuidString],
                kODAttributeTypeNFSHomeDirectory: [IsolatedRuntimePolicy.home.path],
                kODAttributeTypeUserShell: ["/usr/bin/false"], kODAttributeTypeFullName: ["Micropod Container Runtime"],
                kODAttributeTypeComment: [identity.accountComment],
                kODAttributeTypeAuthenticationAuthority: [";DisabledUser;"],
                kODAttributeTypePassword: ["*"], "dsAttrTypeNative:IsHidden": ["1"],
            ])
    }
}
