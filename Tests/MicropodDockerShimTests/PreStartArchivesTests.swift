import MicropodCore
import XCTest

@testable import MicropodDockerShim

/// testcontainers uploads `Files` between create and start; the Apple runtime
/// cannot copy into a stopped container, so the shim wraps the container's
/// command and delivers the archives at first start. These pin the Docker
/// command-resolution rules the wrapper depends on and the wrapper's shape.
final class PreStartArchivesTests: XCTestCase {
    func testImageCommandWhenCreateSetsNeither() {
        XCTAssertEqual(
            PreStartArchives.effectiveArgv(
                entrypoint: nil, cmd: nil, imageEntrypoint: ["/docker-entrypoint.sh"], imageCmd: ["postgres"]),
            ["/docker-entrypoint.sh", "postgres"])
    }

    func testCreateCmdReplacesImageCmdOnly() {
        // WireMock: the test passes flags as Cmd; the image entrypoint stays.
        XCTAssertEqual(
            PreStartArchives.effectiveArgv(
                entrypoint: nil, cmd: ["--disable-banner"],
                imageEntrypoint: ["/docker-entrypoint.sh"], imageCmd: ["java", "-jar", "wm.jar"]),
            ["/docker-entrypoint.sh", "--disable-banner"])
    }

    func testCreateEntrypointDropsImageCmd() {
        XCTAssertEqual(
            PreStartArchives.effectiveArgv(
                entrypoint: ["/bin/app"], cmd: nil, imageEntrypoint: ["/entry"], imageCmd: ["serve"]),
            ["/bin/app"])
    }

    func testEmptyStringEntrypointClearsIt() {
        XCTAssertEqual(
            PreStartArchives.effectiveArgv(
                entrypoint: [""], cmd: ["sh", "-c", "true"], imageEntrypoint: ["/entry"], imageCmd: nil),
            ["sh", "-c", "true"])
    }

    func testWrappedBodyExecsOriginalCommandAfterMarker() throws {
        var body = DockerCreateRequest(Image: "quay.io/keycloak/keycloak:26")
        body.Cmd = ["start-dev", "--import-realm"]
        let marker = PreStartArchives.markerPath(token: "abc123")
        let wrapped = PreStartArchives.wrapped(
            body, argv: ["/opt/keycloak/bin/kc.sh", "start-dev", "--import-realm"], marker: marker)
        XCTAssertEqual(wrapped.Entrypoint?.prefix(2), ["/bin/sh", "-c"])
        XCTAssertEqual(wrapped.Entrypoint?.last, PreStartArchives.wrapperName)
        XCTAssertEqual(wrapped.Cmd, ["/opt/keycloak/bin/kc.sh", "start-dev", "--import-realm"])
        let script = try XCTUnwrap(wrapped.Entrypoint?[2])
        XCTAssertTrue(script.contains("'\(marker)'"))
        XCTAssertTrue(script.hasSuffix("exec \"$@\""))
        XCTAssertTrue(script.contains("exit 125"))

        let request = try Router.buildRunRequest(from: wrapped, name: "kc-test")
        XCTAssertEqual(request.arguments.first, "-c")
        XCTAssertEqual(Array(request.arguments.suffix(3)), ["/opt/keycloak/bin/kc.sh", "start-dev", "--import-realm"])
    }

    func testWrapperWaitsForMarkerThenExecs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("ready").path
        let script = PreStartArchives.wrapperScript(marker: marker, timeoutSeconds: 5)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, PreStartArchives.wrapperName, "/bin/sh", "-c", "exit 7"]
        try process.run()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(process.isRunning, "the wrapper must hold until the marker exists")
        FileManager.default.createFile(atPath: marker, contents: Data())
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 7, "exec'd command's exit code passes through")
    }

    func testWrapperTimesOutWith125() throws {
        let script = PreStartArchives.wrapperScript(marker: "/nonexistent/\(UUID().uuidString)", timeoutSeconds: 1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, PreStartArchives.wrapperName, "/usr/bin/true"]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 125)
    }

    func testImageArgvFromDockerInspect() {
        let json = #"{"Config":{"Entrypoint":["/entry.sh"],"Cmd":["serve","--port","80"]}}"#
        let argv = PreStartArchives.imageArgv(fromDockerInspect: Data(json.utf8))
        XCTAssertEqual(argv.entrypoint, ["/entry.sh"])
        XCTAssertEqual(argv.cmd, ["serve", "--port", "80"])
        XCTAssertNil(PreStartArchives.imageArgv(fromDockerInspect: Data("{}".utf8)).cmd)
    }

    func testStateStashesInOrderAndForgetRemovesFiles() async throws {
        let state = ShimState()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("1.tar")
        let second = dir.appendingPathComponent("2.tar")
        for file in [first, second] { FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)) }

        await state.stashPreStartArchive(PreStartArchive(destination: "/", file: first), for: "c1")
        await state.stashPreStartArchive(PreStartArchive(destination: "/etc", file: second), for: "c1")
        let taken = await state.takePreStartArchives(for: "c1")
        XCTAssertEqual(taken.map(\.destination), ["/", "/etc"])
        let again = await state.takePreStartArchives(for: "c1")
        XCTAssertTrue(again.isEmpty)

        await state.stashPreStartArchive(PreStartArchive(destination: "/", file: first), for: "c2")
        await state.forget(id: "c2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }
}

