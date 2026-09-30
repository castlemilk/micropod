import Foundation
import NIOCore
import XCTest

@testable import MicropodRuntime

/// shuru-parity pieces of the sandbox that need no VM: port specs, the
/// egress allowlist, secret specs, the proxy's request-head handling, and
/// overlay mounts' clone step.
final class SandboxParityTests: XCTestCase {
    // MARK: - Ports

    func testPortSpecs() throws {
        XCTAssertEqual(try PortForward.parse("8080:80"), PortForward(hostPort: 8080, guestPort: 80))
        XCTAssertEqual(try PortForward.parse("8080:80/tcp"), PortForward(hostPort: 8080, guestPort: 80))
        XCTAssertEqual(
            try PortForward.parse("0.0.0.0:8443:443"), PortForward(hostIP: "0.0.0.0", hostPort: 8443, guestPort: 443))
        for bad in ["8080", "a:80", "8080:80/udp", "70000:80", "0:80", "host:1:2", "1:2:3:4"] {
            XCTAssertThrowsError(try PortForward.parse(bad), bad)
        }
    }

    func testNetworkModeFollowsWhatTheRunNeeds() {
        var options = SandboxVM.Options(base: .image("alpine"))
        XCTAssertNil(options.networkMode, "offline by default")
        options.ports = [PortForward(hostPort: 1, guestPort: 1)]
        XCTAssertEqual(options.networkMode, .VMNET_HOST_MODE, "ports alone never open a route out")
        options.network = true
        XCTAssertEqual(options.networkMode, .VMNET_SHARED_MODE)
        options.egress = EgressPolicy(allowHosts: ["example.com"])
        XCTAssertEqual(options.networkMode, .VMNET_HOST_MODE, "a policy makes the proxy the only way out")
    }

    // MARK: - Egress policy

    func testAllowlistMatching() {
        let policy = EgressPolicy(allowHosts: ["api.openai.com", "*.npmjs.org"])
        XCTAssertTrue(policy.allows("api.openai.com"))
        XCTAssertTrue(policy.allows("API.OpenAI.com"))
        XCTAssertTrue(policy.allows("registry.npmjs.org"))
        XCTAssertFalse(policy.allows("npmjs.org"), "*. matches subdomains only")
        XCTAssertFalse(policy.allows("evil-api.openai.com.attacker.net"))
        XCTAssertFalse(policy.allows("openai.com"))
        XCTAssertTrue(EgressPolicy().allows("anything.example"), "no allowlist allows all")
    }

    func testSecretSpecs() throws {
        let secret = try SandboxSecret.parse(
            "API_KEY=REAL@api.example.com,Uploads.Example.com", environment: ["REAL": "s3cr3t"])
        XCTAssertEqual(secret.name, "API_KEY")
        XCTAssertEqual(secret.source.kind, .value)
        XCTAssertEqual(secret.hosts, ["api.example.com", "uploads.example.com"])
        XCTAssertTrue(secret.placeholder.hasPrefix("micropod_secret_"))
        XCTAssertFalse(secret.placeholder.contains("s3cr3t"))
        let other = try SandboxSecret.parse("API_KEY=REAL@api.example.com", environment: ["REAL": "s3cr3t"])
        XCTAssertNotEqual(secret.placeholder, other.placeholder, "placeholders are random per run")

        XCTAssertThrowsError(try SandboxSecret.parse("API_KEY=MISSING@h", environment: [:]))
        for bad in ["API_KEY", "=X@h", "K=@h", "K=X@", "K@h=X"] {
            XCTAssertThrowsError(try SandboxSecret.parse(bad, environment: ["X": "v"]), bad)
        }
        let policy = EgressPolicy(secrets: [secret])
        XCTAssertEqual(policy.secrets(for: "api.example.com").count, 1)
        XCTAssertTrue(policy.secrets(for: "other.example.com").isEmpty)
    }

    // MARK: - Proxy request heads

