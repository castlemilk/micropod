import XCTest

@testable import MicropodDockerShim

/// The docker CLI probes `HEAD /_ping` before every command. A HEAD response
/// that carries a body leaves those bytes unread in the socket, and the Go
/// HTTP client reports them on the *next* request as "Unsolicited response
/// received on idle HTTP channel". Callers that merge the client's stderr into
/// parsed stdout then read that noise as data.
final class ShimHeadMethodTests: XCTestCase {
    private var shim: ShimTestSupport.MockShim!

    override func setUp() async throws {
        shim = try ShimTestSupport.makeMockShim()
    }

    func testHeadPingSendsHeadersWithoutBody() throws {
        let response = try shim.raw().request("HEAD", "/_ping")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(
            response.body.isEmpty,
            "HEAD must not carry a body; got \(response.body.count) bytes")
    }

    func testNegotiationAdvertisesTheVersionServedByTheShim() throws {
        let client = shim.raw()
        let version = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: client.request("GET", "/version").body) as? [String: Any])
        for method in ["HEAD", "GET"] {
            let ping = try client.request(method, "/_ping")
            XCTAssertEqual(ping.headers["api-version"], version["ApiVersion"] as? String)
            XCTAssertEqual(ping.headers["ostype"], version["Os"] as? String)
            XCTAssertEqual(ping.headers["builder-version"], "1")
            XCTAssertEqual(ping.headers["content-length"], method == "HEAD" ? "0" : "2")
        }
        XCTAssertEqual(try client.request("POST", "/_ping").status, 404)
        XCTAssertEqual(try client.request("GET", "/_ping/extra").status, 404)
    }

    /// The connection must stay usable — that is the whole point.
    func testConnectionStaysCleanAfterHead() throws {
        let client = shim.raw()
        _ = try client.request("HEAD", "/_ping")
        let next = try client.request("GET", "/_ping")
        XCTAssertEqual(next.status, 200)
        XCTAssertEqual(String(decoding: next.body, as: UTF8.self), "OK")
    }
}
