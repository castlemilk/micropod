import Darwin
import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `micropod docker install|uninstall|status` against a fake docker CLI that
/// keeps contexts, the current context and buildx state the way the real
/// one does. Every docker file lives under a temporary `DOCKER_CONFIG`.
final class HVFDockerWiringTests: XCTestCase {
    private var root: URL!
    private var layout: HVFMachineLayout!
    private var config: URL!
    private var systemSocket: URL!
    private var environment: [String: String] = [:]
    private let dockerPath = URL(fileURLWithPath: "/usr/bin/docker")

    private let ready = HVFDockerWiring.Machine(missing: [], phase: .running, dockerBuild: .ready)
    private let fallback = HVFDockerWiring.Machine(missing: [], phase: .running, dockerBuild: .fallback)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpdw-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = HVFMachineLayout(root: root.appendingPathComponent("hvf"))
        config = root.appendingPathComponent("docker")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        systemSocket = root.appendingPathComponent("var-run-docker.sock")
        environment = [
            "DOCKER_CONFIG": config.path, "HOME": root.path, "PATH": "/nonexistent",
            "MICROPOD_DOCKER_SOCK": root.appendingPathComponent("canonical-docker.sock").path,
        ]
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func wiring(_ docker: FakeContextCLI, _ extra: [String: String] = [:]) -> HVFDockerWiring {
        HVFDockerWiring(
            layout: layout, docker: dockerPath, environment: environment.merging(extra) { $1 }, runner: docker,
            systemSocket: systemSocket.path)
    }

    private func fake() -> FakeContextCLI {
        FakeContextCLI(buildx: config.appendingPathComponent("buildx"))
    }

    private func record() throws -> HVFDockerWiring.Record? {
        try HVFDockerWiring(layout: layout, docker: nil, environment: environment).loadRecord()
    }

    private func createContext(_ name: String) -> [String] {
        [
            "context", "create", name, "--description", "micropod hvf machine (\(layout.root.path))", "--docker",
            "host=\(layout.dockerEndpoint)",
        ]
    }

    // MARK: Selection

