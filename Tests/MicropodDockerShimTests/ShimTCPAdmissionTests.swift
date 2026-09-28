import Foundation
import MicropodCore
import XCTest

@testable import MicropodDockerShim

/// The shim's TCP listener is an unauthenticated Docker API: it must not be
/// reachable from the LAN (bound to loopback + vmnet gateways only), from a
/// web page (Origin / Sec-Fetch-* refused), or through DNS rebinding (Host
/// allowlist). The unix socket is not reachable from a browser and keeps
/// accepting whatever Host a client sends.
final class ShimTCPAdmissionTests: XCTestCase {
    private var shim: ShimTestSupport.MockShim!

    override func setUp() async throws {
        shim = try ShimTestSupport.makeMockShim()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shim.stateDir)
    }

    // MARK: - Host / Origin over TCP

    func testDockerClientHostsAreAccepted() throws {
        let port = shim.port
        for host in [
            "127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)", "192.168.65.1:\(port)",
            "api.moby.localhost", "docker", "localhost",
        ] {
            let response = try shim.raw().request("GET", "/_ping", headers: [("Host", host)])
            XCTAssertEqual(response.status, 200, host)
        }
        // The Docker Go client's body-less POST carries text/plain.
        let start = try shim.raw().request(
            "POST", "/containers/nope/start", headers: [("Content-Type", "text/plain")])
        XCTAssertNotEqual(start.status, 403)
    }

    func testRebindingHostIsRefused() throws {
        for host in ["evil.example", "evil.example:\(shim.port)", "docker.evil.example"] {
            let response = try shim.raw().request("GET", "/_ping", headers: [("Host", host)])
            XCTAssertEqual(response.status, 403, host)
            XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("Host"), host)
        }
    }

    func testBrowserRequestsAreRefused() throws {
        let body = ShimTestSupport.jsonBody(["Image": "alpine:3.20"])
        for header in [
            ("Origin", "http://evil.example"), ("Origin", "null"), ("Sec-Fetch-Site", "cross-site"),
            ("Sec-Fetch-Mode", "no-cors"),
        ] {
            let response = try shim.raw().request(
                "POST", "/containers/create", body: body,
                headers: [("Content-Type", "text/plain"), header])
            XCTAssertEqual(response.status, 403, "\(header)")
        }
        // Nothing reached the runtime.
        let calls = (try? String(contentsOf: shim.stateDir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.contains("create"), calls)
    }

    // MARK: - Unix socket: no Host check

    func testUnixSocketSkipsHostCheck() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-shim-\(UUID().uuidString.prefix(8)).sock").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let server = ShimHTTPServer(handler: { _, _ in .raw(200, [("Content-Type", "text/plain")], Data("OK\n".utf8)) })
        try server.listenUnix(path: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request = "GET /_ping HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let n = recv(fd, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(n, 0)
        XCTAssertTrue(String(decoding: buffer[0..<max(n, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 200"))
    }

    // MARK: - Gateway resolution

    private static func network(
        _ id: String, gateway: String, subnet: String, builtin: Bool = false
    ) -> Micropod_V1_Network {
        var network = Micropod_V1_Network()
        network.id = id
        network.ipv4Gateway = gateway
        network.ipv4Subnet = subnet
        network.builtin = builtin
        return network
    }

    func testGatewaysResolveFromTheRuntimeNetworkList() async {
        let gateways = VMNetGateways(list: {
            [
                Self.network("default", gateway: "192.168.65.1", subnet: "192.168.65.0/24", builtin: true),
                Self.network("reaper_default", gateway: "10.208.87.1", subnet: "10.208.87.0/24"),
                Self.network("broken", gateway: "", subnet: ""),
            ]
        })
        await gateways.refresh()
        let defaultGateway = await gateways.defaultGateway
        let custom = await gateways.gateway(forNetwork: "reaper_default")
        let unknown = await gateways.gateway(forNetwork: "nope")
        let count = await gateways.networks.count
        XCTAssertEqual(defaultGateway, "192.168.65.1")
        XCTAssertEqual(custom, "10.208.87.1")
        XCTAssertEqual(unknown, "192.168.65.1", "unknown networks fall back to the default gateway")
        XCTAssertEqual(count, 2, "a network without a gateway is ignored")

        let filter = gateways.peerFilter(forGateway: "192.168.65.1")
        XCTAssertTrue(filter("192.168.65.7"))
        XCTAssertFalse(filter("192.168.1.50"), "a LAN peer never reaches a gateway listener")
        XCTAssertFalse(filter("10.208.87.2"), "another network's guest uses its own gateway")
    }

    func testSubnetArithmetic() {
        let subnet = IPv4Subnet(cidr: "192.168.65.0/24")
        XCTAssertEqual(subnet?.contains("192.168.65.254"), true)
        XCTAssertEqual(subnet?.contains("192.168.66.1"), false)
        XCTAssertEqual(IPv4Subnet(cidr: "10.0.0.0/8")?.contains("10.255.1.1"), true)
        XCTAssertNil(IPv4Subnet(cidr: "fd00::/64"))
        XCTAssertNil(IPv4Subnet(cidr: "192.168.65.0/33"))
    }

    /// DOCKER_HOST for a docker.sock bind is the container's network gateway
    /// — resolved, not the stale 192.168.64.1 default.
    func testDockerHostUsesTheResolvedGateway() async throws {
        let gateways = VMNetGateways(list: {
            [
                Self.network("default", gateway: "192.168.65.1", subnet: "192.168.65.0/24", builtin: true),
                Self.network("ci-net", gateway: "10.20.0.1", subnet: "10.20.0.0/24"),
            ]
        })
        let client = ContainerCLIClient(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let router = Router(
            config: ShimConfig(bridgeHost: "127.0.0.1", tcpPort: 45455), state: ShimState(),
            events: EventsHub(containers: ContainerService(client: client), interval: 60), client: client,
            sharedFS: nil, gateways: gateways)

        var body = DockerCreateRequest()
        body.Image = "testcontainers/ryuk:0.11.0"
        var resolved = await router.bridgeHost(for: body)
        XCTAssertEqual(resolved, "192.168.65.1")
        XCTAssertEqual(
            RyukSupport.intercept(body, bridgeHost: resolved, tcpPort: 45455).request.Env,
            ["DOCKER_HOST=tcp://192.168.65.1:45455"])

        var hostConfig = DockerHostConfig()
        hostConfig.NetworkMode = "ci-net"
        body.HostConfig = hostConfig
        resolved = await router.bridgeHost(for: body)
        XCTAssertEqual(resolved, "10.20.0.1")

        // No resolver (MICROPOD_SHIM_BRIDGE pinned): the configured host.
        let pinned = Router(
            config: ShimConfig(bridgeHost: "192.168.99.1", tcpPort: 45455), state: ShimState(),
            events: EventsHub(containers: ContainerService(client: client), interval: 60), client: client,
            sharedFS: nil)
        let pinnedHost = await pinned.bridgeHost(for: body)
        XCTAssertEqual(pinnedHost, "192.168.99.1")
    }

    // MARK: - Gateway listeners follow the host

    /// A gateway is bound only while it is present on an interface, its
    /// listener admits only peers in its network, and it is closed when the
    /// runtime deletes the network. (127.0.0.1 stands in for the vmnet
    /// gateway: it is the only address a test can always bind.)
    func testGatewayListenersFollowInterfacesAndNetworks() async throws {
        let state = GatewayTestState()
        let gateways = VMNetGateways(list: { state.networks })
        let server = ShimHTTPServer(handler: { _, _ in .raw(200, [], Data("OK\n".utf8)) })
        let listeners = GatewayListeners(
            server: server, port: 0, gateways: gateways, interfaces: { state.interfaces }, excluded: [])

        // Known network, interface not up yet (no guest attached): nothing bound.
        state.networks = [Self.network("default", gateway: "127.0.0.1", subnet: "10.9.9.0/24", builtin: true)]
        var bound = await listeners.reconcile(refreshNetworks: true)
        XCTAssertEqual(bound, [])

        // Interface comes up: bound. A peer outside the network is refused.
        state.interfaces = ["127.0.0.1", "192.168.1.197"]
        bound = await listeners.reconcile(refreshNetworks: true)
        XCTAssertEqual(bound, ["127.0.0.1"])
        let port = try XCTUnwrap(server.boundPort)
        let outsider = RawHTTPClient(port: port)
        XCTAssertThrowsError(try outsider.request("GET", "/_ping", timeout: 2), "loopback is not in 10.9.9.0/24")

        // The network's subnet now covers the peer: admitted.
        state.networks = [Self.network("default", gateway: "127.0.0.1", subnet: "127.0.0.0/8", builtin: true)]
        await gateways.refresh()
        XCTAssertEqual(try RawHTTPClient(port: port).request("GET", "/_ping").status, 200)

        // The runtime deletes the network: the listener closes.
        state.networks = []
        bound = await listeners.reconcile(refreshNetworks: true)
        XCTAssertEqual(bound, [])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertThrowsError(try RawHTTPClient(port: port).request("GET", "/_ping", timeout: 2))
    }
}

/// Mutable fakes shared with the listener's @Sendable closures.
private final class GatewayTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var _networks: [Micropod_V1_Network] = []
    private var _interfaces: Set<String> = []

    var networks: [Micropod_V1_Network] {
        get { lock.withLock { _networks } }
        set { lock.withLock { _networks = newValue } }
    }

    var interfaces: Set<String> {
        get { lock.withLock { _interfaces } }
        set { lock.withLock { _interfaces = newValue } }
    }
}
