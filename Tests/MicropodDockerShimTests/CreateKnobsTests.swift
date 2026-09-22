import MicropodCore
import XCTest

@testable import MicropodDockerShim

/// Docker create-knob passthrough: resources Docker clients set in
/// HostConfig must reach `container run` instead of being silently dropped
/// (every container got the 4-CPU/1G/64M-shm defaults regardless).
final class CreateKnobsTests: XCTestCase {
    private static func request(
        nanoCpus: Int64? = nil,
        memory: Int64? = nil,
        shmSize: Int64? = nil,
        tmpfs: [String: String]? = nil,
        dns: [String]? = nil,
        dnsSearch: [String]? = nil,
        ulimits: [DockerUlimit]? = nil,
        entrypoint: [String]? = nil,
        cmd: [String]? = nil
    ) throws -> ContainerRunRequest {
        var body = DockerCreateRequest(Image: "alpine:3.22")
        var hostConfig = DockerHostConfig()
        hostConfig.NanoCpus = nanoCpus
        hostConfig.Memory = memory
        hostConfig.ShmSize = shmSize
        hostConfig.Tmpfs = tmpfs
        hostConfig.Dns = dns
        hostConfig.DnsSearch = dnsSearch
        hostConfig.Ulimits = ulimits
        body.HostConfig = hostConfig
        body.Entrypoint = entrypoint
        body.Cmd = cmd
        return try Router.buildRunRequest(from: body, name: nil)
    }

    func testNanoCpusMapsToWholeCPUs() throws {
        let request = try Self.request(nanoCpus: 2_000_000_000)
        XCTAssertEqual(request.cpus, 2.0)
    }

    func testNanoCpusAbsentMeansDefault() throws {
        XCTAssertNil(try Self.request().cpus)
        XCTAssertNil(try Self.request(nanoCpus: 0).cpus)
    }

    func testMemoryAndShmBytesToMiB() throws {
        let request = try Self.request(memory: 512 * 1024 * 1024, shmSize: 256 * 1024 * 1024)
        XCTAssertEqual(request.memory, "512MiB")
        XCTAssertEqual(request.shmSize, "256MiB")
    }

    func testTmpfsKeysSortedOptionsDropped() throws {
        let request = try Self.request(tmpfs: ["/b": "size=10m", "/a": ""])
        XCTAssertEqual(request.tmpfs, ["/a", "/b"])
    }

    func testDnsPassthroughFiltersEmpties() throws {
        let request = try Self.request(dns: ["8.8.8.8", ""], dnsSearch: ["example.com"])
        XCTAssertEqual(request.dns, ["8.8.8.8"])
        XCTAssertEqual(request.dnsSearch, ["example.com"])
    }

    func testUlimitsMapping() throws {
        let request = try Self.request(ulimits: [
            DockerUlimit(Name: "nofile", Soft: 1024, Hard: 2048),
            DockerUlimit(Name: "nproc", Soft: 512, Hard: 512),
            DockerUlimit(Name: "memlock", Soft: -1, Hard: -1),
            DockerUlimit(Name: "", Soft: 1, Hard: 1),
        ])
        XCTAssertEqual(request.ulimits, ["nofile=1024:2048", "nproc=512"])
    }

    func testEntrypointSplitsHeadFromTail() throws {
        // Single-element entrypoints behave exactly as before.
        var request = try Self.request(entrypoint: ["echo"], cmd: ["hi"])
        XCTAssertEqual(request.entrypoint, "echo")
        XCTAssertEqual(request.arguments, ["hi"])
        // Multi-element entrypoints split head/tail instead of space-joining
        // (the join produced "failed to find target executable 'sh -c ...'").
        request = try Self.request(entrypoint: ["sh", "-c", "echo ep-works"], cmd: ["ignored"])
        XCTAssertEqual(request.entrypoint, "sh")
        XCTAssertEqual(request.arguments, ["-c", "echo ep-works", "ignored"])
        // Absent/empty entrypoints omit the flag and pass Cmd through.
        request = try Self.request(cmd: ["echo", "hi"])
        XCTAssertNil(request.entrypoint)
        XCTAssertEqual(request.arguments, ["echo", "hi"])
        request = try Self.request(entrypoint: [""], cmd: ["echo"])
        XCTAssertNil(request.entrypoint)
        XCTAssertEqual(request.arguments, ["echo"])
    }

    func testCpuCountStringRejectsFloatSpelling() throws {
        // Apple rejects "2.0" outright (verified live): whole Doubles must
        // render as integers, in both run and build commands.
        XCTAssertEqual(ContainerCommandFactory.cpuCountString(2.0), "2")
        XCTAssertEqual(ContainerCommandFactory.cpuCountString(0.0), "0")
        let runArgs = ContainerCommandFactory.run(
            ContainerRunRequest(
                image: "alpine:3.22", name: nil, detach: true, cpus: 2.0,
                memory: nil, env: [], envFiles: [], publishedPorts: [],
                volumes: [], tmpfs: [], labels: [], interactive: false,
                tty: false, useInit: false, readOnly: false, rosetta: false,
                user: nil, shmSize: nil, dns: [], dnsSearch: [], capAdd: [],
                capDrop: [], ulimits: [], networks: [], platform: nil,
                workdir: nil, entrypoint: nil, arguments: [])
        ).arguments
        XCTAssertTrue(
            runArgs.contains("--cpus") && !runArgs.contains("2.0"),
            "args were \(runArgs)")
        XCTAssertEqual(runArgs[runArgs.firstIndex(of: "--cpus")! + 1], "2")
    }
}