    func testInstallCreatesTheContextAndNeverSelectsItWithoutUse() throws {
        let docker = fake()
        docker.contexts = ["other": "unix:///other/docker.sock"]
        docker.current = "other"

        let outcome = try wiring(docker).install(use: false, builder: .auto, force: false, machine: ready)

        XCTAssertTrue(docker.calls.contains(createContext("micropod")), "\(docker.calls)")
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "use"]) }, "\(docker.calls)")
        XCTAssertEqual(docker.current, "other", "the user's current context is untouched")
        XCTAssertEqual(docker.contexts["micropod"], layout.dockerEndpoint)
        XCTAssertEqual(outcome.actions.first, "docker context micropod -> \(layout.dockerEndpoint) (created)")
        XCTAssertTrue(
            outcome.actions.contains {
                $0.hasPrefix("current context: other (unchanged; select with `micropod docker install --use`")
            }, outcome.actions.joined(separator: "\n"))
        let saved = try XCTUnwrap(try record())
        XCTAssertNil(saved.previousContext)
        XCTAssertFalse(saved.selectedByMicropod)
        XCTAssertEqual(saved.endpoint, layout.dockerEndpoint)
        var info = stat()
        XCTAssertEqual(stat(layout.root.appendingPathComponent("docker-wiring.json").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertTrue(docker.executables.allSatisfy { $0 == dockerPath.path }, "\(docker.executables)")
    }

    func testUseRecordsThePreviousContextAndARepeatKeepsIt() throws {
        let docker = fake()
        docker.contexts = ["desktop-linux": "unix:///Users/me/.docker/run/docker.sock"]
        docker.current = "desktop-linux"

        let first = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)
        XCTAssertEqual(docker.current, "micropod")
        XCTAssertTrue(docker.calls.contains(["context", "use", "micropod"]))
        XCTAssertTrue(
            first.actions.contains(
                "current context: micropod (was desktop-linux; `micropod docker uninstall` restores it)"),
            first.actions.joined(separator: "\n"))
        XCTAssertEqual(try record()?.previousContext, "desktop-linux")
        XCTAssertEqual(try record()?.selectedByMicropod, true)

        docker.calls = []
        let second = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "use"]) }, "already selected")
        XCTAssertEqual(try record()?.previousContext, "desktop-linux", "never overwritten with micropod")
        XCTAssertTrue(
            second.actions.contains(
                "current context: micropod (already selected; `micropod docker uninstall` restores desktop-linux)"),
            second.actions.joined(separator: "\n"))
        XCTAssertEqual(second.actions.first, "docker context micropod -> \(layout.dockerEndpoint) (present)")
    }

    func testUninstallRestoresThePreviousContextBeforeRemovingIt() throws {
        let docker = fake()
        docker.contexts = ["other": "unix:///other/docker.sock"]
        docker.current = "other"
        _ = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)
        XCTAssertEqual(docker.current, "micropod")

        docker.calls = []
        let outcome = try wiring(docker).uninstall(force: false)

        let use = try XCTUnwrap(docker.calls.firstIndex(of: ["context", "use", "other"]), "\(docker.calls)")
        let remove = try XCTUnwrap(docker.calls.firstIndex(of: ["context", "rm", "micropod"]), "\(docker.calls)")
        XCTAssertLessThan(use, remove, "the CLI refuses to remove the context in use")
        XCTAssertEqual(docker.current, "other")
        XCTAssertNil(docker.contexts["micropod"])
        XCTAssertEqual(outcome.actions.first, "current context: other (restored)")
        XCTAssertNil(try record(), "the record goes with the context")
        XCTAssertEqual(outcome.manual, [])
    }

    func testUninstallSelectsDefaultWhenThePreviousContextIsGone() throws {
        let docker = fake()
        docker.contexts = ["other": "unix:///other/docker.sock"]
        docker.current = "other"
        _ = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)
        docker.contexts["other"] = nil

        let outcome = try wiring(docker).uninstall(force: false)

        XCTAssertTrue(docker.calls.contains(["context", "use", "default"]), "\(docker.calls)")
        XCTAssertEqual(docker.current, "default")
        XCTAssertNil(docker.contexts["micropod"])
        XCTAssertEqual(
            outcome.actions.first, "current context: default (the previous context 'other' no longer exists)")
    }

    func testUninstallLeavesAContextTheUserSelectedAfterInstallAlone() throws {
        let docker = fake()
        docker.contexts = ["other": "unix:///other/docker.sock", "orbstack": "unix:///o/docker.sock"]
        docker.current = "other"
        _ = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)
        docker.current = "orbstack"

        _ = try wiring(docker).uninstall(force: false)

        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "use", "other"]) })
        XCTAssertEqual(docker.current, "orbstack")
        XCTAssertNil(docker.contexts["micropod"])
    }

    func testMachineBuilderRmRestoresTheSelectionToo() throws {
        let docker = fake()
        docker.contexts = ["other": "unix:///other/docker.sock"]
        docker.current = "other"
        _ = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)

        let setup = HVFBuilderSetup(layout: layout, docker: dockerPath, environment: environment, runner: docker)
        let lines = try setup.remove()

        XCTAssertEqual(docker.current, "other", lines.joined(separator: "\n"))
        XCTAssertNil(docker.contexts["micropod"])
        XCTAssertNil(try record())
    }

    // MARK: A context that is not ours

    func testAForeignMicropodContextIsRefusedAndForceRepointsIt() throws {
        let docker = fake()
        docker.contexts = ["micropod": "unix:///elsewhere/docker.sock"]
        docker.current = "micropod"

        XCTAssertThrowsError(try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)) {
            let message = $0.localizedDescription
            XCTAssertTrue(message.contains("points at unix:///elsewhere/docker.sock"), message)
            XCTAssertTrue(message.contains("--force"), message)
        }
        XCTAssertEqual(docker.calls, [["context", "inspect", "micropod"]], "a refusal changes nothing")
        XCTAssertNil(try record())

        let kept = try wiring(docker).uninstall(force: false)
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "use"]) }, "not ours to deselect")
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "rm"]) })
        XCTAssertEqual(docker.contexts["micropod"], "unix:///elsewhere/docker.sock")
        XCTAssertTrue(kept.actions.contains { $0.hasPrefix("left docker context 'micropod' alone") })

        docker.calls = []
        let forced = try wiring(docker).install(use: false, builder: .auto, force: true, machine: ready)
        XCTAssertTrue(
            docker.calls.contains([
                "context", "update", "micropod", "--description", "micropod hvf machine (\(layout.root.path))",
                "--docker", "host=\(layout.dockerEndpoint)",
            ]), "\(docker.calls)")
        XCTAssertEqual(docker.contexts["micropod"], layout.dockerEndpoint)
        XCTAssertEqual(forced.actions.first, "docker context micropod -> \(layout.dockerEndpoint) (updated)")
    }

    func testEndpointSpellingsOfOneSocketMatch() throws {
        let unique = UUID().uuidString.prefix(8)
        XCTAssertTrue(
            HVFBuilderSetup.sameEndpoint(
                "unix:///tmp/mpdw-absent-\(unique)/run/docker.sock",
                "unix:///private/tmp/mpdw-absent-\(unique)/run/docker.sock"),
            "/tmp is a link to /private/tmp, and the socket need not exist")
        XCTAssertFalse(HVFBuilderSetup.sameEndpoint("unix:///tmp/a/run/docker.sock", "unix:///tmp/b/run/docker.sock"))
        XCTAssertFalse(HVFBuilderSetup.sameEndpoint("tcp://127.0.0.1:2375", layout.dockerEndpoint))
        XCTAssertFalse(HVFBuilderSetup.sameEndpoint(nil, layout.dockerEndpoint))

        // A context spelled through a link to the root is this machine's.
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("hvf-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: layout.root)
        let docker = fake()
        docker.contexts = ["micropod": "unix://\(link.path)/run/docker.sock"]
        let outcome = try wiring(docker).install(use: false, builder: .auto, force: false, machine: ready)
        XCTAssertEqual(outcome.actions.first, "docker context micropod -> \(layout.dockerEndpoint) (present)")
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "create"]) })
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["context", "update"]) })
    }

    // MARK: Shell overrides

    func testShellOverridesNeverReachTheCLIAndAreReported() throws {
        let docker = fake()
        let overrides = [
            "DOCKER_HOST": "unix:///nonexistent/docker.sock", "DOCKER_CONTEXT": "theirs",
            "BUILDX_BUILDER": "their-builder", "DOCKER_API_VERSION": "1.47",
        ]
        let outcome = try wiring(docker, overrides).install(use: true, builder: .auto, force: false, machine: ready)

        XCTAssertFalse(docker.environments.isEmpty)
        for environment in docker.environments {
            XCTAssertNil(environment["DOCKER_HOST"])
            XCTAssertNil(environment["DOCKER_CONTEXT"])
            XCTAssertNil(environment["BUILDX_BUILDER"])
            XCTAssertEqual(environment["DOCKER_CONFIG"], config.path, "DOCKER_CONFIG passes through")
        }
        XCTAssertTrue(
            outcome.notes.contains(
                "DOCKER_HOST=unix:///nonexistent/docker.sock is set in this shell: docker ignores the selected "
                    + "context while it is set (unset DOCKER_HOST)"), outcome.notes.joined(separator: "\n"))
        XCTAssertTrue(
            outcome.notes.contains(
                "DOCKER_CONTEXT=theirs is set in this shell: docker ignores the selected context while it is set "
                    + "(unset DOCKER_CONTEXT)"), outcome.notes.joined(separator: "\n"))

        let status = wiring(docker, overrides).status(machine: ready)
        XCTAssertEqual(status.environmentOverride, overrides)
        XCTAssertTrue(status.selected)
        XCTAssertTrue(status.notes.contains { $0.hasPrefix("DOCKER_HOST=unix:///nonexistent/docker.sock") })

        // DOCKER_HOST already naming this machine, in another spelling, is no override.
        let resolved = "unix://" + HVFBuilderSetup.resolvedPath(layout.dockerSocket.path)
        let same = wiring(docker, ["DOCKER_HOST": resolved, "DOCKER_CONTEXT": "micropod"]).status(machine: ready)
        XCTAssertFalse(same.notes.contains { $0.hasPrefix("DOCKER_HOST=") || $0.hasPrefix("DOCKER_CONTEXT=") })
    }

    // MARK: What is missing

    func testWithoutADockerCLIInstallFailsWithTheDockerHostLineAndStatusStillAnswers() throws {
        let docker = fake()
        let wiring = HVFDockerWiring(
            layout: layout, docker: nil, environment: environment, runner: docker, systemSocket: systemSocket.path)
        XCTAssertNil(HVFDockerWiring(layout: layout, environment: environment).docker, "no docker on PATH")

        XCTAssertThrowsError(try wiring.install(use: true, builder: .auto, force: false, machine: ready)) {
            let message = $0.localizedDescription
            XCTAssertTrue(
                message.contains("the docker CLI was not found on PATH (set MICROPOD_DOCKER_CLI to its path)"), message)
            XCTAssertTrue(message.contains("export DOCKER_HOST=\(layout.dockerEndpoint)"), message)
        }
        XCTAssertThrowsError(try wiring.uninstall(force: false))
        let status = wiring.status(machine: ready)
        XCTAssertNil(status.dockerCLI.path)
        XCTAssertTrue(status.notes.contains { $0.contains("export DOCKER_HOST=\(layout.dockerEndpoint)") })
        XCTAssertEqual(docker.calls, [])
        XCTAssertNil(try record())
    }

    func testMissingPluginsAMissingCredentialHelperAndAnOldClientAreNotes() throws {
        let docker = fake()
        docker.compose = false
        docker.buildxPlugin = false
        docker.apiVersion = "1.43"
        let file = config.appendingPathComponent("config.json")
        let original = Data(#"{"credsStore":"desktop","credHelpers":{"gcr.io":"gcloud"}}"#.utf8)
        try original.write(to: file)

        // compose is installed where the CLI does not look; buildx nowhere.
        let plugins = root.appendingPathComponent("cli-plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let composePlugin = plugins.appendingPathComponent("docker-compose")
        XCTAssertTrue(FileManager.default.createFile(atPath: composePlugin.path, contents: Data("#!/bin/sh\n".utf8)))
        XCTAssertEqual(chmod(composePlugin.path, 0o755), 0)
        var withPlugins = wiring(docker)
        withPlugins.pluginSearch = [root.appendingPathComponent("nothing").path, plugins.path]

        let outcome = try withPlugins.install(use: false, builder: .auto, force: false, machine: ready)
        let notes = outcome.notes.joined(separator: "\n")

        XCTAssertTrue(
            notes.contains(
                "the docker compose plugin was not found; it is in \(plugins.path): add that directory to "
                    + "\"cliPluginsExtraDirs\" in \(file.path)"), notes)
        XCTAssertTrue(
            notes.contains(
                "the docker buildx plugin was not found: docker build needs buildx (this engine has no classic /build) "
                    + "(install it, e.g. `brew install docker-buildx`, then add its directory to \"cliPluginsExtraDirs\""
            ), notes)
        XCTAssertTrue(
            notes.contains(
                "credsStore \"desktop\" in \(file.path) names docker-credential-desktop, which is not on PATH: "
                    + "pulls and builds will fail until it is installed or the key is removed"), notes)
        XCTAssertTrue(notes.contains("docker-credential-gcloud, which is not on PATH: pulls from gcr.io"), notes)
        XCTAssertTrue(notes.contains("docker CLI API 1.43 is older than the engine's minimum 1.44"), notes)
        XCTAssertTrue(outcome.actions.contains("compose: missing    buildx: missing"), outcome.actions.description)
        XCTAssertEqual(try Data(contentsOf: file), original, "config.json is read, never written")

        // The helper on PATH: no note for it.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let helper = bin.appendingPathComponent("docker-credential-desktop")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8)))
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        docker.compose = true
        docker.buildxPlugin = true
        let status = wiring(docker, ["PATH": bin.path, "DOCKER_API_VERSION": "1.43"]).status(machine: ready)
        XCTAssertEqual(
            status.credentialHelpers,
            [
                .init(key: "credsStore", name: "desktop", found: true),
                .init(key: "gcr.io", name: "gcloud", found: false),
            ])
        XCTAssertFalse(status.notes.contains { $0.contains("docker-credential-desktop") })
        XCTAssertTrue(status.dockerCLI.tooOld)
        XCTAssertTrue(
            status.notes.contains(
                "DOCKER_API_VERSION=1.43 is older than the engine's minimum 1.44 (unset DOCKER_API_VERSION)"),
            status.notes.joined(separator: "\n"))
        XCTAssertEqual(status.compose.version, "5.5.0")
        XCTAssertEqual(status.buildx.version, "v0.37.2")
        XCTAssertFalse(HVFDockerWiring.apiVersion("1.47", isBelow: "1.44"))
        XCTAssertFalse(HVFDockerWiring.apiVersion("1.44", isBelow: "1.44"))
        XCTAssertTrue(HVFDockerWiring.apiVersion("1.9", isBelow: "1.44"))
        XCTAssertFalse(HVFDockerWiring.apiVersion("garbage", isBelow: "1.44"))
    }

    func testAStoppedOrUninstalledMachineIsANoteAndIsNotStarted() throws {
        let docker = fake()
        let stopped = HVFDockerWiring.Machine(missing: [], phase: .stopped, dockerBuild: .ready)
        let outcome = try wiring(docker).install(use: false, builder: .auto, force: false, machine: stopped)
        XCTAssertTrue(outcome.notes.contains("the machine is stopped: start it with `micropod machine start`"))
        let absent = HVFDockerWiring.Machine(missing: ["disk.ext4"], phase: .stopped, dockerBuild: .unavailable)
        let status = wiring(docker).status(machine: absent)
        XCTAssertEqual(status.machinePhase, "not installed")
        XCTAssertTrue(status.notes.contains { $0.hasPrefix("the machine is not installed (missing disk.ext4)") })
        XCTAssertTrue(status.builder.hasPrefix("none yet"), status.builder)
    }

    func testStatusListsOtherRuntimesAndTheLinks() throws {
        let docker = fake()
        docker.contexts = [
            "desktop-linux": "unix:///Users/me/.docker/run/docker.sock",
            "orbstack": "unix:///Users/me/.orbstack/d.sock",
            "colima-dev": "unix:///Users/me/.colima/dev/docker.sock", "mine": "unix:///x.sock",
        ]
        try FileManager.default.createSymbolicLink(
            atPath: systemSocket.path, withDestinationPath: "/Users/me/.orbstack/run/docker.sock")
        let status = wiring(docker).status(machine: ready)
        XCTAssertEqual(status.otherRuntimes.map(\.name), ["colima-dev", "desktop-linux", "orbstack"])
        XCTAssertEqual(status.systemSocket.target, "/Users/me/.orbstack/run/docker.sock")
        XCTAssertEqual(status.systemSocket.summary, "-> /Users/me/.orbstack/run/docker.sock (OrbStack)")
        XCTAssertEqual(status.canonicalLink.summary, "absent")
        XCTAssertEqual(status.context.state, .absent)
        XCTAssertFalse(status.selected)
        XCTAssertEqual(status.currentContext, "default")
    }

    // MARK: /var/run/docker.sock

    func testSystemSocketAdviceAndUninstallRunNothingPrivileged() throws {
        try FileManager.default.createSymbolicLink(
            atPath: systemSocket.path, withDestinationPath: "/Users/me/.docker/run/docker.sock")
        let docker = fake()

        let advice = wiring(docker).systemSocketAdvice()
        XCTAssertEqual(advice.count, 3, advice.joined(separator: "\n"))
        XCTAssertTrue(advice[0].hasPrefix("To serve clients that ignore contexts, run this yourself (needs sudo"))
        XCTAssertEqual(advice[1], "  sudo ln -sfn \(layout.dockerSocket.path) \(systemSocket.path)")
        XCTAssertEqual(advice[2], "\(systemSocket.path) now: -> /Users/me/.docker/run/docker.sock (Docker Desktop)")
        XCTAssertEqual(docker.calls, [], "advice runs nothing")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: systemSocket.path),
            "/Users/me/.docker/run/docker.sock")

        // Linked here by the user: uninstall says how to undo it, and does not.
        try FileManager.default.removeItem(at: systemSocket)
        try FileManager.default.createSymbolicLink(
            atPath: systemSocket.path, withDestinationPath: layout.dockerSocket.path)
        XCTAssertEqual(
            wiring(docker).systemSocketAdvice(),
            ["\(systemSocket.path) already points at this machine (\(layout.dockerSocket.path))"])
        _ = try wiring(docker).install(use: true, builder: .auto, force: false, machine: ready)
        let outcome = try wiring(docker).uninstall(force: false)
        XCTAssertEqual(outcome.manual.last, "  sudo rm \(systemSocket.path)")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: systemSocket.path), layout.dockerSocket.path)
        XCTAssertTrue(docker.executables.allSatisfy { $0 == dockerPath.path }, "\(docker.executables)")
        XCTAssertFalse(docker.calls.contains { $0.contains("sudo") || $0.contains("ln") }, "\(docker.calls)")
    }

    // MARK: Builder

    private func installBuildKitBundle() throws {
        let daemon = layout.tools.appendingPathComponent("runner/bin/buildkitd")
        try FileManager.default.createDirectory(
            at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: daemon.path, contents: Data("x".utf8)))
        XCTAssertEqual(chmod(daemon.path, 0o755), 0)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: layout.tools.appendingPathComponent("runner/buildkitd.toml").path, contents: Data()))
    }

    func testAutoBuilderAddsTheRemoteBuilderOnlyForAnEngineThatCannotBuildOnItsSocket() throws {
        try installBuildKitBundle()
        let buildx = config.appendingPathComponent("buildx")
        try FileManager.default.createDirectory(at: buildx, withIntermediateDirectories: true)
        let theirs = Data(#"{"Key":"default","Name":"their-builder","Global":false}"#.utf8)
        try theirs.write(to: buildx.appendingPathComponent("current"))
        let docker = fake()

        let own = try wiring(docker).install(use: false, builder: .auto, force: false, machine: ready)
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["buildx", "create"]) }, "\(docker.calls)")
        XCTAssertTrue(
            own.actions.contains("builder: the context's own builder (the engine builds on its Docker socket)"))
        XCTAssertEqual(try record()?.builderInstalled, false)

        let none = try wiring(docker).install(use: false, builder: .none, force: false, machine: fallback)
        XCTAssertFalse(docker.calls.contains { $0.starts(with: ["buildx", "create"]) })
        XCTAssertTrue(none.actions.contains { $0.hasPrefix("builder: none (this engine cannot build") })

        let remote = try wiring(docker).install(use: false, builder: .auto, force: false, machine: fallback)
        XCTAssertTrue(
            docker.calls.contains([
                "buildx", "create", "--name", "micropod-buildkit", "--driver", "remote", "--driver-opt",
                "default-load=true", layout.buildkitEndpoint,
            ]), "\(docker.calls)")
        XCTAssertTrue(
            docker.calls.contains(["--context", "micropod", "buildx", "use", "--default", "micropod-buildkit"]))
        XCTAssertTrue(
            remote.actions.contains { $0.hasPrefix("builder: micropod-buildkit (remote, created") },
            remote.actions.joined(separator: "\n"))
        XCTAssertEqual(try Data(contentsOf: buildx.appendingPathComponent("current")), theirs, "buildx/current kept")
        XCTAssertEqual(try record()?.builderInstalled, true)
        XCTAssertEqual(wiring(docker).status(machine: fallback).remoteBuilder, .ok)

        _ = try wiring(docker).uninstall(force: false)
        XCTAssertTrue(docker.calls.contains(["buildx", "rm", "micropod-buildkit"]))
        XCTAssertEqual(try Data(contentsOf: buildx.appendingPathComponent("current")), theirs)
        XCTAssertNil(docker.contexts["micropod"])
    }

    func testWithoutBuildxUninstallStillRemovesTheContextAndARemoteBuilderIsRefused() throws {
        try installBuildKitBundle()
        let docker = fake()
        docker.buildxPlugin = false
        docker.contexts = ["other": "unix:///other/docker.sock"]
        docker.current = "other"

        XCTAssertThrowsError(try wiring(docker).install(use: true, builder: .remote, force: false, machine: fallback)) {
            let message = $0.localizedDescription
            XCTAssertTrue(
                message.contains("the docker buildx plugin was not found, and the remote builder micropod-buildkit"),
                message)
        }
        XCTAssertNil(docker.contexts["micropod"], "a refusal creates nothing")
        XCTAssertEqual(docker.current, "other")

        // auto on such an engine: the context still comes, the builder line says why there is none.
        let outcome = try wiring(docker).install(use: true, builder: .auto, force: false, machine: fallback)
        XCTAssertEqual(docker.contexts["micropod"], layout.dockerEndpoint)
        XCTAssertTrue(
            outcome.actions.contains { $0.hasPrefix("builder: none (this engine builds only on micropod-buildkit") },
            outcome.actions.joined(separator: "\n"))
        XCTAssertEqual(try record()?.builderInstalled, false)

        let removed = try wiring(docker).uninstall(force: false)
        XCTAssertEqual(docker.current, "other")
        XCTAssertNil(docker.contexts["micropod"], removed.actions.joined(separator: "\n"))
        XCTAssertTrue(removed.actions.contains("no buildx plugin: no buildx builder to remove"))
        XCTAssertNil(try record())
    }

    func testAForeignRemoteBuilderIsRefusedBeforeTheContextIsCreated() throws {
        try installBuildKitBundle()
        let docker = fake()
        docker.builder = ("unix:///other/buildkit.sock", "remote")
        XCTAssertThrowsError(try wiring(docker).install(use: true, builder: .remote, force: false, machine: ready)) {
            XCTAssertTrue($0.localizedDescription.contains("buildx builder 'micropod-buildkit' already exists"))
        }
        XCTAssertNil(docker.contexts["micropod"], "nothing created")
        XCTAssertEqual(docker.current, "default")
        XCTAssertNil(try record())
    }

    func testEnsureContextAndEnsureBuilderAreTheLowerLevelSteps() throws {
        try installBuildKitBundle()
        let docker = fake()
        let setup = HVFBuilderSetup(layout: layout, docker: dockerPath, environment: environment, runner: docker)
        XCTAssertEqual(try setup.ensureContext(force: false), .created)
        XCTAssertEqual(try setup.ensureContext(force: false), .present)
        docker.contexts["micropod"] = "unix:///elsewhere/docker.sock"
        XCTAssertThrowsError(try setup.ensureContext(force: false)) {
            XCTAssertTrue($0.localizedDescription.contains("pass --force to point it at this machine"))
        }
        XCTAssertEqual(try setup.ensureContext(force: true), .updated)
        XCTAssertEqual(docker.contexts["micropod"], layout.dockerEndpoint)
        XCTAssertFalse(docker.calls.contains { $0.first == "buildx" }, "the context step touches no builder")

        let lines = try setup.ensureBuilder()
        XCTAssertEqual(docker.builder?.endpoint, layout.buildkitEndpoint)
        XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
        XCTAssertEqual(docker.current, "default", "neither step selects anything")
    }
}

