import XCTest

@testable import MicropodDockerShim

final class RyukInterceptTests: XCTestCase {
    func testIsRyukDetection() {
        XCTAssertTrue(RyukSupport.isRyuk("testcontainers/ryuk:0.14.0"))
        XCTAssertTrue(RyukSupport.isRyuk("docker.io/testcontainers/ryuk:0.11.0"))
        XCTAssertFalse(RyukSupport.isRyuk("alpine:3.20"))
        XCTAssertFalse(RyukSupport.isRyuk("testcontainers/other:1.0"))
    }

    private func ryukBody() -> DockerCreateRequest {
        var body = DockerCreateRequest()
        body.Image = "testcontainers/ryuk:0.14.0"
        body.Env = ["EXISTING=1", "DOCKER_HOST=unix:///var/run/docker.sock"]
        body.HostConfig = DockerHostConfig()
        body.HostConfig?.Binds = [
            "/var/run/docker.sock:/var/run/docker.sock",
            "/tmp/data:/data",
        ]
        return body
    }

    func testInterceptStripsDockerSocketBinds() {
        let (result, notes) = RyukSupport.intercept(ryukBody(), bridgeHost: "192.168.64.1", tcpPort: 45455)
        XCTAssertEqual(result.HostConfig?.Binds, ["/tmp/data:/data"])
        XCTAssertFalse(notes.isEmpty)
    }

    func testInterceptInjectsTCPDockerHost() {
        let (result, _) = RyukSupport.intercept(ryukBody(), bridgeHost: "192.168.64.1", tcpPort: 45455)
        let env = result.Env ?? []
        XCTAssertTrue(
            env.contains("DOCKER_HOST=tcp://192.168.64.1:45455"),
            "env was \(env)")
        XCTAssertEqual(env.filter { $0.hasPrefix("DOCKER_HOST=") }.count, 1)
        XCTAssertTrue(env.contains("EXISTING=1"), "pre-existing env must survive")
    }

    func testInterceptEnsures8080Published() {
        var body = ryukBody()
        body.HostConfig?.PortBindings = [:]
        let (result, _) = RyukSupport.intercept(body, bridgeHost: "192.168.64.1", tcpPort: 45455)
        XCTAssertNotNil(result.HostConfig?.PortBindings?["8080/tcp"])

        // An existing 8080/tcp binding is preserved.
        var withPort = ryukBody()
        withPort.HostConfig?.PortBindings = ["8080/tcp": [DockerPortBinding(HostIp: "0.0.0.0", HostPort: "9999")]]
        let (kept, _) = RyukSupport.intercept(withPort, bridgeHost: "192.168.64.1", tcpPort: 45455)
        XCTAssertEqual(kept.HostConfig?.PortBindings?["8080/tcp"]?.first?.HostPort, "9999")
    }

    func testNonRyukDockerSockIsRedirected() {
        // Any DinD client (e.g. the cuttlefish runner) mounting the socket
        // gets the same strip + TCP redirect as Ryuk — but no 8080 publish.
        var body = DockerCreateRequest()
        body.Image = "alpine:3.20"
        body.HostConfig = DockerHostConfig()
        body.HostConfig?.Binds = ["/var/run/docker.sock:/var/run/docker.sock"]
        let (result, notes) = RyukSupport.intercept(body, bridgeHost: "192.168.64.1", tcpPort: 45455)
        XCTAssertEqual(result.HostConfig?.Binds?.count, 0, "binds were \(result.HostConfig?.Binds ?? [])")
        XCTAssertTrue(
            (result.Env ?? []).contains("DOCKER_HOST=tcp://192.168.64.1:45455"),
            "env was \(result.Env ?? [])")
        XCTAssertNil(result.HostConfig?.PortBindings?["8080/tcp"], "only Ryuk gets 8080 published")
        XCTAssertFalse(notes.isEmpty)
    }

    func testNonRyukWithoutSockBindUntouched() {
        var body = DockerCreateRequest()
        body.Image = "alpine:3.20"
        body.HostConfig = DockerHostConfig()
        body.HostConfig?.Binds = ["/tmp/data:/data"]
        let (result, notes) = RyukSupport.intercept(body, bridgeHost: "192.168.64.1", tcpPort: 45455)
        XCTAssertEqual(result.HostConfig?.Binds, ["/tmp/data:/data"])
        XCTAssertTrue(notes.isEmpty)
    }

    func testExistingDockerHostOverwritten() {
        var body = DockerCreateRequest()
        body.Image = "myrunner:latest"
        body.Env = ["DOCKER_HOST=unix:///var/run/docker.sock"]
        body.HostConfig = DockerHostConfig()
        body.HostConfig?.Binds = ["/var/run/docker.sock:/var/run/docker.sock"]
        let (result, _) = RyukSupport.intercept(body, bridgeHost: "192.168.64.1", tcpPort: 45455)
        let hosts = (result.Env ?? []).filter { $0.hasPrefix("DOCKER_HOST=") }
        XCTAssertEqual(hosts, ["DOCKER_HOST=tcp://192.168.64.1:45455"])
    }
}
