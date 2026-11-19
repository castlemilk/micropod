import Foundation

/// If refresh and its rollback both fail, the private directory holds displaced
/// entries. Report its location and keep it for the owner.
struct SharedFSStagingRecovery: LocalizedError {
    let directory: URL
    var errorDescription: String? {
        "Refresh could not restore every entry. Recover previous entries at \(directory.path)."
    }
}

/// A private sibling on the destination filesystem, so publication can use
/// one rename. Only this operation's scratch directory is ever removed.
func withSharedFSStaging<T>(beside destination: URL, _ body: (URL) throws -> T) throws -> T {
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let staging = parent.appendingPathComponent(".sharedfs-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var removeStaging = true
    defer { if removeStaging { try? FileManager.default.removeItem(at: staging) } }
    do {
        return try body(staging.appendingPathComponent("snapshot"))
    } catch let recovery as SharedFSStagingRecovery {
        removeStaging = false
        throw recovery
    }
}