/// The docker CLI as `HVFDockerWiring` uses it: contexts with a current one
/// (`docker context rm` refuses the one in use), plugins that may be
/// missing, the client half of `docker version`, and the buildx calls of
/// `HVFBuilderSetup` (`buildx use` rewrites buildx's `current` file).
final class FakeContextCLI: HVFCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var envs: [[String: String]] = []
    private var paths: [String] = []
    private var contextHosts: [String: String] = [:]
    private var currentName = "default"
    private var builderState: (endpoint: String, driver: String)?
    private var contextDefault: String?
    private var hasCompose = true
    private var hasBuildx = true
    private var api = "1.55"
    let buildx: URL

    init(buildx: URL) { self.buildx = buildx }

    private func locked<T>(_ body: () -> T) -> T { lock.withLock(body) }

    var calls: [[String]] {
        get { locked { recorded } }
        set { locked { recorded = newValue } }
    }
    var environments: [[String: String]] { locked { envs } }
    var executables: [String] { locked { paths } }
    var contexts: [String: String] {
        get { locked { contextHosts } }
        set { locked { contextHosts = newValue } }
    }
    var current: String {
        get { locked { currentName } }
        set { locked { currentName = newValue } }
    }
    var builder: (endpoint: String, driver: String)? {
        get { locked { builderState } }
        set { locked { builderState = newValue } }
    }
    var compose: Bool {
        get { locked { hasCompose } }
        set { locked { hasCompose = newValue } }
    }
    var buildxPlugin: Bool {
        get { locked { hasBuildx } }
        set { locked { hasBuildx = newValue } }
    }
    var apiVersion: String {
        get { locked { api } }
        set { locked { api = newValue } }
    }

    private func inspect(_ name: String, _ host: String) -> HVFCommandResult {
        HVFCommandResult(status: 0, stdout: #"[{"Name":"\#(name)","Endpoints":{"docker":{"Host":"\#(host)"}}}]"#)
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> HVFCommandResult {
        locked {
            recorded.append(arguments)
            envs.append(environment)
            paths.append(executable.path)
        }
        switch arguments {
        case _ where arguments.count == 5 && arguments[0] == "--host" && arguments[2] == "version":
            return HVFCommandResult(
                status: 1, stdout: #"{"Version":"29.7.2","ApiVersion":"\#(apiVersion)"}"# + "\n",
                stderr: "failed to connect to the docker API at \(arguments[1])")
        case ["context", "show"]:
            return HVFCommandResult(status: 0, stdout: current + "\n")
        case ["context", "ls", "--format", "{{json .}}"]:
            let lines = (["default": "unix:///var/run/docker.sock"].merging(contexts) { $1 }).keys.sorted().map {
                name in
                let host = name == "default" ? "unix:///var/run/docker.sock" : contexts[name] ?? ""
                return #"{"Current":\#(name == current),"DockerEndpoint":"\#(host)","Name":"\#(name)"}"#
            }
            return HVFCommandResult(status: 0, stdout: lines.joined(separator: "\n") + "\n")
        case _ where arguments.count == 3 && arguments.starts(with: ["context", "inspect"]):
            let name = arguments[2]
            if name == "default" { return inspect(name, "unix:///var/run/docker.sock") }
            guard let host = contexts[name] else {
                return HVFCommandResult(
                    status: 1, stdout: "[]\n",
                    stderr: "context \"\(name)\": context not found: open …/meta.json: no such file or directory")
            }
            return inspect(name, host)
        case _ where arguments.starts(with: ["context", "create"]) || arguments.starts(with: ["context", "update"]):
            let name = arguments[2]
            let creating = arguments[1] == "create"
            if creating == (contexts[name] != nil) {
                return HVFCommandResult(
                    status: 1, stderr: "context \"\(name)\" \(creating ? "already exists" : "not found")")
            }
            contexts[name] = arguments.last.map { String($0.dropFirst("host=".count)) }
            return HVFCommandResult(status: 0, stdout: name + "\n")
        case _ where arguments.count == 3 && arguments.starts(with: ["context", "use"]):
            let name = arguments[2]
            guard name == "default" || contexts[name] != nil else {
                return HVFCommandResult(status: 1, stderr: "context \"\(name)\": context not found")
            }
            current = name
            return HVFCommandResult(status: 0, stdout: name + "\n")
        case _ where arguments.count == 3 && arguments.starts(with: ["context", "rm"]):
            let name = arguments[2]
            if name == current {
                return HVFCommandResult(status: 1, stderr: "context \"\(name)\" is in use, set -f flag to force remove")
            }
            contexts[name] = nil
            return HVFCommandResult(status: 0, stdout: name + "\n")
        case ["compose", "version", "--short"]:
            return compose
                ? HVFCommandResult(status: 0, stdout: "5.5.0\n")
                : HVFCommandResult(status: 125, stderr: "unknown flag: --short")
        case _ where !buildxPlugin && (arguments.first == "buildx" || arguments.dropFirst(2).first == "buildx"):
            return HVFCommandResult(
                status: 1, stderr: "docker: unknown command: docker buildx\n\nRun 'docker --help' for more information")
        case ["buildx", "version"]:
            return HVFCommandResult(status: 0, stdout: "github.com/docker/buildx v0.37.2 2d379c0c3f22\n")
        case ["buildx", "inspect", "micropod-buildkit"]:
            guard let builder else {
                return HVFCommandResult(status: 1, stderr: "ERROR: no builder \"micropod-buildkit\" found")
            }
            return HVFCommandResult(
                status: 0,
                stdout:
                    "Name: micropod-buildkit\nDriver: \(builder.driver)\nNodes:\nName: n0\nEndpoint: \(builder.endpoint)\n"
            )
        case _ where arguments.starts(with: ["buildx", "create"]):
            builder = (arguments.last ?? "", "remote")
            return HVFCommandResult(status: 0)
        case ["buildx", "rm", "micropod-buildkit"]:
            builder = nil
            locked { contextDefault = nil }
            return HVFCommandResult(status: 0)
        case ["--context", "micropod", "buildx", "inspect"]:
            guard contexts["micropod"] != nil else { return HVFCommandResult(status: 1, stderr: "not found") }
            if locked({ contextDefault }) == nil {
                // buildx resets `current` to a context with no default builder of its own.
                try FileManager.default.createDirectory(at: buildx, withIntermediateDirectories: true)
                try Data(#"{"Key":"micropod","Name":"","Global":false}"#.utf8)
                    .write(to: buildx.appendingPathComponent("current"))
            }
            return HVFCommandResult(status: 0, stdout: "Name: \(locked { contextDefault } ?? "micropod")\n")
        case ["--context", "micropod", "buildx", "use", "--default", "micropod-buildkit"]:
            locked { contextDefault = "micropod-buildkit" }
            try FileManager.default.createDirectory(at: buildx, withIntermediateDirectories: true)
            try Data(#"{"Key":"micropod","Name":"micropod-buildkit","Global":false}"#.utf8)
                .write(to: buildx.appendingPathComponent("current"))
            return HVFCommandResult(status: 0)
        default:
            return HVFCommandResult(status: 2, stderr: "unexpected: \(arguments)")
        }
    }
}
