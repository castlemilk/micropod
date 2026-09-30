/// The micropod release this binary belongs to. scripts/package_app.sh stamps
/// it for the build and restores it after; local builds say "dev".
public enum MicropodBuildInfo {
    public static let version = "dev"
}
