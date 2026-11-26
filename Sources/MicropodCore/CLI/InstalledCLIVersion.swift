import Darwin
import Foundation

/// The version of an Apple `container` CLI that the macOS installer put in
/// place, read from the installer's receipt instead of running
/// `container system version`.
///
/// The receipt is believed only for the file the installer wrote: the
/// executable must be the receipt's install prefix plus `bin/container`,
/// a regular file rather than a symlink, and its inode must not have changed
/// since the install finished. The kernel sets ctime to the current time on
/// every write, chmod, rename, link or copy over it, and nothing can set it
/// back, so a CLI replaced or edited after the install has a ctime later
/// than the receipt's `InstallDate` and is asked directly, as before. A newer
/// package install rewrites both.
public enum InstalledCLIVersion {
    public static let receipt = URL(fileURLWithPath: "/var/db/receipts/com.apple.container-installer.plist")

    /// The installer finishes writing files just before it records the
    /// receipt; allow for that.
    public static let slack: TimeInterval = 5

    /// The receipt's `PackageVersion` when `executable` is the file that
    /// install wrote; nil when it is not (or the receipt does not say).
    public static func version(of executable: URL, receipt: URL = receipt) -> String? {
        guard let data = try? Data(contentsOf: receipt),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let version = plist["PackageVersion"] as? String, !version.isEmpty,
            let installed = plist["InstallDate"] as? Date
        else { return nil }
        let prefix = (plist["InstallPrefixPath"] as? String ?? "").trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        let expected = "/" + (prefix.isEmpty ? "" : prefix + "/") + "bin/container"
        guard executable.standardizedFileURL.path == expected else { return nil }
        var metadata = stat()
        guard lstat(expected, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else { return nil }
        let changed = TimeInterval(metadata.st_ctimespec.tv_sec) + TimeInterval(metadata.st_ctimespec.tv_nsec) / 1e9
        guard changed <= installed.timeIntervalSince1970 + slack else { return nil }
        return version
    }
}
