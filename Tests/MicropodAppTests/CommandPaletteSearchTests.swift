import MicropodCore
import XCTest

@testable import MicropodApp

final class CommandPaletteSearchTests: XCTestCase {
    func testContainerImageAndTypeSurviveBothPaletteFilters() {
        var container = Micropod_V1_Container()
        container.id = "db"
        container.image = "docker.io/library/postgres:17-alpine"
        container.state = "running"
        container.labels = ["com.docker.compose.project": "shop"]
        let inventory = WorkloadInventory.items(
            containers: [container], machines: [], containerStats: [:], machineStats: [:], sampledAt: nil)

        for query in ["postgres:17", "Container", "shop postgres:17", "  POSTGRES:17  "] {
            let candidates = inventory.filter { PaletteSearch.matchesWorkload($0.searchTerms, query: query) }
            let results = candidates.map(PaletteItem.forWorkload).filter { $0.matches(query) }
            XCTAssertEqual(results.map(\.title), ["db"], query)
        }
        let paletteItem = PaletteItem.forWorkload(inventory[0])
        XCTAssertFalse(paletteItem.matches("unrelated-image"))
        if case .selectWorkload(.container(let id)) = paletteItem.action {
            XCTAssertEqual(id, "db")
        } else {
            XCTFail("Container match must retain its exact inspector route")
        }
    }

    func testMicroVMKindMatchesWithoutAppearingInItsName() {
        let inventory = WorkloadInventory.items(
            containers: [], machines: [MachineEntry(name: "linux-dev", state: "running")],
            containerStats: [:], machineStats: [:], sampledAt: nil)
        let query = "MicroVM"
        let candidates = inventory.filter { PaletteSearch.matchesWorkload($0.searchTerms, query: query) }
        let results = candidates.map(PaletteItem.forWorkload).filter { $0.matches(query) }
        XCTAssertEqual(results.map(\.title), ["linux-dev"])
        guard let result = results.first else {
            XCTFail("Expected a MicroVM result")
            return
        }
        if case .selectWorkload(.machine(let name)) = result.action {
            XCTAssertEqual(name, "linux-dev")
        } else {
            XCTFail("MicroVM match must retain its exact inspector route")
        }
    }

    func testStaticCommandsKeepTitleAndSubtitleMatching() {
        let run = PaletteItem(icon: "plus.circle", title: "Run Container…", action: .runContainer)
        XCTAssertTrue(run.matches("run container"))
        XCTAssertFalse(run.matches("container run"))
        XCTAssertFalse(run.matches("postgres:17"))
        let navigation = PaletteItem(
            icon: "archivebox", title: "Go to Cache", subtitle: "Local retained data", action: .switchTab(.cache))
        XCTAssertTrue(navigation.matches("cache"))
        XCTAssertTrue(navigation.matches("retained"))
        XCTAssertFalse(navigation.matches("microvm"))
    }
}
