import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim

/// Read-through cache semantics: hits within TTL, expiry, explicit
/// invalidation on mutation, and the disabled kill-switch. Correctness of
/// write-through against the real flow is covered by the lifecycle server
/// tests (which run with the cache enabled).
final class ReadThroughCacheTests: XCTestCase {
    private func container(_ id: String, state: String = "running") -> Micropod_V1_Container {
        var c = Micropod_V1_Container()
        c.id = id
        c.state = state
        c.image = "alpine:3.20"
        return c
    }

    func testMissThenHit() async {
        let cache = ReadThroughCache(ttl: 60, disabled: false)
        let miss = await cache.cachedList()
        XCTAssertNil(miss)
        let list = [container("a"), container("b")]
        await cache.storeList(list)
        let hit = await cache.cachedList()
        XCTAssertEqual(hit?.map(\.id), ["a", "b"])
        let stats = await cache.stats()
        XCTAssertEqual(stats.misses, 1)
        XCTAssertEqual(stats.hits, 1)
    }

    func testExpiry() async throws {
        let cache = ReadThroughCache(ttl: 0.05, disabled: false)
        await cache.storeList([container("a")])
        let warm = await cache.cachedList()
        XCTAssertNotNil(warm)
        try await Task.sleep(for: .seconds(0.15))
        let cold = await cache.cachedList()
        XCTAssertNil(cold, "entry must expire past TTL")
    }

    func testInvalidateContainersDropsListAndInspects() async {
        let cache = ReadThroughCache(ttl: 60, disabled: false)
        await cache.storeList([container("a")])
        let listed = await cache.cachedList()
        XCTAssertNotNil(listed)
        let inspected = await cache.cachedInspect(id: "a")
        XCTAssertNotNil(inspected)
        await cache.invalidateContainers()
        let listedAfter = await cache.cachedList()
        XCTAssertNil(listedAfter)
        let inspectedAfter = await cache.cachedInspect(id: "a")
        XCTAssertNil(inspectedAfter)
    }

    func testInspectRoundtrip() async {
        let cache = ReadThroughCache(ttl: 60, disabled: false)
        let miss = await cache.cachedInspect(id: "zzz")
        XCTAssertNil(miss)
        await cache.storeInspect(container("zzz", state: "exited"))
        let hit = await cache.cachedInspect(id: "zzz")
        XCTAssertEqual(hit?.state, "exited")
    }

    func testImagesRoundtripAndInvalidate() async {
        let cache = ReadThroughCache(ttl: 60, disabled: false)
        let miss = await cache.cachedImages()
        XCTAssertNil(miss)
        var image = Micropod_V1_Image()
        image.id = "img-1"
        await cache.storeImages([image])
        let hit = await cache.cachedImages()
        XCTAssertEqual(hit?.map(\.id), ["img-1"])
        await cache.invalidateImages()
        let gone = await cache.cachedImages()
        XCTAssertNil(gone)
    }

    func testDisabledIsNoOp() async {
        let cache = ReadThroughCache(ttl: 60, disabled: true)
        let disabled = await cache.isDisabled
        XCTAssertTrue(disabled)
        await cache.storeList([container("a")])
        let listed = await cache.cachedList()
        XCTAssertNil(listed)
        await cache.storeInspect(container("a"))
        let inspected = await cache.cachedInspect(id: "a")
        XCTAssertNil(inspected)
        var image = Micropod_V1_Image()
        image.id = "img-1"
        await cache.storeImages([image])
        let images = await cache.cachedImages()
        XCTAssertNil(images)
        // No-ops must not touch counters either.
        let stats = await cache.stats()
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.misses, 0)
    }

    func testResolvePrefersExactOverPrefix() throws {
        let ab = container("abcdef")
        let abx = container("abcdef12")
        // Exact id wins even when another id shares the prefix.
        XCTAssertEqual(try Router.resolve("abcdef", in: [ab, abx]).id, "abcdef")
        // Unique prefix resolves; ambiguous prefix conflicts.
        XCTAssertEqual(try Router.resolve("abcdef1", in: [ab, abx]).id, "abcdef12")
        XCTAssertThrowsError(try Router.resolve("abc", in: [ab, abx]))
        XCTAssertThrowsError(try Router.resolve("nope", in: [ab, abx]))
    }

    func testBodyFastPathRoundtrip() async {
        let cache = ReadThroughCache(ttl: 60, disabled: false)
        let miss = await cache.cachedBody("containers:true")
        XCTAssertNil(miss)
        let payload = Data("{\"a\":1}".utf8)
        await cache.storeBody(payload, for: "containers:true")
        let hit = await cache.cachedBody("containers:true")
        XCTAssertEqual(hit, payload)
        // Namespace-scoped invalidation: containers drop container bodies,
        // images drop image bodies, never each other's.
        await cache.storeBody(payload, for: "images")
        await cache.invalidateContainers()
        let containersGone = await cache.cachedBody("containers:true")
        XCTAssertNil(containersGone)
        let imagesKept = await cache.cachedBody("images")
        XCTAssertEqual(imagesKept, payload)
        await cache.invalidateImages()
        let imagesGone = await cache.cachedBody("images")
        XCTAssertNil(imagesGone)
    }

    func testBodyDisabledIsNoOp() async {
        let cache = ReadThroughCache(ttl: 60, disabled: true)
        await cache.storeBody(Data("x".utf8), for: "containers:true")
        let hit = await cache.cachedBody("containers:true")
        XCTAssertNil(hit)
    }
}
