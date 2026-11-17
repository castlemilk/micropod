import Crypto
import Foundation
import MicropodCore

/// Fetches the newest release off the critical path and leaves it verified
/// and unpacked in `~/.micropod/releases/<version>-<revision>/`. Every network
/// and verification failure happens here, before anything is disrupted.
struct RigReleaseStager {
    var layout: RigUpgradeLayout
    var publicKey = SelfUpdate.publicKey
    var verifier: any RigBundleVerifying = RigCodeSignatureVerifier()
    /// Downloads `url` to a local file.
    var download: @Sendable (URL, URL) async throws -> Void = { url, destination in
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw MicropodError.message("download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
    /// Copies `Micropod.app` out of a verified disk image.
    var extract: @Sendable (URL, URL) throws -> Void = { image, destination in
        let mount = image.deletingLastPathComponent().appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try SelfUpdate.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", mount.path, image.path])
        defer { _ = try? SelfUpdate.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        try SelfUpdate.run("/usr/bin/ditto", [mount.appendingPathComponent("Micropod.app").path, destination.path])
    }
    var progress: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("\($0)\n".utf8)) }

    /// The newest release `feed` offers.
    func latest(feed: URL) async throws -> SelfUpdate.Release { try await SelfUpdate.latest(feed: feed) }

    func stage(_ release: SelfUpdate.Release) async throws -> RigStagedRelease {
        guard let revision = release.sourceRevision else {
            throw MicropodError.message(
                "Micropod \(release.version) does not declare its source revision in the feed, so it cannot be "
                    + "staged for a rig upgrade")
        }
        let fm = FileManager.default
        let directory = layout.releasesRoot.appendingPathComponent(
            release.version.description + "-" + String(revision.prefix(12)))
        if let marker = RigStagedRelease.read(directory), marker.identity.version == release.version.description,
            marker.identity.revision == revision, marker.identity.matches(marker.bundle(in: layout))
        {
            try verifier.verifyApp(marker.bundle(in: layout))
            progress("Micropod \(release.version) is already staged at \(directory.path)")
            return marker
        }
        try fm.createDirectory(
            at: layout.releasesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Beside the release directory, so the bundle moves in with a rename.
        let work = layout.releasesRoot.appendingPathComponent(".download-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let image = work.appendingPathComponent("Micropod.dmg")
        progress("downloading Micropod \(release.version) (\(ByteFormat.string(Int64(release.length))))…")
        try await download(release.url, image)
        let data = try Data(contentsOf: image, options: .alwaysMapped)
        guard data.count == release.length else {
            throw MicropodError.message("The download is \(data.count) bytes; the feed says \(release.length)")
        }
        guard SelfUpdate.verify(data, signature: release.signature, publicKey: publicKey) else {
            throw MicropodError.message("The download's signature does not match the release key; it was not staged")
        }
        let artifactSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        progress("signature verified; unpacking")
        let unpacked = work.appendingPathComponent("Micropod.app")
        try extract(image, unpacked)
        try verifier.verifyApp(unpacked)
        let identity = try RigBundleIdentity.read(unpacked)
        guard identity.version == release.version.description, identity.revision == revision else {
            throw MicropodError.message(
                "The bundle is \(identity.version) (\(identity.revision.prefix(12))), not the \(release.version) "
                    + "(\(revision.prefix(12))) the feed describes")
        }
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = RigStagedRelease(
            identity: identity, artifactURL: release.url.absoluteString, artifactSHA256: artifactSHA256)
        try fm.moveItem(at: unpacked, to: marker.bundle(in: layout))
        try RuntimeDurableFile.write(marker, to: directory.appendingPathComponent(RigStagedRelease.fileName))
        progress("staged Micropod \(release.version) at \(directory.path)")
        return marker
    }
}

/// The one-shot launchd job that runs the upgrade outside the app it
/// replaces and outside the shell or CI job that asked for it. A crash
/// restarts it (KeepAlive on failure) and it resumes from the journal; at
/// login after a reboot it resumes too. It exits 0 once the journal is
/// terminal and removes its own definition.
enum RigUpgradeHelper {
    /// What `update rig-helper --probe` prints: the journal schemas it runs.
    static let probe = #"{"protocol":1,"journalSchemas":[1]}"#

    static func configuration(helper: URL, layout: RigUpgradeLayout) -> [String: Any] {
        [
            "Label": RigUpgradeLayout.helperLabel,
            "ProgramArguments": [helper.path, "update", "rig-helper", "--app", layout.appPath.path],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
            "ProcessType": "Interactive", "AbandonProcessGroup": true,
            "StandardOutPath": layout.helperLog.path, "StandardErrorPath": layout.helperLog.path,
            "EnvironmentVariables": ["MICROPOD_NO_UPDATE_NOTIFIER": "1"],
        ]
    }

    /// Whether `cli` runs journals of the schema this build writes.
    static func speaksJournal(_ cli: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: cli.path),
            let output = try? SelfUpdate.output(cli.path, ["update", "rig-helper", "--probe"]),
            let data = output.split(separator: "\n").last.map({ Data($0.utf8) }),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let schemas = value["journalSchemas"] as? [Int]
        else { return false }
        return schemas.contains(RigUpgradeJournal.schemaVersion)
    }

    /// Copies the helper out of the staged bundle (or this CLI when the staged
    /// one cannot run this journal) and bootstraps its job.
    @discardableResult
    static func launch(_ journal: RigUpgradeJournal, layout: RigUpgradeLayout, launch: RigLaunchctl = .init())
        async throws -> URL
    {
        let fm = FileManager.default
        let staged = URL(fileURLWithPath: journal.stagedBundle).appendingPathComponent("Contents/MacOS/micropod-cli")
        let source = speaksJournal(staged) ? staged : CLIInstall.currentExecutable()
        let helper = layout.operationDirectory(journal.operation).appendingPathComponent("micropod")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: helper.path) {
            try fm.copyItem(at: source, to: helper)
            guard chmod(helper.path, 0o755) == 0 else { throw MicropodError.message("Cannot prepare \(helper.path)") }
        }
        try fm.createDirectory(at: layout.launchAgents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: configuration(helper: helper, layout: layout), format: .xml, options: 0
        ).write(to: layout.helperPlist, options: .atomic)
        // A finished helper stays loaded but idle until it is booted out.
        try await launch.bootout(RigUpgradeLayout.helperLabel)
        try await launch.bootstrap(layout.helperPlist, label: RigUpgradeLayout.helperLabel)
        return source
    }

    /// The journal is terminal: nothing should start this helper again.
    static func retire(layout: RigUpgradeLayout) {
        try? FileManager.default.removeItem(at: layout.helperPlist)
    }
}

/// `micropod update stage|apply --disruptive|policy|recover --rig|rig-helper`.
enum RigUpgradeCommands {
    static let applyFlags: Set<String> = ["--disruptive", "--foreground", "--detach", "--no-smoke"]
    static let applyValues: Set<String> = [
        "--drain-timeout", "--health-timeout", "--smoke-image", "--channel", "--feed", "--app",
    ]

