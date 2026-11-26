import Foundation
import MicropodCore
import XCTest

@testable import MicropodRuntime

/// `micropod run|create --cache … --cache-scope …` as labels: the hvf
/// guest engine reads `io.micropod.cache` and `io.micropod.cache.scope`;
/// other runtimes get the shim's off switch or a refusal.
final class HVFCacheLabelTests: XCTestCase {
    private func request(cache: String? = nil, scope: String? = nil, labels: [String: String] = [:])
        -> ContainerRunRequest
    {
        ContainerRunRequest(
            image: "golang:alpine",
            labels: labels.sorted { $0.key < $1.key }.map { LabelSpec(key: $0.key, value: $0.value) },
            cache: cache, cacheScope: scope)
    }

    private func labels(_ request: ContainerRunRequest) -> [String: String] {
        Dictionary(request.labels.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    func testFlagsBecomeTheGuestLabels() throws {
        for (flag, label) in [
            ("auto", "auto"), ("off", "off"), ("OFF", "off"), ("go", "go"), ("go, npm", "go,npm"),
            ("+cargo,-npm", "+cargo,-npm"), (" gomod,,gobuild ", "gomod,gobuild"),
            ("pnpm,yarn,yarnberry,pip,uv,corepack", "pnpm,yarn,yarnberry,pip,uv,corepack"),
        ] {
            let mapped = try ContainerCacheOptions.applying(to: request(cache: flag), runtime: "hvf")
            XCTAssertEqual(labels(mapped), ["io.micropod.cache": label], flag)
            XCTAssertNil(mapped.cache, "consumed: the engine never sees the flag twice")
        }
        let scoped = try ContainerCacheOptions.applying(to: request(scope: "proj-a_1"), runtime: "hvf")
        XCTAssertEqual(labels(scoped), ["io.micropod.cache.scope": "proj-a_1"])
        XCTAssertNil(scoped.cacheScope)
        let both = try ContainerCacheOptions.applying(to: request(cache: "go", scope: "projb"), runtime: "hvf")
        XCTAssertEqual(labels(both), ["io.micropod.cache": "go", "io.micropod.cache.scope": "projb"])
    }

    func testNoFlagsAddNothing() throws {
        let plain = request(labels: ["app": "x"])
        XCTAssertEqual(
            try ContainerCacheOptions.applying(to: plain, runtime: "hvf"), plain, "default-on is the guest's")
        XCTAssertEqual(try ContainerCacheOptions.applying(to: plain, runtime: "apple"), plain)
    }

    func testAUserLabelWinsOverTheFlag() throws {
        for key in ["io.micropod.cache", "com.micropod.cache"] {
            let mapped = try ContainerCacheOptions.applying(
                to: request(cache: "off", labels: [key: "go"]), runtime: "hvf")
            XCTAssertEqual(labels(mapped), [key: "go"], "\(key) is kept and no second cache label is added")
        }
        for key in ["io.micropod.cache.scope", "com.micropod.cache.scope"] {
            let mapped = try ContainerCacheOptions.applying(
                to: request(cache: "go", scope: "flag", labels: [key: "label"]), runtime: "hvf")
            XCTAssertEqual(labels(mapped), [key: "label", "io.micropod.cache": "go"])
        }
    }

    func testInvalidValuesAreRefused() {
        let bad: [(String?, String?, String)] = [
            ("", nil, "--cache wants auto, off or a comma list"),
            (",", nil, "--cache wants auto, off or a comma list"),
            // maven is a guest cache kind since 977b2e8a; gems is not one.
            ("gems", nil, "unknown tool 'gems'"),
            ("go,+gems", nil, "unknown tool 'gems'"),
            ("auto,go", nil, "--cache auto cannot be combined"),
            ("-off", nil, "--cache off cannot be combined"),
            ("++go", nil, "unknown tool '+go'"),
            (nil, "", "--cache-scope '' must match"),
            (nil, "ProjA", "--cache-scope 'ProjA' must match"),
            (nil, "-a", "must match"),
            (nil, "a/b", "must match"),
            (nil, String(repeating: "a", count: 64), "must match"),
        ]
        for (cache, scope, message) in bad {
            XCTAssertThrowsError(
                try ContainerCacheOptions.applying(to: request(cache: cache, scope: scope), runtime: "hvf"), message
            ) { error in
                XCTAssertTrue(error is ContainerCacheOptions.Invalid, "\(error)")
                XCTAssertTrue("\(error)".contains(message), "\(message): \(error)")
            }
        }
        XCTAssertTrue(ContainerCacheOptions.isValidScope(String(repeating: "a", count: 63)))
        XCTAssertEqual(
            ContainerCacheOptions.tools, ["go"] + HVFMachineCachePolicy.toolKinds,
            "the run flags and the machine policy accept the same tools")
    }

    func testOtherRuntimesGetTheShimSwitchOrARefusal() throws {
        for runtime in ["apple", "docker", "sandbox"] {
            let off = try ContainerCacheOptions.applying(to: request(cache: "off"), runtime: runtime)
            XCTAssertEqual(labels(off), ["com.micropod.cache.shared": "false"], runtime)
            let auto = try ContainerCacheOptions.applying(to: request(cache: "auto"), runtime: runtime)
            XCTAssertEqual(labels(auto), [:], "auto is every runtime's default")
            XCTAssertNil(auto.cache)
            for refused in [request(cache: "go"), request(scope: "proja"), request(cache: "off", scope: "proja")] {
                XCTAssertThrowsError(try ContainerCacheOptions.applying(to: refused, runtime: runtime)) {
                    XCTAssertTrue("\($0)".contains("runtime '\(runtime)' has no per-tool dependency caches"), "\($0)")
                }
            }
        }
        let kept = try ContainerCacheOptions.applying(
            to: request(cache: "off", labels: ["com.micropod.cache.shared": "true"]), runtime: "apple")
        XCTAssertEqual(labels(kept), ["com.micropod.cache.shared": "true"], "an explicit label still wins")
    }

    func testTheHVFEngineMapsTheFlagsWhenItAdmitsARequest() throws {
        let admitted = try HVFEngine.admit(request(cache: "+cargo", scope: "proja"))
        XCTAssertEqual(labels(admitted), ["io.micropod.cache": "+cargo", "io.micropod.cache.scope": "proja"])
        XCTAssertNil(admitted.cache)
        XCTAssertNil(admitted.cacheScope)
        XCTAssertThrowsError(try HVFEngine.admit(request(scope: "Bad"))) {
            XCTAssertEqual(ConnectCodeMapping.code(for: $0), "invalid_argument", "\($0)")
        }
        XCTAssertThrowsError(try ContainerCacheOptions.admitted(request(cache: "go"), runtime: "apple")) {
            XCTAssertEqual(ConnectCodeMapping.code(for: $0), "invalid_argument")
        }
    }

    func testTheRouterMapsForEveryEngineButHVF() throws {
        let hvf = HVFEngine(root: URL(fileURLWithPath: "/tmp/mphvf-l-none"), environment: [:])
        let untouched = try RuntimeRouter.cacheLabels(request(cache: "go"), for: hvf)
        XCTAssertEqual(untouched.cache, "go", "hvf maps it itself, in admit")
        XCTAssertEqual(untouched.labels, [])
        let sandbox = SandboxEngine(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("sbx-\(UUID())"))
        let mapped = try RuntimeRouter.cacheLabels(request(cache: "off"), for: sandbox)
        XCTAssertEqual(labels(mapped), ["com.micropod.cache.shared": "false"])
        XCTAssertThrowsError(try RuntimeRouter.cacheLabels(request(cache: "go"), for: sandbox))
    }
}
