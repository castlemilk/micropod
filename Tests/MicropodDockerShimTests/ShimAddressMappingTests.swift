import XCTest

@testable import MicropodDockerShim

/// The Apple runtime reports `ipv4Address` in CIDR form ("192.168.64.16/24"),
/// including in the captured real-runtime fixture. Docker's schema wants a
/// bare address plus a separate prefix length, and the Go docker CLI runs the
/// field through `netip.ParseAddr` — which fails on the "/24" with
/// `ParseAddr("192.168.64.16/24"): unexpected character (at "/24")`.
///
/// `plainIP` strips the suffix; these pin the prefix length that goes with it.
final class ShimAddressMappingTests: XCTestCase {
    func testCIDRAddressIsSplitIntoAddressAndPrefix() {
        XCTAssertEqual(DockerMapper.plainIP("192.168.64.16/24"), "192.168.64.16")
        XCTAssertEqual(DockerMapper.addressPrefixLength("192.168.64.16/24"), 24)
    }

    func testBareAddressIsPassedThrough() {
        XCTAssertEqual(DockerMapper.plainIP("192.168.64.16"), "192.168.64.16")
        XCTAssertEqual(
            DockerMapper.addressPrefixLength("192.168.64.16"), 0,
            "no mask means no claim about one")
    }

    func testEmptyAddressStaysEmpty() {
        XCTAssertEqual(DockerMapper.plainIP(""), "")
        XCTAssertEqual(DockerMapper.addressPrefixLength(""), 0)
    }

    func testIPv6CIDRIsSplit() {
        let v6 = "fd1c:bd31:1e48:528f:f812:c7ff:fe2a:7961/64"
        XCTAssertEqual(DockerMapper.plainIP(v6), "fd1c:bd31:1e48:528f:f812:c7ff:fe2a:7961")
        XCTAssertEqual(DockerMapper.addressPrefixLength(v6), 64)
    }

    /// A malformed mask must not be reported as a real prefix length.
    func testNonNumericPrefixIsZero() {
        XCTAssertEqual(DockerMapper.plainIP("192.168.64.16/abc"), "192.168.64.16")
        XCTAssertEqual(DockerMapper.addressPrefixLength("192.168.64.16/abc"), 0)
    }
}

/// Gateway derivation must never emit a partial address. An unstarted
/// container has no IP, and the naive "drop the last octet, append .1" yields
/// ".1", which the Go docker CLI rejects with
/// `ParseAddr(".1"): IPv4 field must have at least one digit`.
final class ShimGatewayMappingTests: XCTestCase {
    func testGatewayFromAddress() {
        XCTAssertEqual(DockerMapper.defaultGateway(for: "192.168.64.16"), "192.168.64.1")
    }

    func testNoAddressYieldsNoGateway() {
        XCTAssertEqual(DockerMapper.defaultGateway(for: ""), "")
    }

    func testPartialAddressYieldsNoGateway() {
        XCTAssertEqual(DockerMapper.defaultGateway(for: "192.168"), "")
        XCTAssertEqual(DockerMapper.defaultGateway(for: "192"), "")
    }

    func testIPv6YieldsNoIPv4Gateway() {
        XCTAssertEqual(DockerMapper.defaultGateway(for: "fd1c:bd31:1e48:528f::1"), "")
    }
}
