import Foundation
import XCTest

@testable import MicropodCore

final class K8sServiceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k8s-\(UUID().uuidString)")
        setenv("MICROPOD_K8S_CONFIG", tmpDir.appendingPathComponent("k8s.json").path, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        unsetenv("MICROPOD_K8S_CONFIG")
    }

    private func service() -> K8sService {
        K8sService(client: ContainerCLIClient())
    }

    // MARK: - enablement

    func testDisabledByDefault() throws {
        XCTAssertNil(service().loadConfig())
        unsetenv("MICROPOD_K8S")
        XCTAssertFalse(service().isEnabled)
    }

    func testEnableWritesConfig() throws {
        try service().saveConfig(.defaults)
        XCTAssertTrue(service().isEnabled)
        let loaded = try XCTUnwrap(service().loadConfig())
        XCTAssertEqual(loaded, .defaults)
    }

    func testEnvVarForceEnables() throws {
        setenv("MICROPOD_K8S", "1", 1)
        defer { unsetenv("MICROPOD_K8S") }
        XCTAssertTrue(service().isEnabled)
    }

    // MARK: - run argv

    func testRunArgsCarryThePrivilegesK3sNeeds() {
        let args = K8sService.runArgs(.defaults)
        XCTAssertTrue(args.contains("--cap-add"))
        XCTAssertTrue(args.contains("ALL"))
        XCTAssertTrue(args.contains("--read-only-path"))
        XCTAssertTrue(args.contains("--masked-path"))
        XCTAssertTrue(args.contains("NONE"))
        XCTAssertTrue(args.contains("server"))
        XCTAssertTrue(args.contains("--disable=servicelb"))
        XCTAssertFalse(args.contains("--disable=traefik"))
    }

    func testRunArgsDisableIngressWhenUnset() {
        var config = K8sConfig.defaults
        config.ingress = false
        XCTAssertTrue(K8sService.runArgs(config).contains("--disable=traefik"))
    }

    func testRunArgsShape() {
        var config = K8sConfig.defaults
        config.clusterName = "test-k3s"
        config.memory = "2G"
        config.cpus = 4
        let args = K8sService.runArgs(config)
        XCTAssertEqual(args.first, "run")
        XCTAssertTrue(args.contains("--detach") || args.contains("-d"))
        let nameIdx = args.firstIndex(of: "--name")
        XCTAssertNotNil(nameIdx)
        XCTAssertEqual(args[nameIdx! + 1], "test-k3s")
        // image is the last positional before `server`
        let imgIdx = args.firstIndex(of: "server")! - 1
        XCTAssertEqual(args[imgIdx], "docker.io/rancher/k3s:v1.34.1-k3s1")
    }

    // MARK: - kubeconfig rewrite

    func testKubeconfigRewritePointsAtVMAddress() {
        let raw = "clusters:\n- cluster:\n    server: https://127.0.0.1:6443\n"
        XCTAssertEqual(
            K8sService.rewriteKubeconfig(raw, address: "192.168.64.8"),
            "clusters:\n- cluster:\n    server: https://192.168.64.8:6443\n")
    }

    // MARK: - MetalLB pool derivation

    func testDefaultPoolIsSubnetTail() {
        XCTAssertEqual(
            K8sService.defaultLBPool(ipv4CIDR: "192.168.64.8/24"),
            "192.168.64.240-192.168.64.250")
        XCTAssertEqual(
            K8sService.defaultLBPool(ipv4CIDR: "10.211.55.3/24"),
            "10.211.55.240-10.211.55.250")
        XCTAssertNil(K8sService.defaultLBPool(ipv4CIDR: "not-an-ip"))
    }

    func testPoolManifestEmbedsRange() {
        let yaml = K8sService.poolManifest("192.168.64.240-192.168.64.250")
        XCTAssertTrue(yaml.contains("kind: IPAddressPool"))
        XCTAssertTrue(yaml.contains("kind: L2Advertisement"))
        XCTAssertTrue(yaml.contains("192.168.64.240-192.168.64.250"))
        XCTAssertTrue(yaml.contains("metallb-system"))
    }

    // MARK: - Image ref normalization (kubelet resolves to docker.io/…)

    func testQualifiedRefNormalizesLikeDocker() {
        XCTAssertEqual(K8sService.qualifiedRef("redis"), "docker.io/library/redis:latest")
        XCTAssertEqual(K8sService.qualifiedRef("redis:alpine"), "docker.io/library/redis:alpine")
        XCTAssertEqual(K8sService.qualifiedRef("org/img:1"), "docker.io/org/img:1")
        XCTAssertEqual(
            K8sService.qualifiedRef("quay.io/metallb/controller:v0.14.9"),
            "quay.io/metallb/controller:v0.14.9")
        XCTAssertEqual(K8sService.qualifiedRef("localhost:5000/img"), "localhost:5000/img:latest")
        XCTAssertEqual(K8sService.qualifiedRef("ghcr.io/x/y"), "ghcr.io/x/y:latest")
    }
}
