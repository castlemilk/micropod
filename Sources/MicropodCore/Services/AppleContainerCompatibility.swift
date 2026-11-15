/// Native API release lines already validated by Micropod. See
/// docs/native-runtime.md for the wire-protocol audit behind this gate.
public enum AppleContainerCompatibility {
    public static let supportedVersions: Set<String> = ["1.3.1"]
    public static let verifiedReleaseLines: [String] = ["1.3.", "1.4.", "1.5."]

    public static func isVerified(semver: String) -> Bool {
        let components = semver.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
            components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return false }
        return supportedVersions.contains(semver) || verifiedReleaseLines.contains { semver.hasPrefix($0) }
    }
}
