import Foundation

extension Bundle {
    /// The SwiftPM resource bundle (brandbrain artwork, strings catalog).
    ///
    /// In the packaged .app it lives at `Contents/Resources/` — the bundle
    /// root is off-limits there because codesign rejects unsealed contents.
    /// In `.build` dev/test trees it sits next to the binary, which the
    /// generated `Bundle.module` accessor already knows how to find.
    static let micropodResources: Bundle = {
        let name = "Micropod_MicropodApp.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            let url = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return .module
    }()
}