final class PreStartArchivesHostFilesTests: XCTestCase {
    func testRegularFilesWalksTreeWithModesAndSkipsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let deep = root.appendingPathComponent("opt/keycloak/data/import")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realm = deep.appendingPathComponent("realm.json")
        FileManager.default.createFile(atPath: realm.path, contents: Data("{}".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: realm.path)
        FileManager.default.createFile(atPath: root.appendingPathComponent("a.txt").path, contents: Data("a".utf8))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: realm)

        let files = PreStartArchives.regularFiles(under: root)
        XCTAssertEqual(files.map(\.relativePath), ["a.txt", "opt/keycloak/data/import/realm.json"])
        XCTAssertEqual(files.last?.mode, 0o640)
    }

    func testMissingExecutableIsRecognised() {
        struct Fake: Error, CustomStringConvertible { var description: String }
        let apple = Fake(description: #"vmexec error: internalError: "failed to find target executable tar""#)
        XCTAssertTrue(Router.isMissingExecutable(apple, "tar"))
        XCTAssertFalse(Router.isMissingExecutable(apple, "chmod"))
        XCTAssertFalse(Router.isMissingExecutable(Fake(description: "tar: short read"), "tar"))
    }
}

final class DefaultNetworkNameTests: XCTestCase {
    func testDefaultNetworkIsReportedAsBridge() {
        XCTAssertEqual(DockerMapper.dockerNetworkName("default"), "bridge")
        XCTAssertEqual(DockerMapper.dockerNetworkName("reaper_default"), "reaper_default")
    }
}

final class DockerLogTailTests: XCTestCase {
    func testAbsentOrAllMeansEveryLine() {
        XCTAssertNil(Router.dockerLogTail(""))
        XCTAssertNil(Router.dockerLogTail("all"))
        XCTAssertNil(Router.dockerLogTail("ALL"))
        XCTAssertNil(Router.dockerLogTail("-1"))
    }

    func testNumbersAreKept() {
        XCTAssertEqual(Router.dockerLogTail("0"), 0)
        XCTAssertEqual(Router.dockerLogTail("250"), 250)
    }
}

final class EndpointNetworkAttachTests: XCTestCase {
    /// testcontainers-go names `ContainerRequest.Networks[0]` only in
    /// NetworkingConfig and leaves NetworkMode empty; Docker attaches it.
    func testEndpointsConfigAttachesCustomNetwork() throws {
        var body = DockerCreateRequest(Image: "supabase/gotrue:v2.169.0")
        body.HostConfig = DockerHostConfig()
        body.NetworkingConfig = DockerNetworkingConfig(
            EndpointsConfig: ["tc-net-1": DockerEndpointSettings(Aliases: ["db"], IPAddress: nil)])
        XCTAssertEqual(body.attachedNetworks, ["tc-net-1"])
        XCTAssertEqual(body.aliases(for: "tc-net-1"), ["db"])
        let request = try Router.buildRunRequest(from: body, name: nil)
        XCTAssertTrue(request.volumes.contains { $0.hasSuffix(":/etc/hosts:ro") })
    }

    func testDefaultEndpointsStayOnDefaultNetwork() {
        var body = DockerCreateRequest(Image: "alpine:3.22")
        body.NetworkingConfig = DockerNetworkingConfig(
            EndpointsConfig: ["bridge": DockerEndpointSettings(Aliases: nil, IPAddress: nil)])
        XCTAssertEqual(body.attachedNetworks, [])
    }

    func testNetworkModeWinsOverEndpoints() {
        var body = DockerCreateRequest(Image: "alpine:3.22")
        var host = DockerHostConfig()
        host.NetworkMode = "mynet"
        body.HostConfig = host
        body.NetworkingConfig = DockerNetworkingConfig(
            EndpointsConfig: ["other": DockerEndpointSettings(Aliases: nil, IPAddress: nil)])
        XCTAssertEqual(body.attachedNetworks, ["mynet"])
    }
}