    struct ApplyRequest: Equatable {
        var disruptive: Bool
        var foreground = false
        var detach = false
        /// Resolved only for the disruptive path.
        var feed: URL?
        var appPath: URL
        var drainTimeout: TimeInterval = 120
        var healthTimeout: TimeInterval = 120
        var smokeImage: String? = "docker.io/library/alpine:3.23.2"
    }

    /// Which updater `micropod update apply` runs: the guarded Sparkle path
    /// unless `--disruptive` is given or this host's policy is disruptive.
    static func parseApply(
        _ args: [String], policy: RigUpgradePolicy, environment: [String: String] = ProcessInfo.processInfo.environment,
        channel: () -> String? = savedChannel
    ) throws -> ApplyRequest {
        let parsed = try parseArgs(args, boolFlags: applyFlags, valueFlags: applyValues, commandName: "update apply")
        guard parsed.positionals.isEmpty else { throw UsageError(message: "update apply takes no arguments") }
        var request = ApplyRequest(
            disruptive: parsed.has("--disruptive") || policy == .disruptive,
            appPath: URL(fileURLWithPath: parsed.value("--app") ?? "/Applications/Micropod.app"))
        let rigOnly = applyFlags.subtracting(["--disruptive"]).union(applyValues).filter {
            parsed.has($0) || parsed.value($0) != nil
        }
        guard request.disruptive else {
            guard rigOnly.isEmpty else {
                throw UsageError(message: "\(rigOnly.sorted().joined(separator: ", ")) requires --disruptive")
            }
            return request
        }
        request.feed = try feedURL(
            feed: parsed.value("--feed"), channel: parsed.value("--channel"), environment: environment, saved: channel)
        request.foreground = parsed.has("--foreground")
        request.detach = parsed.has("--detach")
        for (flag, keyPath) in [
            ("--drain-timeout", \ApplyRequest.drainTimeout), ("--health-timeout", \ApplyRequest.healthTimeout),
        ] {
            guard let raw = parsed.value(flag) else { continue }
            guard let seconds = Double(raw), seconds.isFinite, (0...3600).contains(seconds) else {
                throw UsageError(message: "\(flag) requires 0 to 3600 seconds")
            }
            request[keyPath: keyPath] = seconds
        }
        if parsed.has("--no-smoke") { request.smokeImage = nil }
        if let image = parsed.value("--smoke-image") { request.smokeImage = image }
        return request
    }

