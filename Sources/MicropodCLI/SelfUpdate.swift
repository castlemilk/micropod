import Crypto
import Foundation
import MicropodBuildInfo
import MicropodCore
import MicropodRuntime
import Security

/// Updates a standalone CLI install (one not linked into the app bundle)
/// from the release channel the app's Sparkle updater reads:
/// 1. The appcast names the newest version, its DMG, and the DMG's EdDSA
///    signature.
/// 2. The DMG is checked against Sparkle's public key, the one baked into
///    the app — the channel can't hand out anything the release key didn't
///    sign.
/// 3. `micropod-cli`, `MicropodMCP` and `MicropodAPI` (those installed) are
///    copied out of the signed app inside, and must carry the release's
///    Developer ID signature; the new CLI must report the release version.
/// 4. With an HVF machine installed, the app's HVF payload is staged (never
///    activated: `micropod update hvf apply` boots and verifies it). A
///    release without one, or a failed stage, fails the update.
/// 5. Only then are the installed files replaced, each by a rename, keeping
///    `.bak` copies; if one replacement fails, the ones made are undone and
///    the HVF stage is dropped. A running `micropod` keeps its old image.
enum SelfUpdate {
    static let feedURL = URL(string: "https://castlemilk.github.io/micropod/appcast.xml")!
    /// The app's `SUPublicEDKey` (scripts/package_app.sh).
    static let publicKey = "nJEL+JijqhfC7zxPlqxifCqBM06A3DGki/JmBFTW/VM="
    /// Code signing requirement for binaries taken from a release: Developer
    /// ID, micropod's team.
    static let requirement = #"anchor apple generic and certificate leaf[subject.OU] = "WFTX6CN23F""#

    struct Release: Equatable {
        let version: ReleaseVersion
        let url: URL
        let signature: Data
        let length: Int
        /// The commit the release was built from (`micropodSourceRevision`),
        /// when the feed declares it. A rig upgrade requires it.
        var sourceRevision: String? = nil

        static func == (a: Release, b: Release) -> Bool { a.version == b.version && a.url == b.url }
    }

    /// The newest release the feed describes.
    static func latest(feed: URL = feedOverride ?? feedURL) async throws -> Release {
        var request = URLRequest(url: feed)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MicropodError.message(
                "the release feed \(feed) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let newest = try parseFeed(data).max(by: { $0.version < $1.version }) else {
            throw MicropodError.message("the release feed lists no releases")
        }
        return newest
    }

    /// For tests of the feed plumbing only: the signature key can't be
    /// overridden, so another feed can't install anything unsigned.
    static var feedOverride: URL? {
        ProcessInfo.processInfo.environment["MICROPOD_UPDATE_FEED"].flatMap(URL.init(string:))
    }

    /// Sparkle appcast items: version, enclosure url, edSignature, length.
    static func parseFeed(_ data: Data) throws -> [Release] {
        let parser = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else {
            throw MicropodError.message(
                "the release feed isn't valid XML: \(xml.parserError?.localizedDescription ?? "?")")
        }
        return parser.items.compactMap { item in
            guard
                let version = (item["sparkle:shortVersionString"] ?? item["sparkle:version"]).flatMap(
                    ReleaseVersion.init),
                let url = item["url"].flatMap(URL.init(string:)), url.scheme == "https",
                let signature = item["sparkle:edSignature"].flatMap({ Data(base64Encoded: $0) }),
                let length = item["length"].flatMap(Int.init), length > 0
            else { return nil }
            let revision = item["micropodSourceRevision"].flatMap {
                $0.range(of: "^[0-9a-f]{40}$", options: .regularExpression) == nil ? nil : $0
            }
            return Release(
                version: version, url: url, signature: signature, length: length, sourceRevision: revision)
        }
    }

    /// Whether `signature` is the release key's EdDSA signature of `data`.
    static func verify(_ data: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Whether the binary at `path` is signed to satisfy `requirement`.
    static func hasValidSignature(_ path: URL, requirement text: String = requirement) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
            == errSecSuccess
    }

    // MARK: Installing

