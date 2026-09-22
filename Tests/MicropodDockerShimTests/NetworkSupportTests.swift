import MicropodCore
import XCTest

@testable import MicropodDockerShim

/// Subnet allocation + managed hosts DNS: the two emulations that make
/// custom Apple networks behave like Docker bridge networks.
final class NetworkSupportTests: XCTestCase {
    // MARK: - Allocator

    func testCandidateIsDeterministicAndBounded() {
        let a = DockerNetworkAllocator.candidateSubnet(name: "proj_default")
        let b = DockerNetworkAllocator.candidateSubnet(name: "proj_default")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("10."), a)
        XCTAssertTrue(a.hasSuffix(".0/24"), a)
        let second = Int(a.split(separator: ".")[1])!
        XCTAssertTrue((10...250).contains(second), "\(second)")
        XCTAssertNotEqual(a, DockerNetworkAllocator.candidateSubnet(name: "other"))
    }

    func testAllocateSkipsCollisions() {
        let first = DockerNetworkAllocator.allocate(name: "proj_default", existingSubnets: [])!
        // Same name + its own subnet taken → different, non-overlapping pick.
        let second = DockerNetworkAllocator.allocate(
            name: "proj_default", existingSubnets: [first])!
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(DockerNetworkAllocator.overlaps(first, second))
        // Explicit subnets are honored by callers (allocator only fills gaps).
        XCTAssertNil(
            DockerNetworkAllocator.allocate(name: "x", existingSubnets: [], attempts: 0))
    }

    func testOverlaps() {
        XCTAssertTrue(DockerNetworkAllocator.overlaps("10.66.0.0/24", "10.66.0.0/24"))
        XCTAssertTrue(DockerNetworkAllocator.overlaps("10.66.0.0/24", "10.0.0.0/8"))
        XCTAssertTrue(DockerNetworkAllocator.overlaps("10.66.0.128/25", "10.66.0.0/24"))
        XCTAssertFalse(DockerNetworkAllocator.overlaps("10.66.0.0/24", "10.67.0.0/24"))
        XCTAssertFalse(DockerNetworkAllocator.overlaps("192.168.65.0/24", "10.66.0.0/24"))
        XCTAssertFalse(DockerNetworkAllocator.overlaps("garbage", "10.0.0.0/8"))
        XCTAssertFalse(DockerNetworkAllocator.overlaps("10.0.0.0/24", "not-a-cidr"))
    }

    // MARK: - Hosts file rendering

    func testRenderLocalhostAndMembers() {
        let content = HostsFile.render(members: [
            HostsFile.Member(ip: "10.66.0.4", names: ["db", "db", "abc123def456", "db-full-id"]),
            HostsFile.Member(ip: "10.66.0.3", names: ["web"]),
        ])
        let lines = content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "127.0.0.1\tlocalhost")
        XCTAssertEqual(lines[1], "::1\tlocalhost")
        XCTAssertTrue(lines.contains("10.66.0.3\tweb"), content)
        // Sorted by IP, deduped names.
        XCTAssertTrue(lines.contains("10.66.0.4\tdb abc123def456 db-full-id"), content)
    }

    func testRenderFiltersInvalidNames() {
        let content = HostsFile.render(members: [
            HostsFile.Member(ip: "10.0.0.5", names: ["has space", "", "ok-name"])
        ])
        XCTAssertTrue(content.contains("ok-name"))
        XCTAssertFalse(content.contains("has space"))
    }

    func testRenderEmptyIsLocalhostOnly() {
        XCTAssertEqual(
            HostsFile.render(members: []), "127.0.0.1\tlocalhost\n::1\tlocalhost\n")
    }

    // MARK: - Create-time injection

    private func createRequest(networkMode: String, binds: [String] = []) -> DockerCreateRequest {
        var body = DockerCreateRequest(Image: "alpine:3.20")
        var hostConfig = DockerHostConfig()
        hostConfig.NetworkMode = networkMode
        hostConfig.Binds = binds
        body.HostConfig = hostConfig
        return body
    }

    func testHostsBindInjectedForCustomNetworks() throws {
        let request = try Self.buildRunRequestThrowing(body: createRequest(networkMode: "mynet"))
        XCTAssertTrue(
            request.volumes.contains { $0.hasSuffix(":/etc/hosts:ro") },
            "volumes were \(request.volumes)")
    }

    func testNoHostsBindOnDefaultNetwork() throws {
        for mode in ["", "default", "bridge", "host", "none"] {
            let request = try Self.buildRunRequestThrowing(body: createRequest(networkMode: mode))
            XCTAssertFalse(
                request.volumes.contains { $0.contains("/etc/hosts") },
                "mode \(mode) must not inject")
        }
    }

    func testExistingEtcHostsBindWins() throws {
        let request = try Self.buildRunRequestThrowing(
            body: createRequest(networkMode: "mynet", binds: ["/my/hosts:/etc/hosts"]))
        XCTAssertEqual(
            request.volumes.filter { $0.contains("/etc/hosts") },
            ["/my/hosts:/etc/hosts"])
    }

    private static func buildRunRequestThrowing(body: DockerCreateRequest) throws -> ContainerRunRequest {
        try Router.buildRunRequest(from: body, name: nil)
    }
}
