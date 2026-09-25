import XCTest

@testable import MicropodDockerShim

/// Docker↔Apple container-name translation: Docker accepts long/odd names
/// the Apple runtime rejects (>63 bytes, leading `_`). Valid names pass
/// through byte-identical; anything else gets a deterministic sanitized
/// runtime name (content-hash suffix ⇒ stable across shim restarts).
final class ContainerNameTests: XCTestCase {
    func testValidNamesPassThrough() {
        for name in ["web", "reaper_x", "foo.bar", "9foo", "UPPER", "a-b_c.d9", String(repeating: "a", count: 63)] {
            let mapping = DockerNaming.runtimeName(for: name)
            XCTAssertEqual(mapping.name, name, "\(name) must not be rewritten")
            XCTAssertFalse(mapping.aliased)
            XCTAssertTrue(DockerNaming.isRuntimeValid(name))
        }
    }

    func testLongNamesAreAliasedDeterministically() {
        let long = "reaper_" + String(repeating: "a", count: 64)
        XCTAssertEqual(long.count, 71)
        let first = DockerNaming.runtimeName(for: long)
        let second = DockerNaming.runtimeName(for: long)
        XCTAssertTrue(first.aliased)
        XCTAssertEqual(first.name, second.name, "must be stable across restarts")
        XCTAssertLessThanOrEqual(first.name.count, 63)
        XCTAssertTrue(DockerNaming.isRuntimeValid(first.name))
        XCTAssertTrue(first.name.hasPrefix("reaper_"), "keeps a readable prefix, got \(first.name)")
    }

    func testDistinctLongNamesDoNotCollide() {
        let a = DockerNaming.runtimeName(for: "reaper_" + String(repeating: "a", count: 64)).name
        let b = DockerNaming.runtimeName(for: "reaper_" + String(repeating: "b", count: 64)).name
        XCTAssertNotEqual(a, b)
    }

    func testLeadingUnderscoreAndBadChars() {
        let leading = DockerNaming.runtimeName(for: "_foo")
        XCTAssertTrue(leading.aliased)
        XCTAssertTrue(DockerNaming.isRuntimeValid(leading.name))

        let bad = DockerNaming.runtimeName(for: "a:b/c d")
        XCTAssertTrue(bad.aliased)
        XCTAssertTrue(DockerNaming.isRuntimeValid(bad.name))
        XCTAssertFalse(bad.name.contains(":"))
        XCTAssertFalse(bad.name.contains("/"))
        XCTAssertFalse(bad.name.contains(" "))
    }

    func testIsRuntimeValidBoundaries() {
        XCTAssertFalse(DockerNaming.isRuntimeValid(""))
        XCTAssertFalse(DockerNaming.isRuntimeValid(String(repeating: "a", count: 64)))
        XCTAssertTrue(DockerNaming.isRuntimeValid(String(repeating: "a", count: 63)))
        XCTAssertFalse(DockerNaming.isRuntimeValid("_foo"))
    }

    /// The runtime's id grammar is ASCII — `container` 1.3.1 answers
    /// `container ID café is not a valid container ID` — and so is the
    /// clone-path grammar (`VolumeClone.isSafeComponent`) this check
    /// shares: a name Docker accepts but the runtime does not is aliased,
    /// never passed through to a hard failure.
    func testNonASCIINamesAreAliased() {
        for name in ["café", "日本", "naïve-1"] {
            XCTAssertFalse(DockerNaming.isRuntimeValid(name), name)
            let mapping = DockerNaming.runtimeName(for: name)
            XCTAssertTrue(mapping.aliased, name)
            XCTAssertTrue(DockerNaming.isRuntimeValid(mapping.name), mapping.name)
            XCTAssertTrue(mapping.name.allSatisfy(\.isASCII), mapping.name)
            XCTAssertEqual(mapping.name, DockerNaming.runtimeName(for: name).name, "must be stable across restarts")
        }
        XCTAssertEqual(DockerNaming.runtimeName(for: "café").name, "caf-")
    }
}
