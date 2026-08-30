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

    /// The Content-Length must still describe what a GET would return.
    func testHeadPingKeepsGetContentLength() throws {
        let get = try shim.raw().request("GET", "/_ping")
        let head = try shim.raw().request("HEAD", "/_ping")
        XCTAssertFalse(get.body.isEmpty)
        XCTAssertEqual(
            head.headers["content-length"], String(get.body.count),
            "HEAD headers must match the GET response")
    }

    /// Only `_ping` is routed method-agnostically (`case (_, "_ping")`), which
    /// matches what the docker CLI actually probes. Other routes stay GET-only,
    /// so there is no HEAD-with-body exposure on them to test.

    /// The connection must stay usable — that is the whole point.
    func testConnectionStaysCleanAfterHead() throws {
        let client = shim.raw()
        _ = try client.request("HEAD", "/_ping")
        let next = try client.request("GET", "/_ping")
        XCTAssertEqual(next.status, 200)
        XCTAssertEqual(String(decoding: next.body, as: UTF8.self), "OK\n")
    }
}
