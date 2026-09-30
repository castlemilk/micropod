import Containerization
import ContainerizationError
import Foundation
import MicropodCore
import Virtualization
import XCTest

@testable import MicropodRuntime

/// The SDK surface's host-side logic, no VM: refreshable secrets, process
/// output fan-out, watch parsing, stat parsing, error mapping, and the boot
/// path's lost-VM handling.
final class SandboxSDKTests: XCTestCase {
    // MARK: - Secret values

    func testSecretOutputParsing() throws {
        XCTAssertEqual(try SecretSource.parse(Data("  tok-123\n".utf8)).0, "tok-123")
        let (value, expires) = try SecretSource.parse(
            Data(#"{"version":1,"value":"ghs_x","expires_at":"2030-01-02T03:04:05Z"}"#.utf8))
        XCTAssertEqual(value, "ghs_x")
        XCTAssertEqual(expires, ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z"))
        XCTAssertNil(try SecretSource.parse(Data(#"{"value":"v"}"#.utf8)).1, "expiry is optional")
        for bad in ["", "{", #"{"version":2,"value":"v"}"#, #"{"value":7}"#, #"{"value":"v","expires_at":"soon"}"#] {
            XCTAssertThrowsError(try SecretSource.parse(Data(bad.utf8)), bad)
        }
        XCTAssertThrowsError(try SecretSource.parse(Data(#"{"value":"a\r\nX-Evil: 1"}"#.utf8)), "no header splitting")
        XCTAssertThrowsError(try SandboxSecret(name: "T", value: "a\nb", hosts: ["h"]))
    }

    func testCommandSecretMintsOnceRefreshesAndServesWhileRefreshing() async throws {
        let mint = try MintScript()
        let source = SecretSource(.command(argv: [mint.path], directory: nil, ttl: .seconds(1)), log: { _ in })

        // A cold burst mints once.
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await source.value() } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(values), ["token-1"])
        XCTAssertEqual(mint.runs, 1)

        let cached = try await source.value()
        XCTAssertEqual(cached, "token-1", "cached until the ttl")
        try await Task.sleep(for: .milliseconds(1200))
        let stale = try await source.value()
        XCTAssertEqual(stale, "token-1", "a due value still serves while the refresh runs")
        try await waitUntil { mint.runs == 2 }
        let fresh = try await source.value()
        XCTAssertEqual(fresh, "token-2")
    }

    func testFailedRefreshKeepsAValidValueThenFailsClosed() async throws {
        let mint = try MintScript()
        let source = SecretSource(.command(argv: [mint.path], directory: nil, ttl: .seconds(1)), log: { _ in })
        _ = try await source.value()
        mint.fail = true
        try await Task.sleep(for: .milliseconds(1200))
        let kept = try await source.value()
        XCTAssertEqual(kept, "token-1", "no expiry: the last value keeps serving")
        try await waitUntil { mint.runs == 2 }
        _ = try await source.value()
        XCTAssertEqual(mint.runs, 2, "a failed mint backs off instead of re-running per request")

        let expired = SecretSource(
            .command(
                argv: ["/bin/sh", "-c", #"printf '{"value":"old","expires_at":"2000-01-01T00:00:00Z"}'"#],
                directory: nil, ttl: .seconds(60)), log: { _ in })
        _ = try? await expired.value()
        let broken = SecretSource(.command(argv: ["/usr/bin/false"], directory: nil, ttl: .seconds(60)), log: { _ in })
        do {
            _ = try await broken.value()
            XCTFail("no value to fall back on: the request must fail closed")
        } catch {
            XCTAssertTrue("\(error)".contains("failed"), "\(error)")
        }
    }

    func testSecretSpecsFromTheAPIShape() throws {
        let fixed = try SandboxSecret.from(SandboxSecretSpec(name: "KEY", value: "v", hosts: ["API.example.com"]))
        XCTAssertEqual(fixed.source.kind, .fixed("v"))
        XCTAssertEqual(fixed.hosts, ["api.example.com"])
        let dir = URL(fileURLWithPath: "/tmp/project")
        let command = try SandboxSecret.from(
            SandboxSecretSpec(name: "TOKEN", command: ["./mint"], commandDirectory: "scripts", hosts: ["h"]),
            directory: dir)
        XCTAssertEqual(
            command.source.kind,
            .command(argv: ["./mint"], directory: URL(fileURLWithPath: "/tmp/project/scripts"), ttl: .seconds(300)))
        XCTAssertThrowsError(try SandboxSecret.from(SandboxSecretSpec(name: "X", hosts: ["h"])), "no source")
        XCTAssertThrowsError(
            try SandboxSecret.from(SandboxSecretSpec(name: "X", value: "v", command: ["c"], hosts: ["h"])), "two")
        XCTAssertThrowsError(try SandboxSecret.from(SandboxSecretSpec(name: "1X", value: "v", hosts: ["h"])))
        XCTAssertThrowsError(try SandboxSecret.from(SandboxSecretSpec(name: "X", value: "v", hosts: [])))
        XCTAssertEqual(SandboxSecretSpec.parseTTL("15m"), .seconds(900))
        XCTAssertEqual(SandboxSecretSpec.parseTTL("2h"), .seconds(7200))
        XCTAssertEqual(SandboxSecretSpec.parseTTL("90"), .seconds(90))
        XCTAssertNil(SandboxSecretSpec.parseTTL("0s"))
        XCTAssertNil(SandboxSecretSpec.parseTTL("5d"))
    }

    // MARK: - Process output

    func testProcessOutputReplaysThenStreamsThenEnds() async throws {
        let output = ProcessOutput()
        output.append(.stdout(Data("a".utf8)))
        let early = output.subscribe()
        output.append(.stderr(Data("b".utf8)))
        output.append(.exit(3))
        output.append(.stdout(Data("after exit".utf8)))
        let late = output.subscribe()
        let expected: [ProcessOutput.Event] = [.stdout(Data("a".utf8)), .stderr(Data("b".utf8)), .exit(3)]
        var seenEarly: [ProcessOutput.Event] = []
        for try await event in early { seenEarly.append(event) }
        var seenLate: [ProcessOutput.Event] = []
        for try await event in late { seenLate.append(event) }
        XCTAssertEqual(seenEarly, expected)
        XCTAssertEqual(seenLate, expected, "a stream opened after the exit still gets everything")
    }

    func testProcessOutputFailsAStreamThatFallsTooFarBehind() async throws {
        let output = ProcessOutput()
        let slow = output.subscribe()
        for _ in 0...ProcessOutput.lagLimit { output.append(.stdout(Data("x".utf8))) }
        do {
            for try await _ in slow {}
            XCTFail("a lagging stream must fail, not skip output")
        } catch {
            XCTAssertTrue("\(error)".contains("resourceExhausted"), "\(error)")
        }
    }

    // MARK: - Watch

    func testWatchParserInotify() {
        var parser = WatchParser()
        XCTAssertEqual(
            parser.feed(stderr: Data("Setting up watches.  Beware: …\nWatches established.\n".utf8)),
            [WatchChange(event: "ready", path: "")])
        let changes = parser.feed(
            stdout: Data("CREATE /w/a b.txt\nMODIFY /w/a b.txt\nCREATE,ISDIR /w/d\nATTRIB,ISDIR /w/d\nMOVED_".utf8))
        XCTAssertEqual(
            changes,
            [
                WatchChange(event: "create", path: "/w/a b.txt"), WatchChange(event: "modify", path: "/w/a b.txt"),
                WatchChange(event: "create", path: "/w/d"),
            ])
        XCTAssertEqual(
            parser.feed(stdout: Data("FROM /w/x\nMOVED_TO /w/y\nDELETE /w/y\n".utf8)),
            [
                WatchChange(event: "rename", path: "/w/x"), WatchChange(event: "rename", path: "/w/y"),
                WatchChange(event: "delete", path: "/w/y"),
            ], "a line split across chunks is joined")
        _ = parser.feed(stderr: Data("Couldn't watch /w/x: No such file or directory\n".utf8))
        XCTAssertTrue(parser.errors.contains("No such file"))
    }

    func testWatchParserPolling() {
        var parser = WatchParser()
        let dir = "41ed"  // 040755
        let file = "81a4"  // 0100644
        XCTAssertEqual(
            parser.feed(stdout: Data("@poll\n1 4096 10 \(dir) /w\n1 3 11 \(file) /w/a\n@snap\n".utf8)),
            [WatchChange(event: "ready", path: "")])
        XCTAssertEqual(
            parser.feed(
                stdout: Data("2 4096 10 \(dir) /w\n2 5 11 \(file) /w/a\n2 1 12 \(file) /w/new file\n@snap\n".utf8)),
            [WatchChange(event: "modify", path: "/w/a"), WatchChange(event: "create", path: "/w/new file")],
            "a directory's own mtime change isn't reported")
        XCTAssertEqual(
            parser.feed(stdout: Data("3 4096 10 \(dir) /w\n2 1 12 \(file) /w/new file\n@snap\n".utf8)),
            [WatchChange(event: "delete", path: "/w/a")])
    }

    // MARK: - Files

    func testStatParsingAndTypes() {
        let stats = SandboxFileStat.parse("12 81a4 1700000000 ./a file\n0 41ed 1700000001 dir\n9 a1ff 1 link\nbogus\n")
        XCTAssertEqual(stats.map(\.path), ["./a file", "dir", "link"])
        XCTAssertEqual(stats.map(\.type), ["file", "dir", "symlink"])
        XCTAssertEqual(stats[0].size, 12)
        XCTAssertEqual(stats[0].mode & 0o777, 0o644)
        XCTAssertEqual(stats[1].mtime, 1_700_000_001)
    }

    func testFileErrorsMapToActionableCodes() {
        func code(_ stderr: String) -> String {
            ConnectCodeMapping.code(for: SandboxEngine.fileError("/p", stderr))
        }
        XCTAssertEqual(code("cat: can't open '/p': No such file or directory"), "not_found")
        XCTAssertEqual(code("rm: cannot remove '/p': Permission denied"), "permission_denied")
        XCTAssertEqual(code("mkdir: can't create directory '/p': File exists"), "already_exists")
        XCTAssertEqual(code("rmdir: '/p': Directory not empty"), "failed_precondition")
        XCTAssertEqual(code("/p: Is a directory"), "failed_precondition")
        XCTAssertEqual(code("/p: 40000000 bytes, over the 32 MiB limit"), "resource_exhausted")
        XCTAssertEqual(code("sh: stat: not found"), "failed_precondition", "a missing tool, not a missing file")
    }

    // MARK: - Boot resilience

    func testLostVMErrorsAreRetriedRequestErrorsAreNot() {
        XCTAssertTrue(SandboxVM.isLostVM(NSError(domain: VZErrorDomain, code: VZError.Code.internalError.rawValue)))
        XCTAssertFalse(
            SandboxVM.isLostVM(
                NSError(domain: VZErrorDomain, code: VZError.Code.invalidVirtualMachineConfiguration.rawValue)))
        XCTAssertTrue(SandboxVM.isLostVM(ContainerizationError(.timeout, message: "no agent")))
        XCTAssertTrue(
            SandboxVM.isLostVM(
                ContainerizationError(
                    .internalError, message: "x",
                    cause: NSError(domain: VZErrorDomain, code: VZError.Code.internalError.rawValue))))
        XCTAssertFalse(SandboxVM.isLostVM(ContainerizationError(.invalidArgument, message: "bad mount")))
        XCTAssertFalse(SandboxVM.isLostVM(MicropodError.message("invalidArgument: bad spec")))
        XCTAssertTrue(SandboxVM.isLostVM(SandboxVM.BootTimeout(message: "guest did not boot", limit: .seconds(1))))
    }

    func testTimeoutReturnsWithoutWaitingForAStuckBody() async throws {
        let abandoned = expectation(description: "abandoned body finished later")
        let started = ContinuousClock.now
        do {
            // The body ignores cancellation, like a Virtualization callback
            // that never fires.
            try await SandboxVM.withTimeout(
                .milliseconds(100), "stuck", abandoned: { abandoned.fulfill() },
                {
                    let until = ContinuousClock.now + .milliseconds(600)
                    while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(20)) }
                })
            XCTFail("expected a timeout")
        } catch is SandboxVM.BootTimeout {}
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(400))
        await fulfillment(of: [abandoned], timeout: 5)

        try await SandboxVM.withTimeout(.seconds(5), "fast") {}
        struct Boom: Error {}
        do {
            try await SandboxVM.withTimeout(.seconds(5), "err") { throw Boom() }
            XCTFail("expected the body's error")
        } catch is Boom {}
    }

    // MARK: - Engine options

    func testSandboxOptionsMapOntoTheVM() throws {
        var request = ContainerRunRequest(
            image: "alpine", dns: ["9.9.9.9"], runtime: "sandbox",
            sandbox: SandboxRunOptions(
                exposeHost: [5432], allowHosts: ["api.example.com"],
                secrets: [SandboxSecretSpec(name: "KEY", value: "v", hosts: ["api.example.com"])],
                dnsResolvers: ["1.1.1.1"], diskSizeMiB: 4096, fromCheckpoint: "base"))
        var options = try SandboxEngine.options(from: request)
        XCTAssertEqual(options.exposeHost, [5432])
        XCTAssertEqual(options.egress.allowHosts, ["api.example.com"])
        XCTAssertEqual(options.egress.secrets.map(\.name), ["KEY"])
        XCTAssertEqual(options.dnsResolvers, ["9.9.9.9", "1.1.1.1"])
        XCTAssertEqual(options.diskBytes, 4096 << 20)
        guard case .checkpoint("base") = options.base else { return XCTFail("\(options.base)") }
        XCTAssertEqual(options.networkMode, .VMNET_HOST_MODE, "an allowlist leaves only the proxy route")

        request.sandbox?.network = false
        request.sandbox?.allowHosts = []
        request.sandbox?.secrets = []
        request.sandbox?.dnsResolvers = []
        request.dns = []
        options = try SandboxEngine.options(from: request)
        XCTAssertEqual(options.networkMode, .VMNET_HOST_MODE, "expose_host alone gets a host-only network")

        request.sandbox?.allowHosts = ["x"]
        XCTAssertThrowsError(try SandboxEngine.options(from: request), "an allowlist needs a network")
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition never held") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A mint command: prints token-N (N counts runs), or fails when `fail` is set.
private final class MintScript: @unchecked Sendable {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mint-\(UUID().uuidString)")
    var path: String { dir.appendingPathComponent("mint.sh").path }

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "0".write(to: dir.appendingPathComponent("count"), atomically: true, encoding: .utf8)
        let script = """
            #!/bin/sh
            cd "$(dirname "$0")"
            n=$(( $(cat count) + 1 )); echo $n > count
            [ -e fail ] && { echo "mint failed" >&2; exit 1; }
            printf '{"version":1,"value":"token-%s"}' "$n"
            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var runs: Int {
        Int(
            (try? String(contentsOf: dir.appendingPathComponent("count"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    var fail: Bool {
        get { FileManager.default.fileExists(atPath: dir.appendingPathComponent("fail").path) }
        set {
            let url = dir.appendingPathComponent("fail")
            if newValue {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
