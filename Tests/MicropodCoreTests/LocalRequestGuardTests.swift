import MicropodCore
import XCTest

/// Admission rules for the local API (:45454) and the Docker shim's TCP
/// listener (:45455): Host (anti DNS-rebinding), Content-Type (forces a CORS
/// preflight) and Origin.
final class LocalRequestGuardTests: XCTestCase {
    private let port: UInt16 = 45454

    private func api(
        _ method: String = "POST", host: String? = "127.0.0.1:45454", contentType: String? = "application/json",
        origin: String? = nil, bodyLength: Int = 2, allowed: Set<String> = ["https://castlemilk.github.io"]
    ) -> LocalRequestGuard.Verdict {
        var headers: [String: String] = [:]
        headers["host"] = host
        headers["content-type"] = contentType
        headers["origin"] = origin
        return LocalRequestGuard.evaluateAPI(
            method: method, headers: headers, bodyLength: bodyLength, port: port,
            originAllowed: { allowed.contains($0) })
    }

    private func status(_ verdict: LocalRequestGuard.Verdict) -> Int {
        if case .reject(let status, _) = verdict { return status }
        return 200
    }

    // MARK: - API Host

    func testAPIAcceptsOnlyLoopbackHostsOnItsPort() {
        for host in ["127.0.0.1:45454", "localhost:45454", "LocalHost:45454", "[::1]:45454"] {
            XCTAssertEqual(status(api(host: host)), 200, host)
        }
        for host in [
            "evil.example", "evil.example:45454", "127.0.0.1", "localhost", "127.0.0.1:1", "[::1]",
            "192.168.1.197:45454", "127.0.0.2:45454", "localhost.evil.example:45454", "", "a:b:c",
        ] {
            XCTAssertEqual(status(api(host: host)), 403, host)
        }
        XCTAssertEqual(status(api(host: nil)), 403, "a missing Host is refused")
        XCTAssertEqual(status(api("GET", host: "evil.example:45454", contentType: nil, bodyLength: 0)), 403)
    }

    // MARK: - API Content-Type

    func testMutationsNeedANonSimpleContentType() {
        for type in [
            "application/json", "application/json; charset=utf-8", "Application/JSON", "application/connect+json",
            "application/proto", "application/grpc", "application/grpc+proto", "application/grpc-web+proto",
        ] {
            XCTAssertEqual(status(api(contentType: type)), 200, type)
        }
        for type in [
            "text/plain", "text/plain;charset=UTF-8", "application/x-www-form-urlencoded",
            "multipart/form-data; boundary=x", "", "application/jsonx",
        ] {
            XCTAssertEqual(status(api(contentType: type)), 415, type)
        }
        XCTAssertEqual(status(api(contentType: nil, bodyLength: 0)), 415, "a body-less POST is a simple request")
        XCTAssertEqual(status(api("PUT", contentType: "text/plain")), 415)
        XCTAssertEqual(status(api("DELETE", contentType: "text/plain")), 415)
    }

    func testReadsAndBodylessDeletesNeedNoContentType() {
        XCTAssertEqual(status(api("GET", contentType: nil, bodyLength: 0)), 200)
        XCTAssertEqual(status(api("OPTIONS", contentType: nil, bodyLength: 0)), 200)
        // Browsers always preflight DELETE, so `curl -X DELETE` keeps working.
        XCTAssertEqual(status(api("DELETE", contentType: nil, bodyLength: 0)), 200)
    }

    // MARK: - API Origin

    func testForeignOriginIsRefusedAllowlistedOriginPasses() {
        XCTAssertEqual(status(api(origin: "http://evil.example")), 403)
        XCTAssertEqual(status(api(origin: "null")), 403)
        XCTAssertEqual(status(api(origin: "https://castlemilk.github.io")), 200)
        XCTAssertEqual(status(api(origin: "")), 200, "an empty Origin is treated as absent")
        XCTAssertEqual(status(api("OPTIONS", contentType: nil, origin: "http://evil.example", bodyLength: 0)), 403)
    }

    /// The live exposure from the review: `fetch(..., {method: "POST", body,
    /// headers: {"Content-Type": "text/plain"}})` from evil.example.
    func testCrossSiteTextPlainPingIsRefused() {
        XCTAssertEqual(status(api(host: "evil.example", contentType: "text/plain", origin: "http://evil.example")), 403)
        XCTAssertEqual(status(api(contentType: "text/plain", origin: "http://evil.example")), 403)
        XCTAssertEqual(status(api(contentType: "text/plain")), 415)
    }

    // MARK: - Docker shim

    private func shim(_ headers: [String: String], port: UInt16 = 45455) -> Int {
        status(LocalRequestGuard.evaluateShim(headers: headers, port: port))
    }

    func testShimAcceptsWhatDockerClientsSend() {
        for host in [
            "127.0.0.1:45455", "localhost:45455", "[::1]:45455", "192.168.65.1:45455", "10.208.87.1:45455",
            "api.moby.localhost", "docker", "localhost", "127.0.0.1",
        ] {
            XCTAssertEqual(shim(["host": host]), 200, host)
        }
        XCTAssertEqual(shim([:]), 200, "HTTP/1.0 clients may omit Host")
        // The Docker Go client's own body-less POST content type.
        XCTAssertEqual(shim(["host": "127.0.0.1:45455", "content-type": "text/plain"]), 200)
    }

    func testShimRefusesRebindingHostsAndBrowsers() {
        for host in ["evil.example", "evil.example:45455", "docker.evil.example:45455", "127.0.0.1:2375", "a:b:c"] {
            XCTAssertEqual(shim(["host": host]), 403, host)
        }
        XCTAssertEqual(shim(["host": "127.0.0.1:45455", "origin": "http://evil.example"]), 403)
        XCTAssertEqual(shim(["host": "127.0.0.1:45455", "origin": "http://localhost:3000"]), 403)
        XCTAssertEqual(shim(["host": "127.0.0.1:45455", "sec-fetch-site": "cross-site"]), 403)
        XCTAssertEqual(shim(["host": "127.0.0.1:45455", "sec-fetch-mode": "no-cors"]), 403)
    }
}