    @Sendable static func savedChannel() -> String? {
        UserDefaults(suiteName: "com.skunkworq.micropod")?.string(forKey: "updates.channel")
    }

    /// `--feed`, then `MICROPOD_UPDATE_FEED`, then the channel (`--channel`,
    /// else the app's saved choice). The release key is never configurable.
    static func feedURL(feed: String?, channel: String?, environment: [String: String], saved: () -> String?) throws
        -> URL
    {
        if let feed {
            guard let url = URL(string: feed), url.scheme == "https" || url.isFileURL else {
                throw UsageError(message: "--feed requires an https URL")
            }
            return url
        }
        if let override = environment["MICROPOD_UPDATE_FEED"].flatMap(URL.init(string:)) { return override }
        switch channel ?? saved() ?? "stable" {
        case "stable": return SelfUpdate.feedURL
        case "qualification": return URL(string: "https://castlemilk.github.io/micropod/qualification-appcast.xml")!
        case let other: throw UsageError(message: "unknown channel '\(other)'; choose stable or qualification")
        }
    }

    // MARK: stage

    static func stage(_ args: [String], json: Bool) async throws -> Int32 {
        let parsed = try parseArgs(
            args, boolFlags: [], valueFlags: ["--channel", "--feed", "--app"], commandName: "update stage")
        let layout = RigUpgradeLayout(
            appPath: URL(fileURLWithPath: parsed.value("--app") ?? "/Applications/Micropod.app"))
        let stager = RigReleaseStager(layout: layout)
        let release = try await stager.latest(
            feed: try feedURL(
                feed: parsed.value("--feed"), channel: parsed.value("--channel"),
                environment: ProcessInfo.processInfo.environment, saved: savedChannel))
        let installed = try? RigBundleIdentity.read(layout.appPath)
        if let installed, let running = ReleaseVersion(installed.version), release.version <= running {
            print(
                "Micropod \(installed.version) is installed; the feed's newest is \(release.version). Nothing to stage."
            )
            return ExitCode.ok
        }
        let staged = try await stager.stage(release)
        if FileManager.default.fileExists(atPath: layout.appPath.path) {
            do {
                try RigUpgradeEngine.requireAtomicSwap(staged.bundle(in: layout), layout.appPath)
            } catch {
                FileHandle.standardError.write(Data("warning: \(errorMessage(error)); apply will refuse it\n".utf8))
            }
        }
        if json {
            print(String(decoding: try JSONEncoder().encode(staged), as: UTF8.self))
        } else {
            print("Staged Micropod \(staged.identity.version): `micropod update apply --disruptive` installs it.")
        }
        return ExitCode.ok
    }

