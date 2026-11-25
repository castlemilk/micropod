import Darwin
import Foundation
import MicropodCore

/// `<root>/run/containers.json`: the ids and names of the containers on the
/// machine's disk. The engine keeps it (create, run and delete record and
/// drop entries; every listing while the machine serves replaces it), so
/// `HVFEngine.owns` can route an id-based call to hvf while the machine is
/// stopped or starting, without booting it or asking the guest.
///
/// Advisory only: a missing, unreadable or newer-schema file reads as an
/// empty index, and a stale entry only makes hvf claim an id the guest no
/// longer has (the guest's 404 then drops it).
struct HVFContainerIndex: Codable, Sendable, Equatable {
    static let currentSchema = 1

    struct Entry: Codable, Sendable, Equatable {
        /// The guest engine's full container id.
        var id: String
        /// The container's name, when known.
        var name: String?
        /// When it was recorded. A refresh keeps entries recorded after its
        /// listing was taken, so a create racing a listing is not lost.
        var recordedAt: Date
    }

    var schema = Self.currentSchema
    var containers: [Entry] = []

    /// The entry `key` names, resolved the way the guest engine resolves a
    /// container reference: exact id, then exact name, then a unique id
    /// prefix of at least four characters. nil when nothing matches or a
    /// prefix is ambiguous (the guest answers 409, so it is not owned).
    func entry(for key: String) -> Entry? {
        guard !key.isEmpty else { return nil }
        if let exact = containers.first(where: { $0.id == key }) { return exact }
        if let named = containers.first(where: { $0.name == key }) { return named }
        guard key.count >= 4 else { return nil }
        let prefixed = containers.filter { $0.id.hasPrefix(key) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// A container the engine just created. Any entry with the same id or
    /// name is gone: the guest refuses a duplicate name.
    mutating func record(id: String, name: String?, at date: Date = Date()) {
        containers.removeAll { $0.id == id || (name != nil && $0.name == name) }
        containers.append(Entry(id: id, name: name, recordedAt: date))
    }

    /// Drops the container `key` names (after a delete, or a guest 404).
    mutating func remove(_ key: String) {
        guard let entry = entry(for: key) else { return }
        containers.removeAll { $0.id == entry.id }
    }

    /// Replaces the index with a full guest listing taken at `listedAt`,
    /// keeping entries recorded since then that the listing predates.
    mutating func refresh(from listing: [(id: String, name: String?)], listedAt: Date) {
        let listed = Set(listing.map(\.id))
        let newer = containers.filter { $0.recordedAt > listedAt && !listed.contains($0.id) }
        containers = listing.map { Entry(id: $0.id, name: $0.name, recordedAt: listedAt) } + newer
    }

    /// Same containers, ignoring when they were recorded.
    func sameContainers(as other: HVFContainerIndex) -> Bool {
        func key(_ entry: Entry) -> String { "\(entry.id)\u{0}\(entry.name ?? "")" }
        return Set(containers.map(key)) == Set(other.containers.map(key))
    }
}

/// Reads and updates one root's `HVFContainerIndex`. Updates are atomic
/// (temporary file + rename) and serialised across processes by
/// `run/containers.lock`; an update that cannot take the lock promptly or
/// write the file is skipped, never an error for the call that made it.
struct HVFContainerIndexStore: Sendable {
    let layout: HVFMachineLayout

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The index on disk; empty when it is missing or unreadable.
    func load() -> HVFContainerIndex {
        guard let data = try? Data(contentsOf: layout.containerIndex),
            let index = try? Self.decoder.decode(HVFContainerIndex.self, from: data),
            index.schema == HVFContainerIndex.currentSchema
        else { return HVFContainerIndex() }
        return index
    }

    /// Applies `body` to the current index and writes the result when the
    /// set of containers changed. Best-effort.
    func update(_ body: (inout HVFContainerIndex) -> Void) {
        // The run directory exists once the machine has ever started; never
        // create a root just to index it.
        guard FileManager.default.fileExists(atPath: layout.runDirectory.path),
            let lock = try? HVFFileLock.acquire(layout.containerIndexLock, wait: .seconds(1))
        else { return }
        defer { lock.release() }
        let current = load()
        var updated = current
        body(&updated)
        guard !updated.sameContainers(as: current) else { return }
        try? HVFFiles.writeAtomically(Self.encoder.encode(updated), to: layout.containerIndex)
    }

    /// Forgets every container (a new machine disk holds none).
    func reset() throws {
        if unlink(layout.containerIndex.path) != 0, errno != ENOENT {
            throw HVFFiles.posixError("remove \(layout.containerIndex.path)")
        }
    }
}
