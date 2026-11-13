import Foundation
import MicropodCore

public struct ServiceAccountRecord: Equatable, Sendable {
    public let name: String
    public let uid: UInt32
    public let gid: UInt32
    public let guid: UUID
    public let home: String
    public let shell: String
    public let comment: String
    public let hidden: Bool
    public let loginDisabled: Bool
    public init(
        name: String, uid: UInt32, gid: UInt32, guid: UUID, home: String, shell: String, comment: String, hidden: Bool,
        loginDisabled: Bool
    ) {
        self.name = name
        self.uid = uid
        self.gid = gid
        self.guid = guid
        self.home = home
        self.shell = shell
        self.comment = comment
        self.hidden = hidden
        self.loginDisabled = loginDisabled
    }
}

public enum ServiceAccountPlan {
    /// Allocation excludes both user and group IDs. A stored plan is reused
    /// after interruption; a foreign account is never silently adopted.
    public static func allocate(ownerUID: UInt32, occupiedUIDs: Set<UInt32>, occupiedGIDs: Set<UInt32>) throws
        -> IsolatedRuntimeIdentity
    {
        guard let uid = IsolatedRuntimePolicy.userIDs.first(where: { !occupiedUIDs.contains($0) }),
            let gid = IsolatedRuntimePolicy.userIDs.first(where: { !occupiedGIDs.contains($0) })
        else {
            throw MicropodError.message("No dedicated Micropod service account ID is available")
        }
        let identity = IsolatedRuntimeIdentity(
            instance: UUID(), ownerUID: ownerUID, serviceUID: uid, serviceGID: gid, accountGUID: UUID(),
            groupGUID: UUID())
        try identity.validate()
        return identity
    }

    public static func verify(_ record: ServiceAccountRecord, identity: IsolatedRuntimeIdentity) throws {
        try identity.validate()
        guard record.name == IsolatedRuntimePolicy.accountName, record.uid == identity.serviceUID,
            record.gid == identity.serviceGID, record.guid == identity.accountGUID,
            record.home == IsolatedRuntimePolicy.home.path, record.shell == "/usr/bin/false",
            record.comment == identity.accountComment, record.hidden, record.loginDisabled
        else {
            throw MicropodError.message(
                "The service account differs from Micropod's recorded identity; no account or runtime was changed")
        }
    }
}