    // MARK: apply --disruptive

    static func apply(_ request: ApplyRequest, json: Bool) async throws -> Int32 {
        let layout = RigUpgradeLayout(appPath: request.appPath)
        let store = RigUpgradeStore(layout: layout)
        let engine = RigUpgradeEngine(layout: layout, environment: .live(layout: layout, log: log))
        if let journal = RigUpgradeFence.inFlight(layout: layout) {
            print("Resuming rig upgrade \(journal.operation.uuidString) (\(journal.phase.rawValue)).")
            if !store.engineIsRunning {
                if request.foreground { return report(try await engine.run(), json: json) }
                try await RigUpgradeHelper.launch(journal, layout: layout)
            }
            return request.detach ? ExitCode.ok : try await follow(journal.operation, layout: layout, json: json)
        }
        let stager = RigReleaseStager(layout: layout)
        let release = try await stager.latest(feed: request.feed ?? SelfUpdate.feedURL)
        let installed = try RigBundleIdentity.read(layout.appPath)
        if let running = ReleaseVersion(installed.version), release.version <= running {
            print("Micropod \(installed.version) is up to date (the feed's newest is \(release.version)).")
            return ExitCode.ok
        }
        let staged = try await stager.stage(release)
        var options = RigUpgradeOptions.standard(home: layout.home)
        options.drainTimeout = request.drainTimeout
        options.healthTimeout = request.healthTimeout
        options.smokeImage = request.smokeImage
        let journal = try await engine.prepare(staged, options: options)
        print(
            "Prepared rig upgrade \(journal.operation.uuidString): \(journal.source.version) → \(journal.target.version). "
                + "Jobs on this host may be interrupted.")
        if journal.dedicatedRuntime { print(RigUpgradeEngine.dedicatedNote) }
        if request.foreground { return report(try await engine.run(), json: json) }
        let helper = try await RigUpgradeHelper.launch(journal, layout: layout)
        print("The upgrade runs as \(RigUpgradeLayout.helperLabel) (\(helper.path)); log: \(layout.helperLog.path)")
        return request.detach ? ExitCode.ok : try await follow(journal.operation, layout: layout, json: json)
    }

    /// Prints phase changes until the helper's journal is terminal. Losing
    /// this process (a closed terminal, a preempted CI job) loses nothing.
    static func follow(_ operation: UUID, layout: RigUpgradeLayout, json: Bool, timeout: Duration = .seconds(1800))
        async throws -> Int32
    {
        let deadline = ContinuousClock.now + timeout
        var last: String?
        while ContinuousClock.now < deadline {
            if let journal = try? RigUpgradeStore(layout: layout).read(), journal.operation == operation {
                if journal.phase.rawValue != last, !json {
                    print("  \(journal.phase.rawValue)…")
                    last = journal.phase.rawValue
                }
                if journal.phase.isTerminal { return report(journal, json: json) }
            }
            try await Task.sleep(for: .seconds(1))
        }
        print("The upgrade is still running; `micropod update status` shows where it is.")
        return ExitCode.failure
    }

    static func report(_ journal: RigUpgradeJournal, json: Bool) -> Int32 {
        if json {
            print(String(decoding: (try? JSONEncoder().encode(journal)) ?? Data(), as: UTF8.self))
        } else {
            print(journal.reason ?? journal.phase.rawValue)
            for note in journal.notes { print("  - " + note) }
        }
        return journal.phase == .completed ? ExitCode.ok : ExitCode.failure
    }

    @Sendable static func log(_ line: String) {
        FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n".utf8))
    }

