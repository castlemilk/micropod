import XCTest

@testable import MicropodCore

final class VolumeMountMatchTests: XCTestCase {
    private func volume(id: String, source: String) -> Micropod_V1_Volume {
        var v = Micropod_V1_Volume()
        v.id = id
        v.source = source
        return v
    }

    private func container(id: String, mounts: [(String, String)]) -> Micropod_V1_Container {
        var c = Micropod_V1_Container()
        c.id = id
        for (source, destination) in mounts {
            var m = Micropod_V1_Mount()
            m.source = source
            m.destination = destination
            m.type = "volume"
            c.mounts.append(m)
        }
        return c
    }

    func testMatchesBySourcePath() {
        let volume = volume(id: "pgdata", source: "/mock/volumes/pgdata")
        let container = container(id: "db", mounts: [("/mock/volumes/pgdata", "/var/lib/postgresql/data")])
        XCTAssertEqual(containersMounted(to: volume, in: [container]).map(\.id), ["db"])
    }

    func testMatchesByVolumeIdInSource() {
        let volume = volume(id: "pgdata", source: "/mock/volumes/pgdata")
        let container = container(id: "db", mounts: [("/data/pgdata", "/var/lib/postgresql/data")])
        XCTAssertEqual(containersMounted(to: volume, in: [container]).map(\.id), ["db"])
    }

    func testIgnoresUnrelatedContainers() {
        let volume = volume(id: "pgdata", source: "/mock/volumes/pgdata")
        let container = container(id: "web", mounts: [("/elsewhere", "/app")])
        XCTAssertTrue(containersMounted(to: volume, in: [container]).isEmpty)
    }

    func testEmptySourceMatchesNothing() {
        let volume = volume(id: "anon", source: "")
        let container = container(id: "x", mounts: [("/mock/volumes/anon", "/data")])
        XCTAssertTrue(containersMounted(to: volume, in: [container]).isEmpty)
    }

    func testMultipleMountedContainers() {
        let volume = volume(id: "shared", source: "/mock/volumes/shared")
        let a = container(id: "a", mounts: [("/mock/volumes/shared", "/a")])
        let b = container(id: "b", mounts: [("/mock/volumes/shared", "/b")])
        let c = container(id: "c", mounts: [("/other", "/c")])
        XCTAssertEqual(Set(containersMounted(to: volume, in: [a, b, c]).map(\.id)), ["a", "b"])
    }
}
