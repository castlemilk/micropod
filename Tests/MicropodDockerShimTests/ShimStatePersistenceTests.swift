import XCTest

@testable import MicropodDockerShim

final class ShimStatePersistenceTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shim-state-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeCreate(
        image: String = "alpine:3.20", labels: [String: String]? = nil, autoRemove: Bool = false
    ) -> DockerCreateRequest {
        var request = DockerCreateRequest(Image: image)
        request.Labels = labels
        var hostConfig = DockerHostConfig()
        hostConfig.AutoRemove = autoRemove
        request.HostConfig = hostConfig
        return request
    }

    func testRoundTripAcrossRestart() async {
        let original = ShimState()
        await original.enablePersistence(at: url)
        await original.remember(id: "mpc-0001", name: "web", request: makeCreate())
        var removing = makeCreate(autoRemove: true)
        removing.Labels = ["session": "x"]
        await original.remember(id: "mpc-0002", name: nil, request: removing)

        let revived = ShimState.loadPersisted(from: url)
        let restored = await revived.createRequest(for: "mpc-0001")
        XCTAssertEqual(restored?.Image, "alpine:3.20")
        let restoredRemoving = await revived.createRequest(for: "mpc-0002")
        XCTAssertEqual(restoredRemoving?.HostConfig?.AutoRemove, true)
        XCTAssertEqual(restoredRemoving?.Labels?["session"], "x")
        let idForName = await revived.id(forName: "web")
        XCTAssertEqual(idForName, "mpc-0001")
        let autoRemove = await revived.autoRemoveContainerIDs
        XCTAssertEqual(autoRemove, ["mpc-0002"])
    }

    func testForgetPersists() async {
        let state = ShimState()
        await state.enablePersistence(at: url)
        await state.remember(id: "gone", name: "gone", request: makeCreate())
        await state.forget(id: "gone")

        let revived = ShimState.loadPersisted(from: url)
        let restored = await revived.createRequest(for: "gone")
        XCTAssertNil(restored)
        let name = await revived.id(forName: "gone")
        XCTAssertNil(name)
    }

    func testRetainOnlyDropsStaleEntries() async {
        let state = ShimState()
        await state.enablePersistence(at: url)
        await state.remember(id: "kept", name: "kept", request: makeCreate())
        await state.remember(id: "vanished", name: "vanished", request: makeCreate())
        await state.retainOnly(ids: ["kept"])

        let revived = ShimState.loadPersisted(from: url)
        let kept = await revived.createRequest(for: "kept")
        XCTAssertNotNil(kept)
        let vanished = await revived.createRequest(for: "vanished")
        XCTAssertNil(vanished)
        let name = await revived.id(forName: "vanished")
        XCTAssertNil(name)
    }

    func testLoadWithoutFileIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).json")
        let state = ShimState.loadPersisted(from: missing)
        let expectation = expectation(description: "read")
        Task {
            let count = await state.creates.count
            XCTAssertEqual(count, 0)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}
