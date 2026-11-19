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
/// login after a reboot it resumes too. Once the journal is terminal, or its
/// restart budget is spent, it removes its definition and boots itself out.
enum RigUpgradeHelper {
    /// What `update rig-helper --probe` prints.
    struct Probe: Codable, Equatable {
        let `protocol`: Int
        let journalSchemas: [Int]
        /// This build's retained-service definitions.
        let services: [String: RetainedServiceDefinition]?
    }

    static var probe: String {
        let value = Probe(
            protocol: 1, journalSchemas: [RigUpgradeJournal.schemaVersion],
            services: RetainedServiceLaunchAgent.definitions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    /// Runs of one operation's helper before it gives up and boots itself out.
    static let restartBudget = 20
    /// How long a helper waits for another engine (a `--foreground` run) to finish.
    static let lockWait: Duration = .seconds(300)

    /// A `prepared` journal older than this, with no recent launch by a CLI,
    /// was left behind: a helper launchd started at login does not run it.
    static let staleAfter: TimeInterval = 600

    static func configuration(helper: URL, layout: RigUpgradeLayout, operation: UUID) -> [String: Any] {
        [
            "Label": RigUpgradeLayout.helperLabel,
            "ProgramArguments": [
                helper.path, "update", "rig-helper", "--app", layout.appPath.path, "--operation",
                operation.uuidString,
            ],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
            "ProcessType": "Interactive", "AbandonProcessGroup": true,
            "StandardOutPath": layout.helperLog.path, "StandardErrorPath": layout.helperLog.path,
            "EnvironmentVariables": ["MICROPOD_NO_UPDATE_NOTIFIER": "1"],
        ]
    }

    static func parseProbe(_ output: String) -> Probe? {
        guard let line = output.split(separator: "\n").last else { return nil }
        return try? JSONDecoder().decode(Probe.self, from: Data(line.utf8))
    }

    /// What a CLI binary reports about itself; nil when it cannot run or
    /// predates rig upgrades.
    static func readProbe(_ cli: URL) -> Probe? {
        guard FileManager.default.isExecutableFile(atPath: cli.path),
            let output = try? SelfUpdate.output(cli.path, ["update", "rig-helper", "--probe"])
        else { return nil }
        return parseProbe(output)
    }

    /// The staged release's CLI when it runs this journal's schema, else this CLI.
    static func source(for journal: RigUpgradeJournal, probe: (URL) -> Probe? = readProbe) -> URL {
        let staged = URL(fileURLWithPath: journal.stagedBundle).appendingPathComponent("Contents/MacOS/micropod-cli")
        if probe(staged)?.journalSchemas.contains(RigUpgradeJournal.schemaVersion) == true { return staged }
        return CLIInstall.currentExecutable()
    }

    static func helperURL(_ journal: RigUpgradeJournal, layout: RigUpgradeLayout) -> URL {
        layout.helperExecutable(journal.operation)
    }

    /// When a CLI last started this operation's helper.
    static func ticketURL(_ operation: UUID, layout: RigUpgradeLayout) -> URL {
        layout.operationDirectory(operation).appendingPathComponent("helper-launched-at")
    }

    static func launchedAt(_ operation: UUID, layout: RigUpgradeLayout) -> Date? {
        (try? String(contentsOf: ticketURL(operation, layout: layout), encoding: .utf8))
            .flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    static func runsURL(_ operation: UUID, layout: RigUpgradeLayout) -> URL {
        layout.operationDirectory(operation).appendingPathComponent("helper-runs")
    }

    /// Makes sure one helper runs this journal. Serialised by a lock, so two
    /// callers resuming at once neither boot out a running helper nor start
    /// two: a job already loaded from this helper is kickstarted (which
    /// starts it only if it is not running), anything else replaced.
    static func launch(
        _ journal: RigUpgradeJournal, layout: RigUpgradeLayout, source: URL, launch: any RigLaunchControlling,
        probe: (URL) -> Probe? = readProbe
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: layout.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(
            layout.root.appendingPathComponent("helper-launch.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MicropodError.message("Cannot open the rig upgrade launch lock") }
        defer { close(fd) }
        var locked = false
        for _ in 0..<300 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard locked else { throw MicropodError.message("Another micropod is starting the rig upgrade helper") }
        defer { flock(fd, LOCK_UN) }
        if RigUpgradeStore(layout: layout).engineIsRunning { return }
        let helper = helperURL(journal, layout: layout)
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: helper.path) {
            try fm.copyItem(at: source, to: helper)
            guard chmod(helper.path, 0o755) == 0 else { throw MicropodError.message("Cannot prepare \(helper.path)") }
        }
        // A helper that cannot run would only crash-loop under launchd.
        guard probe(helper)?.journalSchemas.contains(journal.schema) == true else {
            throw MicropodError.message("\(helper.path) does not run rig upgrade journals; it was not started")
        }
        try? fm.removeItem(at: runsURL(journal.operation, layout: layout))
        try Data("\(Date().timeIntervalSince1970)".utf8).write(
            to: ticketURL(journal.operation, layout: layout), options: .atomic)
        try fm.createDirectory(at: layout.launchAgents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: configuration(helper: helper, layout: layout, operation: journal.operation),
            format: .xml, options: 0
        ).write(to: layout.helperPlist, options: .atomic)
        do {
            if let loaded = await launch.loadedProgram(RigUpgradeLayout.helperLabel) {
                if loaded == helper.path {
                    try await launch.kickstart(RigUpgradeLayout.helperLabel)
                    return
                }
                // An earlier operation's helper, finished but still loaded.
                try await launch.bootout(RigUpgradeLayout.helperLabel)
            }
            try await launch.bootstrap(layout.helperPlist, label: RigUpgradeLayout.helperLabel)
        } catch {
            // Nothing should load this definition at the next login.
            try? fm.removeItem(at: layout.helperPlist)
            if await launch.loadedProgram(RigUpgradeLayout.helperLabel) == helper.path {
                try? await launch.bootout(RigUpgradeLayout.helperLabel)
            }
            throw error
        }
    }

    /// Counts one more run of this operation's helper; false once over budget.
    static func countRun(_ operation: UUID, layout: RigUpgradeLayout) -> Bool {
        let url = runsURL(operation, layout: layout)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let runs = (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0) } ?? 0
        guard (try? Data("\(runs + 1)".utf8).write(to: url, options: .atomic)) != nil else { return false }
        return runs + 1 <= restartBudget
    }

    /// Nothing should start this helper again. Boots the job out last: when
    /// the caller is the helper itself, that ends it.
    static func retire(layout: RigUpgradeLayout, launch: any RigLaunchControlling) async {
        try? FileManager.default.removeItem(at: layout.helperPlist)
        try? await launch.bootout(RigUpgradeLayout.helperLabel)
    }
}

/// `micropod update stage|apply --disruptive|policy|recover --rig|rig-helper`.
enum RigUpgradeCommands {
    static let applyFlags: Set<String> = [
        "--disruptive", "--foreground", "--detach", "--no-smoke", "--force-undrained", "--abandon",
    ]
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
        var forceUndrained = false
        var abandon = false
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
            disruptive: parsed.has("--disruptive") || parsed.has("--abandon") || policy == .disruptive,
            appPath: URL(fileURLWithPath: parsed.value("--app") ?? "/Applications/Micropod.app"))
        let rigOnly = applyFlags.subtracting(["--disruptive", "--abandon"]).union(applyValues).filter {
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
        request.forceUndrained = parsed.has("--force-undrained")
        request.abandon = parsed.has("--abandon")
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
        let engine = RigUpgradeEngine(layout: layout, environment: .live(layout: layout, log: log))
        if request.abandon {
            guard RigUpgradeFence.unfinished(layout: layout) != nil else {
                print("No rig upgrade is waiting to start.")
                return ExitCode.ok
            }
            _ = report(try await engine.abandon(reason: "Abandoned by `micropod update apply --abandon`."), json: json)
            return ExitCode.ok
        }
        if let journal = RigUpgradeFence.unfinished(layout: layout) {
            print("Resuming rig upgrade \(journal.operation.uuidString) (\(journal.phase.rawValue)).")
            return try await handOff(journal, layout: layout, engine: engine, request: request, json: json)
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
        options.forceUndrained = request.forceUndrained
        let probe = RigUpgradeHelper.readProbe(
            staged.bundle(in: layout).appendingPathComponent("Contents/MacOS/micropod-cli"))
        let journal = try await engine.prepare(staged, options: options, services: probe?.services)
        print(
            "Prepared rig upgrade \(journal.operation.uuidString): \(journal.source.version) → \(journal.target.version). "
                + "Jobs on this host may be interrupted.")
        if journal.dedicatedRuntime { print(RigUpgradeEngine.dedicatedNote) }
        return try await handOff(journal, layout: layout, engine: engine, request: request, json: json)
    }

    /// Runs the journal here (`--foreground`) or hands it to the launchd
    /// helper. A helper that cannot start leaves no journal waiting for it:
    /// an upgrade that has not stopped anything is refused.
    static func handOff(
        _ journal: RigUpgradeJournal, layout: RigUpgradeLayout, engine: RigUpgradeEngine, request: ApplyRequest,
        json: Bool, launch: any RigLaunchControlling = RigLaunchctl()
    ) async throws -> Int32 {
        if request.foreground {
            if RigUpgradeStore(layout: layout).engineIsRunning {
                return try await follow(journal.operation, layout: layout, json: json)
            }
            let result = try await engine.run()
            let code = report(result, json: json)
            return try await followRuntimeComponents(result, code: code, json: json)
        }
        do {
            try await RigUpgradeHelper.launch(
                journal, layout: layout, source: RigUpgradeHelper.source(for: journal), launch: launch)
        } catch {
            if [.prepared, .draining].contains(journal.phase) {
                _ = try? await engine.abandon(
                    reason: "The upgrade helper could not be started: \(errorMessage(error)).")
            }
            throw error
        }
        if !json { print("The upgrade runs as \(RigUpgradeLayout.helperLabel); log: \(layout.helperLog.path)") }
        guard !request.detach else { return ExitCode.ok }
        let code = try await follow(journal.operation, layout: layout, json: json)
        guard let result = try? RigUpgradeStore(layout: layout).read(), result.operation == journal.operation else {
            return code
        }
        return try await followRuntimeComponents(result, code: code, json: json)
    }

    /// One command updates both: after a completed upgrade of a host with the
    /// dedicated runtime, the runtime component update the helper requested
    /// (or this process requests now; the same operation is resumed, never
    /// repeated) is followed to its end.
    static func followRuntimeComponents(_ journal: RigUpgradeJournal, code: Int32, json: Bool) async throws -> Int32 {
        guard code == ExitCode.ok, journal.phase == .completed, journal.dedicatedRuntime else { return code }
        if !json { print("Updating the dedicated runtime components…") }
        let updated = await RuntimeUpdateCommands.chain(follow: true, log: { line in if !json { print(line) } })
        return updated ? code : ExitCode.failure
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
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        let layout = RigUpgradeLayout(appPath: URL(fileURLWithPath: value("--app") ?? "/Applications/Micropod.app"))
        return await runHelper(
            layout: layout, operation: value("--operation").flatMap(UUID.init(uuidString:)),
            engine: RigUpgradeEngine(layout: layout, environment: .live(layout: layout, log: log)),
            launch: RigLaunchctl())
    }

    /// One helper run: exit 0 ends the job (terminal journal, nothing to do,
    /// or the restart budget spent); exit 1 lets launchd start it again to
    /// resume.
    static func runHelper(
        layout: RigUpgradeLayout, operation: UUID?, engine: RigUpgradeEngine, launch: any RigLaunchControlling,
        lockWait: Duration = RigUpgradeHelper.lockWait, now: Date = Date(),
        chainRuntime: @Sendable () async -> Void = { _ = await RuntimeUpdateCommands.chain(follow: false, log: log) }
    ) async -> Int32 {
        guard let journal = try? RigUpgradeStore(layout: layout).read(), !journal.phase.isTerminal else {
            await RigUpgradeHelper.retire(layout: layout, launch: launch)
            return ExitCode.ok
        }
        // A definition left over from another operation never runs this one.
        guard let operation, operation == journal.operation else {
            log(
                "rig upgrade helper for \(operation?.uuidString ?? "no operation") found journal "
                    + "\(journal.operation.uuidString); not running it")
            await RigUpgradeHelper.retire(layout: layout, launch: launch)
            return ExitCode.ok
        }
        // launchd starting a left-behind definition at login: an upgrade that
        // never got going is not started long after it was prepared.
        if journal.phase == .prepared, now.timeIntervalSince(journal.updatedAt) > RigUpgradeHelper.staleAfter,
            now.timeIntervalSince(RigUpgradeHelper.launchedAt(journal.operation, layout: layout) ?? .distantPast)
                > RigUpgradeHelper.staleAfter
        {
            _ = try? await engine.abandon(
                reason: "Its helper started at login for an upgrade prepared more than 10 minutes earlier, so it "
                    + "was not run.")
            log("rig upgrade \(journal.operation.uuidString) was prepared too long ago; abandoned")
            await RigUpgradeHelper.retire(layout: layout, launch: launch)
            return ExitCode.ok
        }
        guard RigUpgradeHelper.countRun(journal.operation, layout: layout) else {
            _ = try? await engine.stopResuming(
                reason: "The upgrade helper gave up after \(RigUpgradeHelper.restartBudget) runs")
            log(
                "rig upgrade \(journal.operation.uuidString) helper gave up after \(RigUpgradeHelper.restartBudget) runs "
                    + "in \(journal.phase.rawValue); `micropod update recover --rig` takes it from here")
            await RigUpgradeHelper.retire(layout: layout, launch: launch)
            return ExitCode.ok
        }
        // A `--foreground` engine holds the journal: wait for it, bounded.
        let deadline = ContinuousClock.now + lockWait
        while RigUpgradeStore(layout: layout).engineIsRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: min(.seconds(2), lockWait))
        }
        do {
            let result = try await engine.run()
            log("rig upgrade \(result.operation.uuidString) \(result.phase.rawValue): \(result.reason ?? "")")
            guard result.phase.isTerminal else { return ExitCode.failure }
            if result.phase == .completed, result.dedicatedRuntime {
                // The new app is verified and the drain released: the root
                // helper now follows it in its own coordinated operation.
                await chainRuntime()
            }
            await RigUpgradeHelper.retire(layout: layout, launch: launch)
            return ExitCode.ok
        } catch {
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
