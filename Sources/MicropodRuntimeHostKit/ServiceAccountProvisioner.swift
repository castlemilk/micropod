import Foundation
import MicropodCore

public struct ServiceGroupRecord: Equatable, Sendable {
    public let name: String
    public let gid: UInt32
    public let guid: UUID
    public let comment: String
    public init(name: String, gid: UInt32, guid: UUID, comment: String) {
        self.name = name
        self.gid = gid
        self.guid = guid
        self.comment = comment
    }
}

public protocol ServiceAccountDirectory: Sendable {
    func user() throws -> ServiceAccountRecord?
    func group() throws -> ServiceGroupRecord?
    func occupiedIDs() throws -> (users: Set<UInt32>, groups: Set<UInt32>)
    func createGroup(identity: IsolatedRuntimeIdentity) throws
    func createUser(identity: IsolatedRuntimeIdentity) throws
}

/// The complete identity is synchronized before the first directory mutation.
/// Recovery can complete only this exact account; it never allocates a second
/// uid or repairs an account it cannot prove belongs to the recorded instance.
public struct ServiceAccountProvisioner: Sendable {
    private let directory: any ServiceAccountDirectory
    private let journal: URL
    public init(directory: any ServiceAccountDirectory, journal: URL) {
        self.directory = directory
        self.journal = journal
    }

    public func prepare(ownerUID: UInt32) throws -> IsolatedRuntimeIdentity {
        let identity: IsolatedRuntimeIdentity
        if FileManager.default.fileExists(atPath: journal.path) {
            identity = try JSONDecoder().decode(
                IsolatedRuntimeIdentity.self, from: RuntimeDurableFile.read(journal, maximumBytes: 8192))
            try identity.validate()
            guard identity.ownerUID == ownerUID else {
                throw MicropodError.message("This managed runtime belongs to another macOS account")
            }
        } else {
            guard try directory.user() == nil, try directory.group() == nil else {
                throw MicropodError.message(
                    "The _micropod account or group already exists without a matching Micropod journal; it was left unchanged"
                )
            }
            let occupied = try directory.occupiedIDs()
            identity = try ServiceAccountPlan.allocate(
                ownerUID: ownerUID, occupiedUIDs: occupied.users, occupiedGIDs: occupied.groups)
            try RuntimeDurableFile.write(identity, to: journal)
        }
        if let user = try directory.user() { try ServiceAccountPlan.verify(user, identity: identity) }
        if let group = try directory.group() {
            try verify(group, identity: identity)
        } else {
            try directory.createGroup(identity: identity)
        }
        guard let group = try directory.group() else {
            throw MicropodError.message("Service group creation is unconfirmed")
        }
        try verify(group, identity: identity)
        if try directory.user() == nil { try directory.createUser(identity: identity) }
        guard let user = try directory.user() else {
            throw MicropodError.message("Service account creation is unconfirmed")
        }
        try ServiceAccountPlan.verify(user, identity: identity)
        return identity
    }

    private func verify(_ group: ServiceGroupRecord, identity: IsolatedRuntimeIdentity) throws {
        guard group.name == IsolatedRuntimePolicy.accountName, group.gid == identity.serviceGID,
            group.guid == identity.groupGUID, group.comment == identity.accountComment
        else {
            throw MicropodError.message(
                "The service group differs from Micropod's recorded identity; no account was changed")
        }
    }
}
