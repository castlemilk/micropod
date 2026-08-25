import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim

final class DockerMapperTests: XCTestCase {
    func testStateNameMapping() {
        XCTAssertEqual(DockerMapper.stateName("running"), "running")
        XCTAssertEqual(DockerMapper.stateName("stopped"), "exited")
        XCTAssertEqual(DockerMapper.stateName("exited"), "exited")
        XCTAssertEqual(DockerMapper.stateName("creating"), "created")
        XCTAssertEqual(DockerMapper.stateName("created"), "created")
        XCTAssertEqual(DockerMapper.stateName("unknown-state"), "unknown-state")
        XCTAssertEqual(DockerMapper.stateName(""), "")
    }

    func testSummaryShape() {
        var container = Micropod_V1_Container()
        container.id = "web-1"
        container.image = "alpine:3.20"
        container.state = "running"
        container.labels = ["a": "b"]
        var port = Micropod_V1_PortMapping()
        port.hostPort = 8080
        port.containerPort = 80
        port.`protocol` = "tcp"
        container.publishedPorts = [port]
        let summary = DockerMapper.summary(container, create: nil)

        XCTAssertEqual(summary.Id, "web-1")
        XCTAssertEqual(summary.Image, "alpine:3.20")
        XCTAssertEqual(summary.State, "running")
        XCTAssertEqual(summary.Status.hasPrefix("Up"), true)
        XCTAssertEqual(summary.Names, ["/web-1"])
        XCTAssertEqual(summary.Labels, ["a": "b"])
        XCTAssertEqual(summary.Ports.first?.PublicPort, 8080)
        XCTAssertEqual(summary.Ports.first?.PrivatePort, 80)
        XCTAssertEqual(summary.Ports.first?.Type, "tcp")
    }

    func testExitedStatusText() {
        var container = Micropod_V1_Container()
        container.state = "stopped"
        let summary = DockerMapper.summary(container, create: nil)
        XCTAssertTrue(summary.Status.hasPrefix("Exited"), "got \(summary.Status)")
        XCTAssertEqual(summary.State, "exited")
    }

    func testStoredCreateMergesIntoSummary() {
        var container = Micropod_V1_Container()
        container.id = "x"
        container.state = "running"
        var create = DockerCreateRequest()
        create.Labels = ["stored": "yes"]
        let summary = DockerMapper.summary(container, create: create)
        XCTAssertEqual(summary.Labels["stored"], "yes")
    }

    func testImageIDHashingIsStableAndPrefixed() {
        var image = Micropod_V1_Image()
        image.id = "img-7"
        image.names = ["alpine:3.20"]
        let first = DockerMapper.imageSummary(image)
        let second = DockerMapper.imageSummary(image)
        XCTAssertEqual(first.Id, second.Id, "same input must hash identically")
        XCTAssertTrue(first.Id.hasPrefix("sha256:"))
    }

    func testDockerImageInspectReshape() throws {
        let raw = Data(
            """
            [{"configuration":{"creationDate":"2024-07-15T16:22:51Z","descriptor":{"digest":"sha256:abc","mediaType":"application/vnd.oci.image.index.v1+json","size":100},"name":"docker.io/testcontainers/ryuk:0.8.1"},"id":"bf3f74a4","variants":[{"config":{"architecture":"arm64","config":{"Cmd":["/bin/ryuk"],"Env":["PATH=/x"],"Labels":{"org.testcontainers.ryuk":"true"}},"os":"linux"},"digest":"sha256:def","platform":{"architecture":"arm64","os":"linux"},"size":6525413}]}]
            """.utf8)
        let mapped = try XCTUnwrap(
            DockerMapper.dockerImageInspect(fromRaw: raw, reference: "testcontainers/ryuk:0.8.1"))
        let object = try JSONSerialization.jsonObject(with: mapped) as! [String: Any]
        XCTAssertEqual(object["Id"] as? String, "sha256:bf3f74a4")
        XCTAssertEqual(object["Os"] as? String, "linux")
        XCTAssertEqual(object["Architecture"] as? String, "arm64")
        XCTAssertEqual(object["Size"] as? Int, 6_525_413)
        XCTAssertEqual((object["RepoTags"] as? [String])?.first, "docker.io/testcontainers/ryuk:0.8.1")
        let config = object["Config"] as! [String: Any]
        XCTAssertEqual((config["Cmd"] as? [String])?.first, "/bin/ryuk")
        XCTAssertEqual((config["Labels"] as? [String: String])?["org.testcontainers.ryuk"], "true")
    }

    func testDockerImageInspectRejectsEmptyArray() {
        let empty = Data("[]".utf8)
        XCTAssertNil(DockerMapper.dockerImageInspect(fromRaw: empty, reference: "x"))
        let garbage = Data("not json".utf8)
        XCTAssertNil(DockerMapper.dockerImageInspect(fromRaw: garbage, reference: "x"))
    }
}

extension DockerCreateRequest {
    init(_ image: String = "alpine:3.20") {
        self.init(Image: image)
    }
}
