import Foundation

/// The approved helper and its workers must live outside the desktop bundle.
/// Existing setup installations are retained, including their exact version.
public enum RuntimeSetupInstallation {
    public static let installedURL = URL(fileURLWithPath: "/Applications/Micropod Runtime Setup.app")
    /// The executables of root `MicropodRuntimeHost` processes.
    public static func helperPrograms() -> [String] {
        UpdateServiceWitness.processIDs(executableName: "MicropodRuntimeHost").compactMap { pid in
            guard (try? RuntimeProcessBirth.read(pid))?.uid == 0 else { return nil }
            return UpdateServiceWitness.processPath(pid)
        }
    }

    public static func helperIsRunning() throws -> Bool {
        try UpdateServiceWitness.processIDs(executableName: "MicropodRuntimeHost").contains {
            try RuntimeProcessBirth.read($0)?.uid == 0
        }
    }
    public static func prepare(from desktop: URL) throws -> URL {
        try stage(
            source: desktop.appendingPathComponent("Contents/Helpers/Micropod Runtime Setup.app"),
            destination: installedURL, verify: verify)
    }

    static func stage(source: URL, destination: URL, verify: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try verify(destination)
            return destination
        }
        try verify(source)
        let parent = destination.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw MicropodError.message(
                "Administrator permission is needed to install Micropod Runtime Setup in Applications")
        }
        let staging = parent.appendingPathComponent(".micropod-runtime-setup-" + UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try verify(staging)
        do { try fm.moveItem(at: staging, to: destination) } catch {
            // Another installer may have published a valid setup app. Neither
            // participant may overwrite an installed helper's executable tree.
            guard fm.fileExists(atPath: destination.path) else { throw error }
            try verify(destination)
        }
        return destination
    }

    private static func verify(_ app: URL) throws {
        try RuntimeCodeIdentity.verifyExecutable(app, identifier: IsolatedRuntimePolicy.setupIdentifier)
        try RuntimeCodeIdentity.verifyExecutable(
            app.appendingPathComponent("Contents/MacOS/MicropodRuntimeHost"),
            identifier: IsolatedRuntimePolicy.helperIdentifier)
        try RuntimeCodeIdentity.verifyExecutable(
            app.appendingPathComponent("Contents/MacOS/MicropodAPI"),
            identifier: IsolatedRuntimeAPIConfiguration.executableIdentifier)
    }
}
