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

    /// `cache explain` shows what the guest decided beyond attach or skip: the
    /// tier and where it came from, each proxy decision, and a store the
    /// latest start only read (copy-on-write) apart from one it writes.
    func testExplainShowsTrustProxyAndAccess() throws {
        let body = #"""
            {"containerId":"0123456789abcdef0123","containerName":"fork-pr","image":"golang","state":"running",
             "cache":{"scope":"cf-proj","uid":0,"trust":"untrusted","trustFrom":"policy-default",
                      "proxy":{"gomod":"reader-tier","npm":"proxy-unreachable"},
                      "tools":{"gomod":{"mode":"env","path":"/micropod/cache/gomod","layer":"L0","scope":"cf-proj","access":"copy-on-write"},
                               "maven":{"mode":"path","path":"/root/.m2/repository","layer":"L0","scope":"cf-proj"},
                               "pip":{"mode":"skipped","reason":"no-store-to-read"}}}}
            """#
        let info = try JSONDecoder().decode(HVFContainerCacheExplain.self, from: Data(body.utf8))
        XCTAssertEqual(info.cache?.effectiveTrust, "untrusted")
        XCTAssertEqual(info.cache?.tools?["gomod"]?.access, "copy-on-write")
        let text = CacheCommands.explainLines(info).joined(separator: "\n")
        XCTAssertTrue(text.contains("TRUST:     untrusted — only reads the stores"), text)
        XCTAssertTrue(text.contains("(policy-default: no io.micropod.cache.trust label"), text)
        XCTAssertTrue(
            text.contains("PROXY:     gomod  reader-tier — untrusted and read-only containers get none"), text)
        XCTAssertTrue(text.contains("PROXY:     npm    proxy-unreachable — the proxy did not answer"), text)
        let gomod = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("gomod ") })
        XCTAssertTrue(
            gomod.contains(" reads ") && gomod.contains("[copy-on-write: its writes go with the container]"), "\(gomod)"
        )
        let maven = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("maven ") })
        XCTAssertTrue(maven.contains(" attached "), "\(maven)")
        XCTAssertTrue(text.contains("no-store-to-read — an untrusted or read-only container only reads"), text)

        // A guest before the tier sends none of it: trusted, no proxy lines.
        let old =
            #"{"containerId":"ab","containerName":"x","image":"i","state":"exited","cache":{"scope":"default","tools":{}}}"#
        let plain = try JSONDecoder().decode(HVFContainerCacheExplain.self, from: Data(old.utf8))
        let lines = CacheCommands.explainLines(plain)
        XCTAssertTrue(lines.contains { $0.hasPrefix("TRUST:     trusted — writes the stores it uses") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("PROXY:") })
        XCTAssertEqual(
            CacheCommands.skipHint("shared-store-retired").contains("recreate the container"), true)
        // Round trip: the API and MCP encode the same struct.
        let again = try JSONDecoder().decode(
            HVFContainerCacheExplain.self, from: try JSONEncoder().encode(info))
        XCTAssertEqual(again, info)
    }
}
