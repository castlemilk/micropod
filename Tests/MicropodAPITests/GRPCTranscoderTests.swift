import Foundation
import XCTest

@testable import MicropodAPI

final class GRPCTranscoderTests: XCTestCase {
    func testConnectCodesMapToGRPCStatuses() {
        let pairs: [(ConnectWireCode, Int)] = [
            (.canceled, 1), (.unknown, 2), (.invalidArgument, 3), (.deadlineExceeded, 4), (.notFound, 5),
            (.alreadyExists, 6), (.permissionDenied, 7), (.resourceExhausted, 8), (.failedPrecondition, 9),
            (.aborted, 10), (.outOfRange, 11), (.unimplemented, 12), (.internal, 13), (.unavailable, 14),
            (.dataLoss, 15), (.unauthenticated, 16),
        ]
        for (code, status) in pairs {
            XCTAssertEqual(code.grpcStatus, status, code.rawValue)
            let body = Data(#"{"code":"\#(code.rawValue)","message":"m"}"#.utf8)
            XCTAssertEqual(GRPCWire.status(ofError: code.httpStatus, body: body).code, status, code.rawValue)
            let end = Data(#"{"error":{"code":"\#(code.rawValue)","message":"m"}}"#.utf8)
            XCTAssertEqual(GRPCWire.status(ofEndStream: end).code, status, code.rawValue)
        }
    }

    func testHTTPStatusesWithoutACodeMapAsGRPCSays() {
        for (http, status) in [
            (400, 13), (401, 16), (403, 7), (404, 12), (429, 14), (502, 14), (503, 14), (504, 14), (500, 2), (409, 2),
        ] {
            XCTAssertEqual(GRPCWire.status(ofError: http, body: Data(#"{"error":"x"}"#.utf8)).code, status, "\(http)")
        }
        XCTAssertEqual(GRPCWire.status(ofError: 404, body: Data(#"{"error":"not found"}"#.utf8)).message, "not found")
        XCTAssertEqual(GRPCWire.status(ofError: 500, body: Data("plain".utf8)).message, "plain")
    }

    func testEndStreamStatuses() {
        XCTAssertEqual(GRPCWire.status(ofEndStream: Data("{}".utf8)).code, 0)
        XCTAssertEqual(GRPCWire.status(ofEndStream: Data("not json".utf8)).code, 13)
        let error = GRPCWire.status(ofEndStream: Data(#"{"error":{"code":"not_found","message":"gone"}}"#.utf8))
        XCTAssertEqual(error.code, 5)
        XCTAssertEqual(error.message, "gone")
    }

    func testMessagesArePercentEncoded() {
        XCTAssertEqual(GRPCWire.percentEncode("plain text: ok"), "plain text: ok")
        XCTAssertEqual(GRPCWire.percentEncode("100%"), "100%25")
        XCTAssertEqual(GRPCWire.percentEncode("line\nbreak"), "line%0Abreak")
        XCTAssertEqual(GRPCWire.percentEncode("café"), "caf%C3%A9")
        XCTAssertEqual(GRPCWire.trailers(5, "a\tb").map(\.1), ["5", "a%09b"])
        XCTAssertEqual(GRPCWire.trailers(0, "").map(\.0), ["grpc-status"])
    }

    func testTimeouts() {
        XCTAssertEqual(GRPCWire.timeout(nil), .none)
        XCTAssertEqual(GRPCWire.timeout("1H"), .after(.seconds(3600)))
        XCTAssertEqual(GRPCWire.timeout("2M"), .after(.seconds(120)))
        XCTAssertEqual(GRPCWire.timeout("3S"), .after(.seconds(3)))
        XCTAssertEqual(GRPCWire.timeout("50m"), .after(.milliseconds(50)))
        XCTAssertEqual(GRPCWire.timeout("7u"), .after(.microseconds(7)))
        XCTAssertEqual(GRPCWire.timeout("99999999n"), .after(.nanoseconds(99_999_999)))
        for bad in ["", "S", "100", "123456789S", "1x", "-1S", "1.5S", " 1S"] {
            XCTAssertEqual(GRPCWire.timeout(bad), .malformed, bad)
        }
    }

    func testCodecsComeFromTheContentType() {
        XCTAssertEqual(GRPCWire.codec(contentType: "application/grpc"), .proto)
        XCTAssertEqual(GRPCWire.codec(contentType: "application/grpc+proto"), .proto)
        XCTAssertEqual(GRPCWire.codec(contentType: "Application/GRPC+JSON; charset=utf-8"), .json)
        XCTAssertNil(GRPCWire.codec(contentType: "application/grpc-web"))
        XCTAssertNil(GRPCWire.codec(contentType: "application/connect+proto"))
        XCTAssertNil(GRPCWire.codec(contentType: nil))
    }

    func testOneMessageExactly() {
        XCTAssertEqual(GRPCWire.singleMessage(GRPCWire.message(Data("x".utf8))), .message(Data("x".utf8)))
        XCTAssertEqual(GRPCWire.singleMessage(GRPCWire.message(Data())), .message(Data()))
        XCTAssertEqual(GRPCWire.singleMessage(ConnectEnvelope.frame(Data("x".utf8), flags: 1)), .compressed)
        guard case .malformed = GRPCWire.singleMessage(Data()) else { return XCTFail("none") }
        guard case .malformed = GRPCWire.singleMessage(GRPCWire.message(Data()) + GRPCWire.message(Data())) else {
            return XCTFail("two")
        }
        guard case .malformed = GRPCWire.singleMessage(Data([0, 0, 0, 0, 2, 1])) else { return XCTFail("cut") }
    }

    /// Envelopes come out whole however the bytes are split or coalesced.
    func testTheEnvelopeReaderTakesAnySplit() {
        let stream =
            ConnectEnvelope.frame(Data("one".utf8), flags: 0) + ConnectEnvelope.frame(Data(), flags: 0)
            + ConnectEnvelope.frame(Data(repeating: 7, count: 300), flags: 0)
            + ConnectEnvelope.frame(Data("{}".utf8), flags: 2)
        for cut in 0...stream.count {
            var reader = ConnectEnvelopeReader()
            let frames = reader.feed(stream.prefix(cut)) + reader.feed(stream.dropFirst(cut))
            XCTAssertEqual(frames.map(\.flags), [0, 0, 0, 2], "cut at \(cut)")
            XCTAssertEqual(frames.map(\.payload.count), [3, 0, 300, 2], "cut at \(cut)")
            XCTAssertEqual(reader.pending, 0)
        }
        var bytewise = ConnectEnvelopeReader()
        var frames: [(flags: UInt8, payload: Data)] = []
        for byte in stream { frames += bytewise.feed(Data([byte])) }
        XCTAssertEqual(frames.count, 4)
    }

    func testTheRequestHeadIsMappedOntoHTTPRequest() {
        func head(_ fields: [(String, String)]) -> HTTP2RequestAdapter.Outcome {
            HTTP2RequestAdapter.head(.init(fields))
        }
        let base = [
            (":method", "POST"), (":scheme", "http"), (":path", "/v1/x?a=1&b=c%20d"), (":authority", "localhost:1"),
        ]
        guard
            case .head(let parsed) = head(
                base + [("content-type", "application/json"), ("x-micropod-stream-framing", "chunked")])
        else { return XCTFail("a valid head") }
        let request = HTTP2RequestAdapter.request(parsed, body: Data("{}".utf8))
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/v1/x")
        XCTAssertEqual(request.query, ["a": "1", "b": "c d"])
        XCTAssertEqual(request.headers, ["host": "localhost:1", "content-type": "application/json"])
        XCTAssertEqual(head(base + [("host", "localhost:1")]), head(base), "an agreeing host field is fine")
        if case .refuse(400, _) = head(base + [("host", "evil:1")]) {} else { XCTFail("a differing host") }
        for repeated in ["content-type", "origin", "content-length", "grpc-timeout", "host"] {
            let outcome = head(base + [(repeated, "1"), (repeated, "1")])
            if case .refuse(400, _) = outcome {} else { XCTFail("repeated \(repeated): \(outcome)") }
        }
        if case .refuse(405, _) = head([(":method", "TRACE"), (":scheme", "http"), (":path", "/")]) {
        } else {
            XCTFail("TRACE")
        }
        if case .refuse(405, _) = head([(":method", "CONNECT"), (":authority", "x:1")]) {} else { XCTFail("CONNECT") }
        if case .refuse(400, _) = head([(":method", "GET"), (":scheme", "https"), (":path", "/")]) {
        } else {
            XCTFail("https")
        }
        if case .refuse(400, _) = head([(":method", "GET"), (":scheme", "http"), (":path", "*")]) {
        } else {
            XCTFail("*")
        }
        guard case .head(let bare) = head([(":method", "GET"), (":scheme", "http"), (":path", "/")]) else {
            return XCTFail("no authority")
        }
        XCTAssertNil(bare.headers["host"], "no authority: no host (the guard refuses it)")
    }

    func testTheCatalogIsProtoDeclared() throws {
        XCTAssertEqual(RPCCatalog.services.count, 12)
        XCTAssertEqual(RPCCatalog.services.values.reduce(0) { $0 + $1.count }, 90)
        XCTAssertEqual(
            RPCCatalog.services.values.flatMap(\.values).filter { $0 == .serverStream }.count, 8)
        XCTAssertEqual(
            RPCCatalog.kind(service: "micropod.v1.ContainerService", method: "StreamContainerLogs"), .serverStream)
        XCTAssertEqual(RPCCatalog.kind(service: "micropod.v1.SystemService", method: "Ping"), .unary)
        XCTAssertNil(RPCCatalog.kind(service: "micropod.v1.MicropodService", method: "Ping"))
        XCTAssertEqual(RPCCatalog.route("/micropod.v1.SystemService/Ping")?.method, "Ping")
        XCTAssertNil(RPCCatalog.route("/micropod.v1.SystemService/Ping/extra"))
        // The generated file is what scripts/gen_rpc_catalog.py makes of proto/ today.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["python3", "-I", repo.appendingPathComponent("scripts/gen_rpc_catalog.py").path, "--check"]
        check.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "PYTHONDONTWRITEBYTECODE": "1"]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, "RPCCatalog.generated.swift is stale")
    }
}