    // MARK: rig-helper (launchd)

    static func helper(_ args: [String]) async -> Int32 {
        if args.contains("--probe") {
            print(RigUpgradeHelper.probe)
            return ExitCode.ok
        }
        let appPath = args.firstIndex(of: "--app").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let layout = RigUpgradeLayout(appPath: URL(fileURLWithPath: appPath ?? "/Applications/Micropod.app"))
        guard let journal = try? RigUpgradeStore(layout: layout).read(), !journal.phase.isTerminal else {
            RigUpgradeHelper.retire(layout: layout)
            return ExitCode.ok
        }
        do {
            let result = try await RigUpgradeEngine(layout: layout, environment: .live(layout: layout, log: log)).run()
            log("rig upgrade \(result.operation.uuidString) \(result.phase.rawValue): \(result.reason ?? "")")
            if result.phase.isTerminal { RigUpgradeHelper.retire(layout: layout) }
            return ExitCode.ok
        } catch {
            // launchd starts this helper again, which resumes the journal.
            log("rig upgrade \(journal.operation.uuidString) will resume: \(errorMessage(error))")
            return ExitCode.failure
        }
    }

    // MARK: policy, recover, status

    static func policy(_ args: [String], json: Bool) throws -> Int32 {
        let layout = RigUpgradeLayout()
        if let value = args.first {
            guard let policy = RigUpgradePolicy(rawValue: value) else {
                throw UsageError(message: "choose guarded or disruptive")
            }
            try policy.write(layout: layout)
        }
        let current = RigUpgradePolicy.read(layout: layout)
        if json {
            print(#"{"policy":"\#(current.rawValue)"}"#)
        } else {
            print(
                current == .disruptive
                    ? "Update policy: disruptive — `micropod update apply` replaces the app and its services at once, "
                        + "interrupting jobs; the app never installs updates by itself."
                    : "Update policy: guarded — `micropod update apply` installs through the app, keeping workloads running."
            )
        }
        return ExitCode.ok
    }

    /// Retries a rollback that gave up, and releases a drain a finished
    /// upgrade could not release.
    static func recover(_ args: [String], json: Bool) async throws -> Int32 {
        let parsed = try parseArgs(args, boolFlags: ["--rig"], valueFlags: ["--app"], commandName: "update recover")
        let layout = RigUpgradeLayout(
            appPath: URL(fileURLWithPath: parsed.value("--app") ?? "/Applications/Micropod.app"))
        let engine = RigUpgradeEngine(layout: layout, environment: .live(layout: layout, log: log))
        guard try RigUpgradeStore(layout: layout).read() != nil else {
            print("No rig upgrade is recorded.")
            return ExitCode.ok
        }
        let journal = try await engine.recover()
        return report(journal, json: json)
    }

    /// One line for `micropod update status`, when a rig upgrade has anything to say.
    static func statusLine(_ state: Micropod_V1_UpdateState?, policy: RigUpgradePolicy) -> String? {
        let suffix = policy == .disruptive ? " (policy: disruptive)" : ""
        guard let state else { return policy == .disruptive ? "Rig upgrade — nothing staged" + suffix : nil }
        let operation = state.operationID.prefix(8)
        switch state.kind {
        case .upgrading:
            return "Rig upgrade \(operation) — \(state.phase): \(state.currentVersion) → \(state.targetVersion)"
                + suffix
        case .staged:
            return "Rig upgrade — \(state.targetVersion) is staged: `micropod update apply --disruptive` installs it"
                + suffix
        case .rolledBack:
            return "Rig upgrade \(operation) — rolled back from \(state.targetVersion): \(state.reason)" + suffix
        case .blocked:
            return "Rig upgrade \(operation) — \(state.targetVersion) was refused: \(state.reason)" + suffix
        case .recoveryRequired:
            return "Rig upgrade \(operation) — recovery required: \(state.reason)" + suffix
        default:
            return nil
        }
    }
}
