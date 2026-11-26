import MicropodCore
import MicropodRuntime
import XCTest

@testable import MicropodCLI

/// `micropod machine …` argument handling: routing past the global flags,
/// and sizes and counts that must be usage errors rather than traps.
final class MachineCommandsTests: XCTestCase {
    func testGlobalFlagsAnywhereStillRouteToTheHVFMachine() throws {
        func route(_ argv: [String]) -> [String]? { MachineCommands.route(argv)?.args }
        XCTAssertEqual(route(["machine", "status"]), ["status"])
        XCTAssertEqual(route(["--no-color", "machine", "status"]), ["status"])
        XCTAssertEqual(
            route(["--cli", "/x/container", "machine", "install", "--cpus", "2"]), ["install", "--cpus", "2"])
        XCTAssertEqual(route(["machine", "stop", "--no-color"]), ["stop"], "not Apple's `machine stop <name>`")
        XCTAssertEqual(route(["machine", "logs", "-n", "5", "--no-color"]), ["logs", "-n", "5"])
        XCTAssertEqual(MachineCommands.route(["--json", "machine", "status"])?.json, true)
        XCTAssertEqual(MachineCommands.route(["machine", "status"])?.json, false)
        XCTAssertEqual(route(["machine", "buildkit-endpoint"]), ["buildkit-endpoint"])
        XCTAssertNil(route(["--no-color", "machine", "stop", "web"]), "a named machine is Apple's")
        XCTAssertNil(route(["machines", "logs", "web"]))
        XCTAssertNil(route(["ps", "--no-color"]))
        XCTAssertNil(route(["--cli"]))
        XCTAssertEqual(route(["machine", "cache", "policy", "--mode", "off"]), ["cache", "policy", "--mode", "off"])
        XCTAssertEqual(route(["--json", "machine", "builder", "status"]), ["builder", "status"])
    }

    func testANewDiskDefaultsTo64GiB() throws {
        XCTAssertEqual(MachineCommands.defaultDiskSize, "64g")
        XCTAssertEqual(try MachineCommands.diskBytes(MachineCommands.defaultDiskSize), 64 << 30)
        XCTAssertEqual(HVFInstallRequest().diskBytes, 64 << 30)
        XCTAssertTrue(MachineCommands.helpText.contains("--disk-size 64g"))
    }

    private func policy(_ args: [String], from original: HVFMachineCachePolicy = HVFMachineCachePolicy()) throws
        -> HVFMachineCachePolicy
    {
        let parsed = try parseArgs(
            args, boolFlags: [], valueFlags: MachineCommands.policyValueFlags, commandName: "machine cache policy")
        return try MachineCommands.applyPolicyFlags(parsed, to: original)
    }

    func testCachePolicyFlagsEditThePolicy() throws {
        XCTAssertEqual(try policy([]), HVFMachineCachePolicy(), "no flags, no change")
        XCTAssertEqual(try policy(["--mode", "off"]).mode, .off)
        XCTAssertEqual(try policy(["--mode=AUTO"], from: HVFMachineCachePolicy(mode: .off)).mode, .auto)
        XCTAssertEqual(try policy(["--default-scope", "none"]).defaultScope, "")
        XCTAssertEqual(try policy(["--default-scope", "proj-a"]).defaultScope, "proj-a")
        XCTAssertEqual(
            try policy(["--allow-scopes", "ci-*, main", "--default-scope", "main"]).allowedScopes, ["ci-*", "main"])
        XCTAssertEqual(try policy(["--tools", "go,npm"]).tools, ["gomod", "gobuild", "npm"])
        XCTAssertEqual(
            try policy(["--tools", "all"], from: HVFMachineCachePolicy(tools: ["npm"])).tools,
            HVFMachineCachePolicy.toolKinds)
        let toggled = try policy(["--go-trimpath", "off", "--pnpm-legacy-env", "false", "--register-buildx", "on"])
        XCTAssertFalse(toggled.goTrimpath)
        XCTAssertFalse(toggled.pnpmLegacyEnv)
        XCTAssertTrue(toggled.buildkit.registerBuildx)
        let extra = HVFMachineCachePolicy(extra: ["later": .bool(true)])
        XCTAssertEqual(
            try policy(["--mode", "off"], from: extra).extra, ["later": .bool(true)], "unknown keys survive")

        for (bad, message) in [
            (["--mode", "sometimes"], "--mode wants auto or off"),
            (["--default-scope", "Proj"], "--default-scope 'Proj' must match"),
            (["--allow-scopes", "a*b"], "--allow-scopes entry 'a*b'"),
            (["--allow-scopes", "ci-*"], "default scope 'default' is not in the allowed scopes"),
            (["--tools", "go,bogus-tool"], "unknown tool 'bogus-tool'"),
            (["--go-trimpath", "maybe"], "--go-trimpath wants on or off"),
        ] {
            XCTAssertThrowsError(try policy(bad), "\(bad)") { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
                XCTAssertTrue("\(error)".contains(message), "\(message): \(error)")
                XCTAssertFalse("\(error)".contains("invalidArgument"), "no error-code prefix in a usage line: \(error)")
            }
        }
    }

