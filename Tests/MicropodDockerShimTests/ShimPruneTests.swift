import Foundation
import XCTest

@testable import MicropodCore
@testable import MicropodDockerShim

/// `POST /containers/prune` and `POST /volumes/prune` honour Docker's
/// `filters` (live defect 3: they were dropped, so a cuttlefish agent's
/// `docker volume prune -f --filter label!=cuttle.kind` deleted every unused
/// volume), reject filters they cannot read without deleting anything, and
/// never take a volume a clone refers to.
final class ShimPruneTests: XCTestCase {
    private var shim: ShimTestSupport.MockShim!

    override func setUp() async throws {
        shim = try ShimTestSupport.makeMockShim()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shim.stateDir)
    }

    // MARK: - Helpers

    private func query(_ filters: [String: [String: Bool]]) -> String {
        let json = String(decoding: try! JSONEncoder().encode(filters), as: UTF8.self)
        return "filters=" + json.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }

    private func createVolume(_ name: String, labels: [String: String] = [:]) throws {
        let response = try shim.raw().request(
            "POST", "/volumes/create", body: ShimTestSupport.jsonBody(["Name": name, "Labels": labels]),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self))
    }

    private func volumeNames() throws -> Set<String> {
        let body =
            try JSONSerialization.jsonObject(with: shim.raw().request("GET", "/volumes").body)
            as! [String: Any]
        return Set((body["Volumes"] as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String })
    }

    private func pruneVolumes(_ query: String = "") throws -> (status: Int, deleted: Set<String>) {
        let response = try shim.raw().request("POST", "/volumes/prune" + (query.isEmpty ? "" : "?\(query)"))
        let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return (response.status, Set(body?["VolumesDeleted"] as? [String] ?? []))
    }

    @discardableResult
    private func createContainer(
        _ name: String, labels: [String: String] = [:], binds: [String] = [], run: Bool = true
    ) throws -> String {
        let body: [String: Any] = [
            "Image": "alpine:3.20", "Cmd": ["true"], "Labels": labels, "HostConfig": ["Binds": binds],
        ]
        let response = try shim.raw().request(
            "POST", "/containers/create?name=\(name)", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self))
        let id = (try JSONSerialization.jsonObject(with: response.body) as! [String: Any])["Id"] as! String
        if run {
            // A stopped attempt container: it ran, then stopped.
            XCTAssertEqual(try shim.raw().request("POST", "/containers/\(id)/start").status, 204)
            XCTAssertEqual(try shim.raw().request("POST", "/containers/\(id)/stop").status, 204)
        }
        return id
    }

    private func pruneContainers(_ query: String = "") throws -> (status: Int, deleted: Set<String>) {
        let response = try shim.raw().request("POST", "/containers/prune" + (query.isEmpty ? "" : "?\(query)"))
        let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return (response.status, Set(body?["ContainersDeleted"] as? [String] ?? []))
    }

    // MARK: - Volume prune

    /// The agent's disk-manager prune: every `cuttle.kind` volume survives,
    /// whatever its value; unlabelled and otherwise-labelled ones go.
    func testVolumePruneLabelNotKeepsEveryVolumeCarryingTheKey() throws {
        try createVolume("cf-cache-golden", labels: ["cuttle.kind": "cache"])
        try createVolume("cf-ws-connect", labels: ["cuttle.kind": "workspace"])
        try createVolume("scratch")
        try createVolume("team-x", labels: ["team": "x"])

        let pruned = try pruneVolumes(query(["label!": ["cuttle.kind": true]]))
        XCTAssertEqual(pruned.status, 200)
        XCTAssertEqual(pruned.deleted, ["scratch", "team-x"])
        XCTAssertEqual(try volumeNames(), ["cf-cache-golden", "cf-ws-connect"])
    }

    func testVolumePruneLabelNotWithAValueKeepsOnlyThatValue() throws {
        try createVolume("golden", labels: ["cuttle.kind": "cache"])
        try createVolume("workspace", labels: ["cuttle.kind": "workspace"])

        let pruned = try pruneVolumes(query(["label!": ["cuttle.kind=cache": true]]))
        XCTAssertEqual(pruned.deleted, ["workspace"])
        XCTAssertEqual(try volumeNames(), ["golden"])
    }

    func testVolumePruneLabelKeyValueTakesOnlyMatchingVolumes() throws {
        try createVolume("ab", labels: ["a": "b"])
        try createVolume("ac", labels: ["a": "c"])
        try createVolume("plain")

        let pruned = try pruneVolumes(query(["label": ["a=b": true]]))
        XCTAssertEqual(pruned.deleted, ["ab"])
        XCTAssertEqual(try volumeNames(), ["ac", "plain"])
    }

    /// The legacy list form dockerd still accepts.
    func testVolumePruneReadsTheLegacyFilterForm() throws {
        try createVolume("kept", labels: ["cuttle.kind": "cache"])
        try createVolume("gone")
        let legacy = #"{"label!":["cuttle.kind"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(try pruneVolumes("filters=\(legacy)").deleted, ["gone"])
    }

    func testVolumePruneKeepsVolumesInUse() throws {
        try createVolume("attached")
        try createVolume("idle")
        try createContainer("user", binds: ["attached:/data"], run: false)

        XCTAssertEqual(try pruneVolumes().deleted, ["idle"])
        XCTAssertTrue(try volumeNames().contains("attached"))
    }

    /// Goldens: a volume a container clones (`com.micropod.cache.clone`),
    /// the source a `CloneVolume` copy names (`com.micropod.clone-of`), one
    /// with a per-container clone image on disk and one the volume policy
    /// names are never pruned — none of them is attached by name, so an
    /// unused-volume prune would take them.
    func testVolumePruneNeverTakesAVolumeACloneRefersTo() throws {
        XCTAssertEqual(VolumeClone.cloneRoot.path, shim.cloneRoot.path)
        let placed = shim.cloneRoot.appendingPathComponent("cf-attempt-1", isDirectory: true)
        try FileManager.default.createDirectory(at: placed, withIntermediateDirectories: true)
        try Data().write(to: placed.appendingPathComponent("golden-on-disk.img"))
        try JSONEncoder().encode(VolumePolicy(cloneMode: .goldens, goldenVolumes: ["golden-by-policy"]))
            .write(to: shim.volumePolicyFile)

        try createVolume("golden-labelled")
        try createVolume("golden-source")
        try createVolume("seeded", labels: [VolumeClone.cloneOfLabel: "golden-source"])
        try createVolume("golden-on-disk")
        try createVolume("golden-by-policy")
        try createVolume("scratch")
        try createContainer(
            "cloner", labels: ["com.micropod.cache.clone": "golden-labelled"],
            binds: ["golden-labelled:/cache"])

        let pruned = try pruneVolumes()
        XCTAssertEqual(pruned.deleted, ["seeded", "scratch"])
        XCTAssertEqual(
            try volumeNames(), ["golden-labelled", "golden-source", "golden-on-disk", "golden-by-policy"])
    }

    func testMalformedVolumeFiltersAre400AndDeleteNothing() throws {
        try createVolume("a")
        try createVolume("b", labels: ["cuttle.kind": "cache"])
        for filters in [
            "not-json", #"{"label!":"cuttle.kind"}"#, #"["label!"]"#, #"{"label!":{"cuttle.kind":"yes"}}"#,
            #"{"until":{"24h":true}}"#, #"{"dangling":{"maybe":true}}"#,
        ] {
            let encoded = filters.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            XCTAssertEqual(try pruneVolumes("filters=\(encoded)").status, 400, filters)
        }
        XCTAssertEqual(try volumeNames(), ["a", "b"])
    }

    // MARK: - Container prune

    func testContainerPruneHonoursLabelFilters() throws {
        let mine = try createContainer("mine", labels: ["owner": "me"])
        let theirs = try createContainer("theirs", labels: ["owner": "them"])
        let plain = try createContainer("plain")
        let running = try createContainer("running-mine", labels: ["owner": "me"], run: false)
        XCTAssertEqual(try shim.raw().request("POST", "/containers/\(running)/start").status, 204)

        XCTAssertEqual(try pruneContainers(query(["label": ["owner=me": true]])).deleted, [mine])
        XCTAssertEqual(try pruneContainers(query(["label!": ["owner": true]])).deleted, [plain])
        // Still there: another owner's stopped container, and the running one.
        XCTAssertEqual(try shim.raw().request("GET", "/containers/\(theirs)/json").status, 200)
        XCTAssertEqual(try shim.raw().request("GET", "/containers/\(running)/json").status, 200)
    }

    func testContainerPruneUntilKeepsNewerContainers() throws {
        let id = try createContainer("recent")
        XCTAssertEqual(try pruneContainers(query(["until": ["2000-01-01T00:00:00Z": true]])).deleted, [])
        XCTAssertEqual(try pruneContainers(query(["until": ["0s": true]])).deleted, [id])
    }

    /// A container created and not yet started is a create whose start is
    /// on its way (live defect 4): the prune leaves it for the grace period.
    func testContainerPruneKeepsAFreshNeverStartedContainer() throws {
        let fresh = try createContainer("fresh", run: false)
        let ran = try createContainer("ran")
        XCTAssertEqual(try pruneContainers().deleted, [ran])
        XCTAssertEqual(try shim.raw().request("GET", "/containers/\(fresh)/json").status, 200)
    }

    func testMalformedContainerFiltersAre400AndDeleteNothing() throws {
        let id = try createContainer("kept")
        for filters in [
            "{", #"{"label":"owner=me"}"#, #"{"dangling":{"true":true}}"#, #"{"until":{"yesterday-ish":true}}"#,
            #"{"until":{"1h":true,"2h":true}}"#,
        ] {
            let encoded = filters.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            XCTAssertEqual(try pruneContainers("filters=\(encoded)").status, 400, filters)
        }
        XCTAssertEqual(try shim.raw().request("GET", "/containers/\(id)/json").status, 200)
    }

    // MARK: - System prune

    func testSystemPruneKeepsGoldensAndHonoursFilters() throws {
        try createVolume("golden-source")
        try createVolume("seeded", labels: [VolumeClone.cloneOfLabel: "golden-source"])
        try createVolume("kept", labels: ["cuttle.kind": "cache"])
        try createVolume("scratch")

        let bad = try shim.raw().request("POST", "/system/prune?filters=nope")
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(try volumeNames(), ["golden-source", "seeded", "kept", "scratch"])

        let response = try shim.raw().request("POST", "/system/prune?" + query(["label!": ["cuttle.kind": true]]))
        XCTAssertEqual(response.status, 200)
        let body = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        XCTAssertEqual(Set(body["VolumesDeleted"] as? [String] ?? []), ["seeded", "scratch"])
        XCTAssertEqual(try volumeNames(), ["golden-source", "kept"])
    }

    // MARK: - Filter semantics

    func testLabelSemanticsMatchDockerd() throws {
        let labelled = ["cuttle.kind": "cache", "a": "b"]
        func filters(_ json: String) throws -> PruneFilters {
            try PruneFilters(json: json, accepted: PruneFilters.volumeKeys)
        }
        XCTAssertTrue(try filters(#"{"label":{"a":true}}"#).admits(labels: labelled))
        XCTAssertTrue(try filters(#"{"label":{"a=b":true,"cuttle.kind":true}}"#).admits(labels: labelled))
        XCTAssertFalse(try filters(#"{"label":{"a=c":true}}"#).admits(labels: labelled))
        XCTAssertFalse(try filters(#"{"label":{"a":true}}"#).admits(labels: [:]))
        XCTAssertFalse(try filters(#"{"label!":{"cuttle.kind":true}}"#).admits(labels: labelled))
        XCTAssertTrue(try filters(#"{"label!":{"cuttle.kind":true}}"#).admits(labels: ["a": "b"]))
        XCTAssertTrue(try filters(#"{"label!":{"cuttle.kind":true}}"#).admits(labels: [:]))
        // `label!` keeps only what carries every one of its values.
        XCTAssertTrue(try filters(#"{"label!":{"cuttle.kind":true,"z":true}}"#).admits(labels: labelled))
        XCTAssertTrue(try filters(#"{"all":{"true":true}}"#).admits(labels: [:]))
        XCTAssertEqual(try filters(#"{"dangling":{"false":true}}"#).dangling, false)
    }

    func testUntilReadsDockerTimeValues() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func until(_ value: String) throws -> Date? {
            try PruneFilters(
                json: #"{"until":{"\#(value)":true}}"#, accepted: PruneFilters.containerKeys, now: now
            ).until
        }
        XCTAssertEqual(try until("24h"), now.addingTimeInterval(-86_400))
        XCTAssertEqual(try until("1h30m"), now.addingTimeInterval(-5_400))
        XCTAssertEqual(try until("1790000000"), now)
        XCTAssertEqual(try until("1789999999.5"), now.addingTimeInterval(-0.5))
        XCTAssertEqual(try until("2026-09-21T08:53:20Z"), Date(timeIntervalSince1970: 1_789_980_800))
        XCTAssertEqual(try until("2026-09-21T18:53:20+10:00"), Date(timeIntervalSince1970: 1_789_980_800))
        XCTAssertNotNil(try until("2026-09-21"))
        XCTAssertNotNil(try until("2026-09-21T08:53"))
        XCTAssertThrowsError(try until("soon"))
        XCTAssertThrowsError(try until("2026-13-45"))
        XCTAssertThrowsError(try until("10x"))
    }
}
