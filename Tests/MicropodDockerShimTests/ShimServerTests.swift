import XCTest

@testable import MicropodDockerShim

/// Drives the full shim Router in-process against the mock CLI, over real
/// TCP connections.
final class ShimServerTests: XCTestCase {
    private var shim: ShimTestSupport.MockShim!

    override func setUp() async throws {
        shim = try ShimTestSupport.makeMockShim()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shim.stateDir)
    }

    // MARK: Basics

    func testPingAndVersionAndInfo() throws {
        let client = shim.raw()
        XCTAssertEqual(try client.request("GET", "/_ping").body, Data("OK\n".utf8))
        XCTAssertEqual(try client.request("GET", "/_ping").headers["content-type"], "text/plain")

        let version =
            try JSONSerialization.jsonObject(with: client.request("GET", "/version").body)
            as! [String: Any]
        XCTAssertEqual(version["Version"] as? String, "27.3.1")
        XCTAssertEqual(version["ApiVersion"] as? String, "1.44")
        XCTAssertEqual((version["Platform"] as? [String: Any])?["Name"] as? String, "Apple Container Runtime")

        let info =
            try JSONSerialization.jsonObject(with: client.request("GET", "/info").body)
            as! [String: Any]
        XCTAssertEqual(info["OSType"] as? String, "linux")
        XCTAssertEqual(info["ServerVersion"] as? String, "27.3.1")
    }

    func testVersionedPathsRoute() throws {
        let client = shim.raw()
        XCTAssertEqual(
            try client.request("GET", "/v1.24/_ping").status, 200)
        XCTAssertEqual(
            try client.request("GET", "/v1.44/version").status, 200)
        XCTAssertEqual(try client.request("POST", "/build/prune").status, 200)
    }

    // MARK: Lifecycle

    @discardableResult
    private func createContainer(
        _ name: String, image: String = "alpine:3.20", labels: [String: String] = [:],
        cmd: [String] = ["sleep", "60"], autoRemove: Bool = false,
        restartPolicy: [String: Any]? = nil, healthcheck: [String: Any]? = nil
    ) throws -> String {
        var body: [String: Any] = ["Image": image, "Cmd": cmd]
        if !labels.isEmpty { body["Labels"] = labels }
        if let healthcheck { body["Healthcheck"] = healthcheck }
        var hostConfig: [String: Any] = ["AutoRemove": autoRemove]
        if let restartPolicy { hostConfig["RestartPolicy"] = restartPolicy }
        body["HostConfig"] = hostConfig
        let response = try shim.raw().request(
            "POST", "/containers/create?name=\(name)", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 201, "create \(name): \(response.body)")
        let parsed = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        return parsed["Id"] as! String
    }

    func testFullLifecycle() throws {
        let id = try createContainer("life-1")

        var client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)

        // Inspect shows running + stored config merged in.
        let inspect =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/\(id)/json").body) as! [String: Any]
        let state = inspect["State"] as! [String: Any]
        XCTAssertEqual(state["Status"] as? String, "running")
        XCTAssertEqual(state["Running"] as? Bool, true)

        // Wait for exit (mock stop → exited).
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/stop").status, 204)
        let wait =
            try JSONSerialization.jsonObject(
                with: client.request("POST", "/containers/\(id)/wait?condition=not-running").body)
            as! [String: Any]
        XCTAssertEqual(wait["StatusCode"] as? Int, 0)

        // List reflects exited state; all=1 required.
        let runningOnly =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/json").body) as! [[String: Any]]
        XCTAssertFalse(runningOnly.contains { $0["Id"] as? String == id })
        let all =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/json?all=1").body) as! [[String: Any]]
        XCTAssertTrue(all.contains { $0["Id"] as? String == id })

        XCTAssertEqual(
            try client.request("DELETE", "/containers/\(id)?force=true").status, 204)
        let afterDelete = try client.request("GET", "/containers/\(id)/json")
        XCTAssertEqual(afterDelete.status, 404)
    }

    func testAutoRemoveDeletesOnStop() throws {
        let id = try createContainer("auto-rm", autoRemove: true)
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/stop").status, 204)
        // Poll until EventsHub observes the die and issues the delete — the
        // full suite's mock-CLI lock contention stretches poll intervals.
        let deadline = Date().addingTimeInterval(15)
        var gone = false
        while Date() < deadline {
            let list =
                try JSONSerialization.jsonObject(
                    with: client.request("GET", "/containers/json?all=1").body) as! [[String: Any]]
            if !list.contains(where: { $0["Id"] as? String == id }) {
                gone = true
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(gone, "AutoRemove must delete the stopped container")
    }

    func testNameConflictReturns409() throws {
        _ = try createContainer("dupe")
        var body: [String: Any] = ["Image": "alpine:3.20"]
        body["HostConfig"] = ["AutoRemove": false]
        let response = try shim.raw().request(
            "POST", "/containers/create?name=dupe", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 409)
    }

    // MARK: Filters

    func testLabelFiltersOverHTTP() throws {
        _ = try createContainer("matchy", labels: ["org.testcontainers.session-id": "sess-7"])
        _ = try createContainer("plain")
        let client = shim.raw()
        let filters = "{\"labels\":[\"org.testcontainers.session-id=sess-7\"]}"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let matched =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/json?all=1&filters=\(filters)").body)
            as! [[String: Any]]
        XCTAssertEqual(matched.count, 1, "expected exactly the labeled container, got \(matched)")

        // Unknown filter keys are rejected (dockerd parity).
        let bad = try client.request(
            "GET", "/containers/json?all=1&filters=%7B%22nonsense%22%3A%5B%22x%22%5D%7D")
        XCTAssertEqual(bad.status, 400)
    }

    // MARK: Logs

    func testLogsAreStdcopyFramed() throws {
        let id = try createContainer("loggy", cmd: ["echo", "boot"])
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        let logs = try client.request("GET", "/containers/\(id)/logs?stdout=1&tail=10")
        XCTAssertEqual(logs.status, 200)
        XCTAssertTrue(
            logs.headers["content-type"]?.contains("application/vnd.docker.multiplexed-stream") ?? false)
        guard let frame = decodeFrame(logs.body) else {
            return XCTFail("logs not framed: \(logs.body.prefix(32))")
        }
        XCTAssertEqual(frame.type, 1)
        XCTAssertTrue(String(decoding: frame.payload, as: UTF8.self).contains("mock log line"))
    }

    // MARK: Exec hijack

    func testExecHijackFramedOutputThenClose() throws {
        let id = try createContainer("execy")
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)

        let execResponse = try client.request(
            "POST", "/containers/\(id)/exec",
            body: ShimTestSupport.jsonBody(["Cmd": ["echo", "hijacked"], "AttachStdout": true]),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(execResponse.status, 201)
        let execID =
            (try JSONSerialization.jsonObject(with: execResponse.body) as! [String: Any])["Id"]
            as! String

        // Raw upgrade request — read head, then the framed payload.
        client.close()
        try client.connectForHijack()
        try client.writeRaw(
            Data("POST /exec/\(execID)/start HTTP/1.1\r\nHost: d\r\nContent-Length: 2\r\n\r\n{}".utf8))
        let terminator = Data("\r\n\r\n".utf8)
        let data = try client.readUntil(timeout: 15) { raw in
            guard let headEnd = raw.range(of: terminator) else { return false }
            return decodeFrame(Data(raw[headEnd.upperBound...])) != nil
        }
        guard let headEnd = data.range(of: terminator) else {
            return XCTFail("no 101 head received: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        XCTAssertTrue(head.contains("101"), "expected 101 upgrade, got: \(head)")
        guard let frame = decodeFrame(Data(data[headEnd.upperBound...])) else {
            return XCTFail("no stdcopy frame after upgrade: \(data.count) bytes")
        }
        XCTAssertEqual(frame.type, 1)
        // The mock CLI answers exec with "ok".
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "ok\n")
    }

    func testExecInspectReportsExitCode() throws {
        let id = try createContainer("inspecty")
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        let execResponse = try client.request(
            "POST", "/containers/\(id)/exec",
            body: ShimTestSupport.jsonBody(["Cmd": ["true"]]),
            headers: [("Content-Type", "application/json")])
        let execID =
            (try JSONSerialization.jsonObject(with: execResponse.body) as! [String: Any])["Id"]
            as! String
        _ = try client.request("POST", "/exec/\(execID)/start", body: Data("{}".utf8)).body
        let inspected =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/exec/\(execID)/json").body) as! [String: Any]
        XCTAssertEqual(inspected["ExitCode"] as? Int, 0)
        XCTAssertEqual(inspected["Running"] as? Bool, false)
    }

    // MARK: Events

    func testEventsStreamDeliversCreateEvent() throws {
        let eventsClient = shim.raw()
        let filters = "{\"labels\":[\"events-test=1\"]}"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let raw =
            "GET /events?filters=\(filters) HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n"
        try eventsClient.writeRaw(Data(raw.utf8))

        // Wait for the 200 head — the subscription baseline is settled then
        // (real clients also gate on the status line before proceeding).
        _ = try eventsClient.readUntil(timeout: 15) {
            String(decoding: $0, as: UTF8.self).contains("200")
        }
        // Give the hub a moment to settle before creating (avoids a tight
        // race where the snapshot list straddles the create under load).
        Thread.sleep(forTimeInterval: 0.4)
        _ = try createContainer("evented", labels: ["events-test": "1"])

        let data = try eventsClient.readUntil(timeout: 15) {
            String(decoding: $0, as: UTF8.self).contains("\"create\"")
        }
        XCTAssertTrue(
            String(decoding: data, as: UTF8.self).contains("\"create\""),
            "no create event within window: \(String(decoding: data.prefix(300), as: UTF8.self))")
        eventsClient.close()
    }

    // MARK: Ryuk interception through the API surface

    func testRyukCreateIsIntercepted() throws {
        var body: [String: Any] = [
            "Image": "testcontainers/ryuk:0.14.0",
            "Env": ["DOCKER_HOST=unix:///var/run/docker.sock"],
        ]
        body["HostConfig"] = [
            "AutoRemove": false,
            "Binds": ["/var/run/docker.sock:/var/run/docker.sock"],
            "PortBindings": ["8080/tcp": [[:]]],
        ]
        let response = try shim.raw().request(
            "POST", "/containers/create?name=reaper", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 201)
        let reaperID =
            (try JSONSerialization.jsonObject(with: response.body) as! [String: Any])["Id"]
            as! String

        let inspect =
            try JSONSerialization.jsonObject(
                with: shim.raw().request("GET", "/containers/\(reaperID)/json").body) as! [String: Any]
        let config = inspect["Config"] as! [String: Any]
        let env = config["Env"] as! [String]
        XCTAssertTrue(env.contains("DOCKER_HOST=tcp://192.168.64.1:45455"), "env was \(env)")
        let hostConfig = inspect["HostConfig"] as! [String: Any]
        let binds = hostConfig["Binds"] as! [String]
        XCTAssertFalse(binds.contains("/var/run/docker.sock:/var/run/docker.sock"), "binds were \(binds)")
    }

    func testDinDCreateIsRedirected() throws {
        // Cuttlefish-runner style DinD: any image mounting the socket gets
        // the strip + TCP redirect (Ryuk-only 8080 publish must NOT apply).
        var body: [String: Any] = [
            "Image": "myrunner:latest",
            "Env": ["FOO=bar"],
        ]
        body["HostConfig"] = [
            "AutoRemove": false,
            "Binds": ["/var/run/docker.sock:/var/run/docker.sock"],
        ]
        let response = try shim.raw().request(
            "POST", "/containers/create?name=dind", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(response.status, 201, String(decoding: response.body.prefix(200), as: UTF8.self))
        let dindID =
            (try JSONSerialization.jsonObject(with: response.body) as! [String: Any])["Id"]
            as! String

        let inspect =
            try JSONSerialization.jsonObject(
                with: shim.raw().request("GET", "/containers/\(dindID)/json").body) as! [String: Any]
        let config = inspect["Config"] as! [String: Any]
        let env = config["Env"] as! [String]
        XCTAssertTrue(env.contains("DOCKER_HOST=tcp://192.168.64.1:45455"), "env was \(env)")
        XCTAssertTrue(env.contains("FOO=bar"), "pre-existing env must survive")
        let hostConfig = inspect["HostConfig"] as! [String: Any]
        let binds = hostConfig["Binds"] as! [String]
        XCTAssertFalse(binds.contains("/var/run/docker.sock:/var/run/docker.sock"), "binds were \(binds)")
    }

    // MARK: Build context cache

    func testBuildTwiceReusesCachedContext() async throws {
        let tar = TarBuilder.archive(
            TarBuilder.file(name: "Dockerfile", content: Data("FROM alpine:3.20\n".utf8)),
            TarBuilder.file(name: "app.txt", content: Data("v1".utf8)))
        let client = shim.raw()
        for _ in 0..<2 {
            let response = try client.request(
                "POST", "/build?t=bctx:test1", body: tar,
                headers: [("Content-Type", "application/x-tar")])
            let preview = String(decoding: response.body.prefix(300), as: UTF8.self)
            XCTAssertEqual(response.status, 200, preview)
            XCTAssertTrue(response.body.contains("naming to".data(using: .utf8)!), preview)
        }
        let stats = await shim.buildCache.stats()
        XCTAssertEqual(stats.entries, 1, "identical contexts must share one cache entry")
        XCTAssertEqual(try client.request("GET", "/images/bctx:test1/json").status, 200)
    }

    // MARK: Runtime compat shims

    func testNetworkUppercaseLabelsAreNormalized() throws {
        // The real runtime rejects uppercase network label keys; the shim
        // lowercases them (the mock enforces the same rule, so 201 proves
        // normalization happened before the CLI call).
        let body: [String: Any] = [
            "Name": "lblnet",
            "Labels": ["org.testcontainers.sessionId": "abc", "plain": "x"],
        ]
        let response = try shim.raw().request(
            "POST", "/networks/create", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(
            response.status, 201, String(decoding: response.body.prefix(200), as: UTF8.self))
    }

    func testMissingImageIsDockerShaped404() throws {
        let response = try shim.raw().request("GET", "/images/definitely-missing:9.9/json")
        XCTAssertEqual(response.status, 404)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("No such image"), text)
    }

    func testLongContainerNameIsAliased() throws {        // testcontainers-style 71-char name: Docker accepts it, the Apple
        // runtime does not — the shim aliases and resolves transparently.
        let long = "reaper_" + String(repeating: "a", count: 64)
        XCTAssertEqual(long.count, 71)
        let body: [String: Any] = ["Image": "alpine:3.20", "Cmd": ["sleep", "60"]]
        let response = try shim.raw().request(
            "POST", "/containers/create?name=\(long)", body: ShimTestSupport.jsonBody(body),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(
            response.status, 201, String(decoding: response.body.prefix(200), as: UTF8.self))
        let parsed = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let id = parsed["Id"] as! String
        XCTAssertNotEqual(id, long, "runtime id must be the sanitized alias")
        XCTAssertLessThanOrEqual(id.count, 63)
        // Every later lookup by Docker name resolves through the alias.
        XCTAssertEqual(try shim.raw().request("GET", "/containers/\(long)/json").status, 200)
        XCTAssertEqual(
            try shim.raw().request("DELETE", "/containers/\(long)?force=true").status, 204)
    }

    func testRenameStoppedContainerAliases() throws {
        // Rename never deletes (a stopped temp replacement is
        // indistinguishable from debris): the runtime container survives
        // under the new name, and removing the abandoned request name is
        // idempotent via the tombstone (compose's cleanup rm).
        _ = try createContainer("rename-me")
        let client = shim.raw()
        XCTAssertEqual(
            try client.request("POST", "/containers/rename-me/rename?name=rename-me-old").status,
            204)
        // Abandoned request name: tombstoned removal succeeds, container lives.
        XCTAssertEqual(
            try client.request("DELETE", "/containers/rename-me?force=true").status, 204)
        // New name resolves to the intact container.
        let inspect =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/rename-me-old/json").body)
            as! [String: Any]
        let liveID = inspect["Id"] as? String
        XCTAssertNotNil(liveID)
        // And the underlying runtime container still lists (rename moves
        // names, not containers).
        let list =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/json?all=1").body) as! [[String: Any]]
        XCTAssertTrue(list.contains { ($0["Id"] as? String) == liveID })
    }

    func testRenameRunningContainerAliases() throws {        let id = try createContainer("rename-live")
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        XCTAssertEqual(
            try client.request("POST", "/containers/rename-live/rename?name=rename-live-v2").status,
            204)
        // Live workloads are never killed by a rename: the runtime container
        // is intact and reachable under the new name.
        let inspect =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/containers/rename-live-v2/json").body)
            as! [String: Any]
        let state = inspect["State"] as! [String: Any]
        XCTAssertEqual(state["Status"] as? String, "running")
    }
    func testRenameMissingContainerIs404() throws {
        XCTAssertEqual(
            try shim.raw().request("POST", "/containers/no-such-xyz/rename?name=n2").status,
            404)
    }

    func testLogsFollowTerminatesWhenContainerDead() throws {
        // Apple `logs -f` never terminates on its own (proven live); the
        // shim's death watch must finish follow streams ~2s after death.
        // The hanging mock (MICROPOD_MOCK_FOLLOW_HANG) emulates that CLI.
        let hanging = try ShimTestSupport.makeMockShim(extraEnv: ["MICROPOD_MOCK_FOLLOW_HANG": "1"])
        defer { try? FileManager.default.removeItem(at: hanging.stateDir) }
        let created = try hanging.raw().request(
            "POST", "/containers/create?name=follow-dead",
            body: ShimTestSupport.jsonBody(["Image": "alpine:3.20", "Cmd": ["sleep", "60"]]),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(created.status, 201)
        let start = Date()
        let response = try hanging.raw().request("GET", "/containers/follow-dead/logs?follow=1&tail=5")
        let wall = Date().timeIntervalSince(start)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(
            String(decoding: response.body, as: UTF8.self).contains("mock log line 1"),
            "buffered output must still flush")
        XCTAssertLessThan(
            wall, 12,
            "follow ended after \(wall)s; without the death watch it hangs until client timeout (15s)")
    }

    func testHealthcheckReportedAsStarting() throws {
        // Deterministic (no timing): a fresh healthchecked container reports
        // State.Health starting before any probe runs.
        let id = try createContainer(
            "health-new", healthcheck: ["Test": ["CMD-SHELL", "true"], "Interval": 1_000_000_000])
        let inspect =
            try JSONSerialization.jsonObject(
                with: shim.raw().request("GET", "/containers/\(id)/json").body) as! [String: Any]
        let health = (inspect["State"] as! [String: Any])["Health"] as! [String: Any]
        XCTAssertEqual(health["Status"] as? String, "starting")
        XCTAssertEqual(health["FailingStreak"] as? Int, 0)
    }

    func testHealthcheckTurnsHealthy() throws {
        // Mock exec exits 0 ("ok"), so probes succeed and the container must
        // report healthy well within the deadline (EventsHub ticks at 0.1s).
        let id = try createContainer(
            "health-warm", healthcheck: ["Test": ["CMD", "true"], "Interval": 100_000_000])
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        let deadline = Date().addingTimeInterval(15)
        var status = ""
        while Date() < deadline {
            let inspect =
                try JSONSerialization.jsonObject(
                    with: client.request("GET", "/containers/\(id)/json").body) as! [String: Any]
            status = ((inspect["State"] as! [String: Any])["Health"] as? [String: Any])?["Status"]
                as? String ?? ""
            if status == "healthy" { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(status, "healthy", "mock exec always succeeds; probes must land")
    }

    func testNoHealthcheckMeansNoHealthKey() throws {
        let id = try createContainer("health-none")
        let inspect =
            try JSONSerialization.jsonObject(
                with: shim.raw().request("GET", "/containers/\(id)/json").body) as! [String: Any]
        let state = inspect["State"] as! [String: Any]
        XCTAssertTrue(
            state["Health"] == nil || state["Health"] is NSNull,
            "unconfigured containers must not report health, got \(state["Health"] as Any)")
    }

    // MARK: Protocol robustness

    func testImageInspectHandlesSlashedReferences() throws {
        let client = shim.raw()
        // Pull (mock registers the image), then inspect by repo-with-slash ref.
        let pull = try client.request("POST", "/images/create?fromImage=testcontainers/ryuk:0.8.1")
        XCTAssertEqual(pull.status, 200)
        let inspect = try client.request("GET", "/images/testcontainers/ryuk:0.8.1/json")
        XCTAssertEqual(inspect.status, 200, String(decoding: inspect.body.prefix(120), as: UTF8.self))
        // Must be a Docker-shaped dict, not the runtime's raw array.
        let object = try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any]
        XCTAssertNotNil(object)
        XCTAssertEqual(object?["Os"] as? String, "linux")
        XCTAssertNotNil(object?["Config"] as? [String: Any])
    }

    func testForceDeleteAcceptsCapitalizedTrue() throws {
        let id = try createContainer("force-me")
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        // docker-py sends force=True (capitalized).
        XCTAssertEqual(try client.request("DELETE", "/containers/\(id)?force=True").status, 204)
        XCTAssertEqual(try client.request("GET", "/containers/\(id)/json").status, 404)
    }

    func testKeepAliveReusesConnection() throws {
        let client = shim.raw()
        client.close()
        try client.connectForHijack()
        // No Connection header: server defaults to keep-alive.
        try client.writeRaw(Data("GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        let first = try client.readUntil(timeout: 10) {
            String(decoding: $0, as: UTF8.self).contains("OK")
        }
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("200"))

        // Second request on the same connection must still work.
        try client.writeRaw(Data("GET /version HTTP/1.1\r\nHost: d\r\n\r\n".utf8))
        let second = try client.readUntil(timeout: 10) {
            String(decoding: $0, as: UTF8.self).contains("27.3.1")
        }
        XCTAssertTrue(
            String(decoding: second, as: UTF8.self).contains("27.3.1"),
            "keep-alive second request failed: \(String(decoding: second.prefix(200), as: UTF8.self))")

        // Explicit close is honored.
        try client.writeRaw(
            Data("GET /_ping HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n".utf8))
        let final = try client.readUntilClose(timeout: 10)
        XCTAssertTrue(String(decoding: final, as: UTF8.self).contains("200"))
        client.close()
    }

    func testPipelinedRequestsRespondInOrder() throws {
        let client = shim.raw()
        client.close()
        try client.connectForHijack()
        let ping = "GET /_ping HTTP/1.1\r\nHost: d\r\n\r\n"
        let version = "GET /version HTTP/1.1\r\nHost: d\r\nConnection: close\r\n\r\n"
        try client.writeRaw(Data((ping + ping + version).utf8))

        let all = try client.readUntilClose(timeout: 15)
        let text = String(decoding: all, as: UTF8.self)
        XCTAssertEqual(
            text.components(separatedBy: "HTTP/1.1 200 OK").count - 1, 3,
            "expected three responses: \(text.prefix(400))")
        let firstPingBody = text.range(of: "\r\nOK\n")
            .map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        let versionAt = text.range(of: "27.3.1")
            .map { text.distance(from: text.startIndex, to: $0.lowerBound) }
        XCTAssertNotNil(versionAt)
        if let versionAt {
            XCTAssertGreaterThan(
                versionAt, firstPingBody ?? -1, "version response must come after ping responses")
        }
        client.close()
    }

    func testExpect100ContinueGetsInterimResponse() throws {
        let client = shim.raw()
        client.close()
        try client.connectForHijack()
        // Send headers with Expect + only part of the body.
        let body = ShimTestSupport.jsonBody(["Image": "alpine:3.20", "Cmd": ["sleep", "5"]])
        try client.writeRaw(
            Data(
                "POST /containers/create?name=slow-body HTTP/1.1\r\nHost: d\r\nContent-Length: \(body.count)\r\nExpect: 100-continue\r\n\r\n"
                    .utf8))
        let interim = try client.readUntil(timeout: 5) {
            String(decoding: $0, as: UTF8.self).contains("100 Continue")
        }
        XCTAssertTrue(
            String(decoding: interim, as: UTF8.self).contains("100 Continue"),
            "no interim response: \(String(decoding: interim.prefix(120), as: UTF8.self))")
        try client.writeRaw(body)
        let rest = try client.readUntil(timeout: 15) { data in
            data.range(of: Data("\r\n\r\n".utf8)) != nil
        }
        // Drop the interim response bytes before the real head.
        let marker = Data("HTTP/1.1 2".utf8)
        guard let start = rest.range(of: marker)?.lowerBound else {
            return XCTFail("no final response: \(String(decoding: rest.prefix(200), as: UTF8.self))")
        }
        let response = try RawHTTPClient.parseResponse(Data(rest[start...]))
        XCTAssertEqual(response.status, 201)
        client.close()
    }

    func testChunkedRequestBodyOverTheWire() throws {
        let client = shim.raw()
        client.close()
        try client.connectForHijack()
        let bodyJSON = String(
            decoding: ShimTestSupport.jsonBody(["Image": "alpine:3.20", "Cmd": ["sleep", "5"]]),
            as: UTF8.self)
        let chunk = { (text: String) in String(format: "%x\r\n%@\r\n", text.utf8.count, text) }
        let request =
            "POST /containers/create?name=chunky HTTP/1.1\r\nHost: d\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + chunk(bodyJSON) + "0\r\n\r\n"
        try client.writeRaw(Data(request.utf8))
        let all = try client.readUntil(timeout: 15) { data in
            (try? RawHTTPClient.parseResponse(data))?.status != nil
        }
        let response = try RawHTTPClient.parseResponse(all)
        XCTAssertEqual(response.status, 201, String(decoding: response.body, as: UTF8.self))
        client.close()
    }

    // MARK: Lifecycle management

    func testStopReturnsPromptlyWithLargeGrace() throws {
        // The mock CLI stops instantly; the point is the shim must not wait
        // out the grace when the container is already observed stopped.
        let id = try createContainer("fast-stop")
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        let started = Date()
        let response = try client.request("POST", "/containers/\(id)/stop?t=10")
        XCTAssertEqual(response.status, 204)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3.0, "stop burned the 10s grace: \(elapsed)s")

        // rm right after early-returned stop must not race (awaits drain).
        XCTAssertEqual(try client.request("DELETE", "/containers/\(id)?force=true").status, 204)
    }

    func testRestartPolicyAlwaysRestartsAfterExplicitStop() throws {
        let id = try createContainer("restarting", restartPolicy: ["Name": "always"])
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/stop?t=1").status, 204)

        // Supervisor should bring it back within a poll + backoff window.
        let deadline = Date().addingTimeInterval(15)
        var runningAgain = false
        while Date() < deadline {
            let inspect = try client.request("GET", "/containers/\(id)/json")
            if inspect.status == 200,
                let object = try? JSONSerialization.jsonObject(with: inspect.body)
                    as? [String: Any],
                let state = object["State"] as? [String: Any],
                state["Status"] as? String == "running"
            {
                runningAgain = true
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(runningAgain, "always policy must restart after explicit stop")
        XCTAssertEqual(try client.request("DELETE", "/containers/\(id)?force=true").status, 204)
    }

    func testRestartPolicyUnlessStoppedStaysDown() throws {
        let id = try createContainer("staying-down", restartPolicy: ["Name": "unless-stopped"])
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/stop?t=1").status, 204)

        // Give the supervisor ample opportunity to (wrongly) restart.
        Thread.sleep(forTimeInterval: 3)
        let inspect = try client.request("GET", "/containers/\(id)/json")
        let object = try JSONSerialization.jsonObject(with: inspect.body) as! [String: Any]
        let state = object["State"] as! [String: Any]
        XCTAssertEqual(state["Status"] as? String, "exited", "unless-stopped must stay stopped")
        XCTAssertEqual(try client.request("DELETE", "/containers/\(id)?force=true").status, 204)
    }

    func testRestartActionWorks() throws {
        let id = try createContainer("restarted")
        let client = shim.raw()
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/start").status, 204)
        XCTAssertEqual(try client.request("POST", "/containers/\(id)/restart").status, 204)
        let inspect = try client.request("GET", "/containers/\(id)/json")
        let object = try JSONSerialization.jsonObject(with: inspect.body) as! [String: Any]
        XCTAssertEqual((object["State"] as! [String: Any])["Status"] as? String, "running")
        XCTAssertEqual(try client.request("DELETE", "/containers/\(id)?force=true").status, 204)
    }

    // MARK: Usage + prune reporting

    func testSystemDFReportsInUseContainers() throws {
        // Seed the mock state with alpine so the system df has images to
        // report in-use counts on.
        _ = try shim.raw().request(
            "POST", "/images/create?fromImage=alpine:3.20",
            body: Data("{}".utf8), headers: [("Content-Type", "application/json")])
        _ = try createContainer("in-use", labels: ["job": "df-test"])
        _ = try createContainer("in-use-2")
        let client = shim.raw()
        let response = try client.request("GET", "/system/df")
        XCTAssertEqual(response.status, 200)
        let object = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let images = object["Images"] as? [[String: Any]] ?? []
        let containers = object["Containers"] as? [[String: Any]] ?? []
        XCTAssertGreaterThan(images.count, 0)
        XCTAssertGreaterThan(containers.count, 0)
        // The Containers field per-image counts how many use it (docker API).
        let withInUseCount = images.filter { (($0["Containers"] as? Int) ?? 0) > 0 }
        XCTAssertFalse(
            withInUseCount.isEmpty,
            "at least one image should report in-use containers: \(images.count) images")
    }

    func testImagePruneReportsDeletedAndSpaceReclaimed() throws {
        _ = try createContainer("prune-test")  // marks alpine as in-use
        let client = shim.raw()
        // Run the prune — image must not be deleted (in use) so report empty.
        let inUsePrune = try client.request("POST", "/images/prune")
        XCTAssertEqual(inUsePrune.status, 200)
        let inUseBody = try JSONSerialization.jsonObject(with: inUsePrune.body) as! [String: Any]
        XCTAssertEqual((inUseBody["ImagesDeleted"] as? [Any])?.count ?? 0, 0)
    }

    func testContainersPruneReportsDeleted() throws {
        _ = try createContainer("to-prune")
        let client = shim.raw()
        let response = try client.request("POST", "/containers/prune")
        XCTAssertEqual(response.status, 200)
        let object = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
        let deleted = (object["ContainersDeleted"] as? [String]) ?? []
        XCTAssertFalse(deleted.isEmpty, "expected at least one deleted container")
    }

    // MARK: Networks & volumes

    func testNetworksListAndCreate() throws {
        let client = shim.raw()
        let created = try client.request(
            "POST", "/networks/create",
            body: ShimTestSupport.jsonBody(["Name": "shim-net"]),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(created.status, 201)
        XCTAssertTrue(created.body.contains("shim-net".data(using: .utf8)!))

        let list =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/networks").body) as! [[String: Any]]
        XCTAssertTrue(list.contains { $0["Name"] as? String == "shim-net" })

        XCTAssertEqual(
            try client.request("DELETE", "/networks/shim-net").status, 204)
    }

    func testVolumesLifecycle() throws {
        let client = shim.raw()
        let created = try client.request(
            "POST", "/volumes/create",
            body: ShimTestSupport.jsonBody(["Name": "shim-vol"]),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(created.status, 201)
        let list =
            try JSONSerialization.jsonObject(
                with: client.request("GET", "/volumes").body) as! [String: Any]
        let volumes = list["Volumes"] as! [[String: Any]]
        XCTAssertTrue(volumes.contains { $0["Name"] as? String == "shim-vol" })
        XCTAssertEqual(try client.request("DELETE", "/volumes/shim-vol").status, 204)
    }
}