    func testRunCacheFlagsReachTheRequestAndAreCheckedUpFront() throws {
        let parsed = try parseArgs(
            ["--runtime", "hvf", "--cache", "go", "--cache-scope", "proja", "golang:alpine", "go", "version"],
            boolFlags: [], valueFlags: ["--runtime", "--cache", "--cache-scope"], commandName: "run")
        let request = ContainerCommands.buildRunRequest(parsed, image: "golang:alpine")
        XCTAssertEqual(request.cache, "go")
        XCTAssertEqual(request.cacheScope, "proja")
        XCTAssertEqual(request.arguments, ["go", "version"])
        XCTAssertNoThrow(try ContainerCommands.validateCacheFlags(request))
        for (cache, scope, runtime) in [("maven", nil, "hvf"), (nil, "Bad", "hvf"), ("go", nil, "apple")]
            as [(String?, String?, String)]
        {
            let bad = ContainerRunRequest(image: "x", runtime: runtime, cache: cache, cacheScope: scope)
            XCTAssertThrowsError(try ContainerCommands.validateCacheFlags(bad)) { error in
                XCTAssertTrue(error is UsageError, "\(error)")
            }
        }
        let viaDefault = ContainerRunRequest(image: "x", cache: "go")
        XCTAssertNoThrow(try ContainerCommands.validateCacheFlags(viaDefault, defaultRuntime: "hvf"))
        XCTAssertThrowsError(try ContainerCommands.validateCacheFlags(viaDefault, defaultRuntime: "apple"))
        XCTAssertNoThrow(try ContainerCommands.validateCacheFlags(ContainerRunRequest(image: "x", cache: "off")))
    }

    func testDiskSizeOverflowIsAUsageError() throws {
        XCTAssertEqual(try MachineCommands.diskBytes("32g"), 32 << 30)
        XCTAssertEqual(try MachineCommands.diskBytes("40960M"), 40960 << 20)
        for bad in ["20000000000g", "18446744073709551615m", "0g", "-1g", "12", "g", "1.5g"] {
            XCTAssertThrowsError(try MachineCommands.diskBytes(bad), bad) { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
            }
        }
    }

    func testLogsTailMustBeANonNegativeCount() throws {
        XCTAssertEqual(try MachineCommands.tailLines(try MachineCommands.parseLogs([])), 100)
        XCTAssertEqual(try MachineCommands.tailLines(try MachineCommands.parseLogs(["-n", "0"])), 0)
        XCTAssertEqual(try MachineCommands.tailLines(try MachineCommands.parseLogs(["--tail", "7"])), 7)
        for bad in [["-n", "-1"], ["--tail=-5"], ["-n", "lots"]] {
            XCTAssertThrowsError(try MachineCommands.tailLines(try MachineCommands.parseLogs(bad)), "\(bad)") { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
            }
        }
    }

    func testCacheCommandRoutingAndFleetPolicyFlags() throws {
        XCTAssertEqual(CacheCommands.route(["cache", "status"])?.args, ["status"])
        XCTAssertEqual(
            CacheCommands.route(["--json", "cache", "ls", "--scope", "proj"])?.args, ["ls", "--scope", "proj"])
        XCTAssertEqual(CacheCommands.route(["--json", "cache", "ls"])?.json, true)
        XCTAssertEqual(CacheCommands.route(["cache", "prune", "--dry-run", "--json"])?.json, true)
        XCTAssertNil(CacheCommands.route(["machine", "cache", "policy"]))

        XCTAssertEqual(try CacheCommands.parseDurationSeconds("14d"), 14 * 86400)
        XCTAssertEqual(try CacheCommands.parseDurationSeconds("6h"), 6 * 3600)
        XCTAssertEqual(try CacheCommands.parseDurationSeconds("30m"), 1800)
        XCTAssertEqual(try MachineCommands.parseCacheSizeBytes("20g", flag: "--max-bytes"), 20 << 30)
        XCTAssertEqual(try MachineCommands.parseCacheSizeBytes("512mib", flag: "--max-bytes"), 512 << 20)

        let fleet = try policy([
            "--share-l0", "on",
            "--go-proxy", "http://10.43.0.1:5555/go,direct",
            "--npm-registry", "http://10.43.0.1:5555/npm",
            "--max-bytes", "20g",
            "--min-free-bytes", "4g",
            "--max-age-days", "14",
        ])
        XCTAssertTrue(fleet.sharedL0)
        XCTAssertEqual(fleet.goProxy, "http://10.43.0.1:5555/go,direct")
        XCTAssertEqual(fleet.npmRegistry, "http://10.43.0.1:5555/npm")
        XCTAssertEqual(fleet.maxBytes, 20 << 30)
        XCTAssertEqual(fleet.minFreeBytes, 4 << 30)
        XCTAssertEqual(fleet.maxAgeDays, 14)

        let cleared = try policy(
            [
                "--share-l0", "off", "--go-proxy", "off", "--npm-registry", "none", "--max-bytes", "off",
                "--max-age-days", "off",
            ],
            from: fleet)
        XCTAssertFalse(cleared.sharedL0)
        XCTAssertNil(cleared.goProxy)
        XCTAssertNil(cleared.npmRegistry)
        XCTAssertNil(cleared.maxBytes)
        XCTAssertNil(cleared.maxAgeDays)

        for bad in [
            ["--go-proxy", "ftp://bad"],
            ["--npm-registry", "not-a-url"],
            ["--max-bytes", "0g"],
            ["--max-age-days", "-1"],
        ] {
            XCTAssertThrowsError(try policy(bad), "\(bad)") { error in
                XCTAssertTrue(error is UsageError, "\(bad): \(error)")
            }
        }
    }
}