    /// The files a standalone install consists of: the CLI itself, and the
    /// MCP and API servers beside it when present (`micropod-mcp-bin` behind
    /// the install.sh wrapper or a plain `micropod-mcp` binary;
    /// `micropod-api-bin` or `micropod-api`).
    static func installedFiles(cli: URL) -> [(bundled: String, path: URL)] {
        let dir = cli.deletingLastPathComponent()
        var files = [("micropod-cli", cli)]
        for (bundled, names) in [
            ("MicropodMCP", ["micropod-mcp-bin", "micropod-mcp"]),
            ("MicropodAPI", ["micropod-api-bin", "micropod-api"]),
        ] {
            if let path = names.map(dir.appendingPathComponent).first(where: isMachO) {
                files.append((bundled, path))
            }
        }
        return files
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 4) else {
            return false
        }
        try? handle.close()
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE]].contains(Array(head))
    }

    /// Downloads, verifies and installs `release` over the files at `cli`.
    static func install(_ release: Release, cli: URL, progress: @Sendable (String) -> Void) async throws {
        let files = installedFiles(cli: cli)
        let dir = cli.deletingLastPathComponent()
        guard access(dir.path, W_OK) == 0 else {
            throw MicropodError.message("can't write \(dir.path) — run as its owner")
        }
        progress("downloading Micropod \(release.version) (\(ByteFormat.string(Int64(release.length))))…")
        let (download, response) = try await URLSession.shared.download(from: release.url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MicropodError.message("download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let data = try Data(contentsOf: download, options: .alwaysMapped)
        guard data.count == release.length else {
            throw MicropodError.message("download is \(data.count) bytes, the feed says \(release.length)")
        }
        guard verify(data, signature: release.signature) else {
            throw MicropodError.message("the download's signature doesn't match the release key — not installing it")
        }
        progress("signature verified; unpacking")

        let mount = FileManager.default.temporaryDirectory.appendingPathComponent(
            "micropod-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path, download.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }
        try installRelease(
            from: mount.appendingPathComponent("Micropod.app"), version: release.version,
            revision: release.sourceRevision, files: files, hvf: HVFMachineLayout(), progress: progress)
    }

    /// How `installRelease` checks what it takes from a release; replaced in tests.
    struct ReleaseChecks: Sendable {
        /// The binary carries the release's Developer ID signature.
        var signedByRelease: @Sendable (URL) -> Bool
        /// What `<cli> version` prints.
        var reportedVersion: @Sendable (URL) throws -> String
        /// Require the hypervisor entitlement on the staged micropod-vmm.
        var hvfEntitlement: Bool

        static let live = ReleaseChecks(
            signedByRelease: { SelfUpdate.hasValidSignature($0) },
            reportedVersion: { try SelfUpdate.output($0.path, ["version"]) }, hvfEntitlement: true)
    }

    /// Whether `layout` holds an HVF machine whose payload this update must keep in step.
    static func hvfInstalled(_ layout: HVFMachineLayout) -> Bool {
        layout.resolvePayload().hasBootAssets || HVFPayloadStore.status(layout: layout).staged != nil
    }

    /// Replaces `files` from the app bundle `app` and stages its HVF payload
    /// into `hvf` (when an HVF machine is installed there), all or nothing:
    /// every binary is copied beside its target and checked, and the HVF
    /// payload staged, before anything installed is replaced.
    static func installRelease(
        from app: URL, version: ReleaseVersion, revision: String?, files: [(bundled: String, path: URL)],
        hvf: HVFMachineLayout?, checks: ReleaseChecks = .live, progress: @Sendable (String) -> Void
    ) throws {
        let fm = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS")
        var staged: [(from: URL, to: URL)] = []
        defer { for item in staged { try? fm.removeItem(at: item.from) } }
        for (bundled, target) in files {
            let source = macOS.appendingPathComponent(bundled)
            guard fm.isExecutableFile(atPath: source.path) else {
                throw MicropodError.message("Micropod \(version) doesn't carry \(bundled) in its app bundle")
            }
            guard checks.signedByRelease(source) else {
                throw MicropodError.message("\(bundled) in Micropod \(version) isn't signed by micropod's Developer ID")
            }
            // Staged beside the target (same volume), so the swap is a rename.
            let staging = target.deletingLastPathComponent()
                .appendingPathComponent(".\(target.lastPathComponent).update-\(getpid())")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: source, to: staging)
            staged.append((staging, target))
        }
        if let cli = staged.first {
            let reported = try checks.reportedVersion(cli.from)
            guard reported.contains(version.description) else {
                throw MicropodError.message(
                    "the new micropod reports \"\(reported.trimmingCharacters(in: .whitespacesAndNewlines))\", not \(version)"
                )
            }
        }

        // The HVF payload is staged, never activated: `update hvf apply`
        // boots and verifies it while the machine is idle.
        var stagedHVF: HVFPayloadManifest?
        if let hvf, hvfInstalled(hvf) {
            do {
                _ = try HVFPayloadStore.resolveAssets(from: .directory(app))
            } catch {
                throw MicropodError.message(
                    "Micropod \(version) carries no HVF runtime payload (\(error.localizedDescription)); not "
                        + "installing it, or this CLI would no longer match the HVF machine under \(hvf.root.path)")
            }
            stagedHVF = try HVFPayloadStore.stage(
                from: .directory(app), version: version.description, revision: revision ?? "unknown", layout: hvf,
                verifySignature: checks.hvfEntitlement, progress: progress)
        }

        var swapped: [(target: URL, backup: URL)] = []
        do {
            for (from, to) in staged {
                let backup = to.appendingPathExtension("bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: to, to: backup)
                guard rename(from.path, to.path) == 0 else {
                    throw MicropodError.message("replacing \(to.path): \(String(cString: strerror(errno)))")
                }
                swapped.append((to, backup))
            }
        } catch {
            // Back to the old set: never some binaries of each release.
            for item in swapped.reversed() where rename(item.backup.path, item.target.path) != 0 {
                progress("WARNING: could not restore \(item.target.path) from \(item.backup.path)")
            }
            if let hvf, let stagedHVF { try? HVFPayloadStore.unstage(layout: hvf, manifest: stagedHVF) }
            throw error
        }
        staged.removeAll()

        guard let hvf, let stagedHVF else { return }
        do {
            let removed = try HVFPayloadStore.pruneVersions(layout: hvf, keep: 2)
            if !removed.isEmpty { progress("pruned old HVF payloads: \(removed.joined(separator: ", "))") }
        } catch {
            progress("note: old HVF payloads were not pruned: \(error.localizedDescription)")
        }
        progress(
            "staged HVF runtime payload \(stagedHVF.version) — `micropod update hvf apply` boots, verifies and "
                + "activates it when the machine is idle")
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) throws -> String {
        try output(path, arguments)
    }

    static func output(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MicropodError.message(
                "\(URL(fileURLWithPath: path).lastPathComponent) \(arguments.first ?? ""): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return text
    }
}

/// Collects each `<item>`'s version elements and enclosure attributes.
private final class AppcastParser: NSObject, XMLParserDelegate {
    var items: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        if name == "item" {
            current = [:]
        } else if name == "enclosure", current != nil {
            for (key, value) in attributes { current?[key] = value }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let item = current {
            items.append(item)
            current = nil
        } else if current != nil, name.hasPrefix("sparkle:") {
            current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// A once-a-day, cached "a newer micropod is out" line after interactive
/// commands. The check itself runs in a detached child (`micropod update
/// --refresh`), so no command ever waits on the network.
enum UpdateNotice {
    static var cacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".micropod/cli-update-check.json")
    }
    static let interval: TimeInterval = 86400

    struct Cache: Codable {
        var checkedAt: Date
        var latest: String?
    }

    static func load() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    static func save(_ cache: Cache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Whether this invocation may print a notice: a person at a terminal,
    /// not a script, CI or a JSON consumer.
    static func applies(json: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !json && isatty(STDERR_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 && environment["CI"] == nil
            && environment["MICROPOD_NO_UPDATE_NOTIFIER"] == nil && ReleaseVersion(MicropodBuildInfo.version) != nil
    }

    /// The notice for `latest` against the running version, if newer.
    static func message(latest: String?, kind: CLIInstall.Kind, current: String = MicropodBuildInfo.version) -> String?
    {
        guard let latest, let newer = ReleaseVersion(latest), let running = ReleaseVersion(current), running < newer
        else {
            return nil
        }
        switch kind {
        case .appManaged:
            return "micropod \(newer) is out (this is \(running)) — it comes with the app's update; "
                + "`micropod update apply` restarts into it once downloaded"
        case .standalone:
            return "micropod \(newer) is out (this is \(running)) — `micropod update cli` installs it"
        case .development:
            return nil
        }
    }

    /// Prints the cached notice, and starts a background refresh when the
    /// cache is a day old.
    static func run(json: Bool) {
        guard applies(json: json) else { return }
        let cache = load()
        if let text = message(latest: cache?.latest, kind: CLIInstall.kind(of: CLIInstall.currentExecutable())) {
            FileHandle.standardError.write(Data("\n\(text)\n".utf8))
        }
        guard (cache.map { Date().timeIntervalSince($0.checkedAt) > interval }) ?? true else { return }
        // Claim the slot first, so a burst of commands spawns one check.
        save(Cache(checkedAt: Date(), latest: cache?.latest))
        let child = Process()
        child.executableURL = CLIInstall.currentExecutable()
        child.arguments = ["update", "--refresh"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
    }

    /// `micropod update --refresh`: fetch the feed and cache its newest version.
    static func refresh() async {
        guard let release = try? await SelfUpdate.latest() else { return }
        save(Cache(checkedAt: Date(), latest: release.version.description))
    }
}
