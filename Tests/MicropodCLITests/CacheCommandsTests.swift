import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodCLI

/// `micropod cache prune` prunes unless `--dry-run` is given. The API's
/// prune route now assumes a dry run when the body is silent, so the
/// command's request always states `dryRun` (HVFMachineClient sends the
/// field whatever its value; CacheRoutesTests checks that on the wire).
final class CacheCommandsTests: XCTestCase {
    func testPruneAppliesUnlessDryRunIsGiven() throws {
        let apply = try CacheCommands.pruneRequest([])
        XCTAssertFalse(apply.dryRun)
        XCTAssertEqual(apply.reason, "cli-prune")
        XCTAssertNil(apply.scope)
        XCTAssertNil(apply.maxBytes)
        XCTAssertTrue(try CacheCommands.pruneRequest(["--dry-run"]).dryRun)
    }

    func testPruneFlagsBecomeTypedSelectors() throws {
        let request = try CacheCommands.pruneRequest([
            "--scope", "proj", "--tool", "go", "--older-than", "14d", "--max-bytes", "20g", "--partial", "off",
        ])
        XCTAssertFalse(request.dryRun)
        XCTAssertEqual(request.scope, "proj")
        XCTAssertEqual(request.tool, "go")
        XCTAssertEqual(request.olderThanSecs, 14 * 86400)
        XCTAssertEqual(request.maxBytes, 20 << 30)
        XCTAssertEqual(request.partialGoBuild, false)
        for bad in [["--partial", "maybe"], ["--max-bytes", "lots"], ["--older-than", "soon"], ["extra"]] {
            XCTAssertThrowsError(try CacheCommands.pruneRequest(bad), "\(bad)") { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
            }
        }
    }
}