    func testHeadParsingWaitsForTheBlankLineAndKeepsTheRest() {
        var buffer = ByteBuffer(string: "CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n")
        XCTAssertNil(HTTPHead.take(from: &buffer), "incomplete head")
        buffer.writeString("\r\n\u{16}\u{03}\u{01}")  // + the start of a ClientHello
        let head = HTTPHead.take(from: &buffer)
        XCTAssertEqual(head?.method, "CONNECT")
        XCTAssertEqual(head?.target, "api.example.com:443")
        XCTAssertEqual(buffer.readableBytes, 3, "bytes after the head stay for the tunnel")
        XCTAssertEqual(HTTPHead.authority("api.example.com:443")?.0, "api.example.com")
        XCTAssertEqual(HTTPHead.authority("api.example.com:443")?.1, 443)
        XCTAssertEqual(HTTPHead.authority("[::1]:8443")?.0, "::1")
        XCTAssertNil(HTTPHead.authority("no-port"))
        XCTAssertNil(HTTPHead.authority("host:0"))
    }

    /// Absolute-form targets: busybox wget sends `GET https://…` instead of
    /// CONNECT, and a path's escapes must reach the upstream unchanged.
    func testAbsoluteFormTargets() throws {
        let https = try XCTUnwrap(HTTPHead.origin("https://Api.Example.com/v1/a%20b?x=1%202&y"))
        XCTAssertEqual(https.host, "Api.Example.com")
        XCTAssertEqual(https.port, 443)
        XCTAssertTrue(https.tls)
        XCTAssertEqual(https.path, "/v1/a%20b?x=1%202&y")
        let http = try XCTUnwrap(HTTPHead.origin("http://example.com:8080"))
        XCTAssertEqual(http.port, 8080)
        XCTAssertFalse(http.tls)
        XCTAssertEqual(http.path, "/")
        for bad in ["/relative", "ftp://example.com/", "example.com:443", "https:///nohost"] {
            XCTAssertNil(HTTPHead.origin(bad), bad)
        }
    }

    func testRewriteSubstitutesSecretsInTheHeadOnly() throws {
        let secret = try SandboxSecret.parse("TOKEN=REAL@api.example.com", environment: ["REAL": "real-value"])
        var buffer = ByteBuffer(
            string: "POST /v1/x?key=\(secret.placeholder) HTTP/1.1\r\nHost: api.example.com\r\n"
                + "Authorization: Bearer \(secret.placeholder)\r\nProxy-Connection: keep-alive\r\n"
                + "Connection: keep-alive\r\nContent-Length: 4\r\n\r\nbody")
        let head = try XCTUnwrap(HTTPHead.take(from: &buffer))
        var out = head.rewritten(target: head.target, substitutions: [secret.placeholder: "real-value"])
        let text = out.readString(length: out.readableBytes) ?? ""
        XCTAssertTrue(text.hasPrefix("POST /v1/x?key=real-value HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Authorization: Bearer real-value\r\n"))
        XCTAssertFalse(text.contains(secret.placeholder))
        XCTAssertFalse(text.lowercased().contains("proxy-connection"))
        XCTAssertTrue(text.hasSuffix("Connection: close\r\n\r\n"))
        XCTAssertEqual(text.components(separatedBy: "Connection:").count - 1, 1, "one Connection header")
        XCTAssertEqual(buffer.readString(length: buffer.readableBytes), "body", "the body is never touched")
    }

    // MARK: - Overlay mounts

    func testOverlayMountClonesSoGuestWritesMissTheHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sbx-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/nested")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "orig".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let mount = try SandboxVM.shareMount(
            "\(root.path)/src:/w:overlay", runDir: root.appendingPathComponent("run"), index: 0)
        XCTAssertEqual(mount.destination, "/w")
        XCTAssertNotEqual(mount.source, "\(root.path)/src", "the guest gets a copy, not the source")
        try "changed".write(
            toFile: "\(mount.source)/nested/a.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("a.txt"), encoding: .utf8), "orig")

        XCTAssertThrowsError(try SandboxVM.shareMount("/:/w:overlay", runDir: root, index: 1))
        XCTAssertThrowsError(try SandboxVM.shareMount("\(root.path):/w:bogus", runDir: root, index: 2))
    }
}
