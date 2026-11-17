import Foundation

/// Which feed items this desktop build may install through the guarded,
/// workload-preserving updater.
///
/// `release/updater-policy.json` is the single source: `package_app.sh` writes
/// it into Info.plist, the feed scripts stamp it into every workload item, and a
/// test pins `fallback` to the same file.
struct UpdaterPolicy: Equatable, Sendable {
    static let minimumUpdateVersionKey = "MicropodMinimumUpdateVersion"
    static let workloadProtocolKey = "MicropodWorkloadProtocol"
    /// Enclosure attribute naming the workload protocol a feed item retains.
    static let enclosureWorkloadProtocolKey = "micropodWorkloadProtocol"
    /// The workload protocol this binary's code speaks with retained services.
    static let implementedWorkloadProtocol = 1
    /// The policy this binary implements, for bundles packaged without the keys.
    static let fallback = UpdaterPolicy(
        minimumUpdateVersion: "0.13.6", workloadProtocol: implementedWorkloadProtocol)

    /// The oldest installed version whose updater retains workload owners.
    let minimumUpdateVersion: String
    /// The workload protocol the retained services speak.
    let workloadProtocol: Int

    /// The packaged policy. An absent key falls back to the compiled policy;
    /// a present but malformed one admits nothing (nil).
    static func packaged(_ info: [String: Any]?) -> UpdaterPolicy? {
        let minimum = info?[minimumUpdateVersionKey] ?? fallback.minimumUpdateVersion
        let workload = info?[workloadProtocolKey] ?? fallback.workloadProtocol
        guard let minimum = minimum as? String, ReleaseVersion(minimum) != nil,
            let workload = workload as? Int, workload > 0
        else { return nil }
        return UpdaterPolicy(minimumUpdateVersion: minimum, workloadProtocol: workload)
    }

    static var current: UpdaterPolicy? { packaged(Bundle.main.infoDictionary) }

    /// Whether a bundle explicitly declares the workload protocol this code
    /// implements. Unlike `packaged`, an absent key is not enough: a bundle
    /// that does not declare the protocol must not adopt or retain services.
    static func declaresImplementedWorkloadProtocol(_ info: [String: Any]?) -> Bool {
        info?[workloadProtocolKey] as? Int == implementedWorkloadProtocol
    }

    static var bundleDeclaresImplementedWorkloadProtocol: Bool {
        declaresImplementedWorkloadProtocol(Bundle.main.infoDictionary)
    }

    /// Whether a feed item was published for this updater. Its floor must be a
    /// version no lower than ours, so items that would also admit updaters
    /// older than ours are not workload-preserving, while a later policy's
    /// higher floor still is. The running app must meet that floor, and the
    /// enclosure must name the protocol the retained services speak.
    func admits(itemMinimumUpdateVersion: String?, itemWorkloadProtocol: String?, appVersion: String?) -> Bool {
        guard let floor = itemMinimumUpdateVersion.flatMap(ReleaseVersion.init),
            let ours = ReleaseVersion(minimumUpdateVersion),
            let app = appVersion.flatMap(ReleaseVersion.init),
            let workload = itemWorkloadProtocol, workload == String(workloadProtocol)
        else { return false }
        return floor >= ours && app >= floor
    }

    /// `admits` for the running bundle and a Sparkle item's floor and enclosure.
    static func admitsFeedItem(minimumUpdateVersion: String?, enclosure: [String: Any]?) -> Bool {
        current?.admits(
            itemMinimumUpdateVersion: minimumUpdateVersion,
            itemWorkloadProtocol: enclosure?[enclosureWorkloadProtocolKey] as? String,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) == true
    }
}

/// A strict, canonical `major.minor.patch` release version. Leading zeros are
/// refused: released apps (0.13.6-0.13.8) compare the floor as an exact string,
/// so "0.013.6" would mean something different to them.
struct ReleaseVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                part == "0" || part.first != "0", let value = Int(part)
            else {
                return nil
            }
            components.append(value)
        }
        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
