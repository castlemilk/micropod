import Foundation
import XCTest

@testable import MicropodRuntimeHostKit

final class WorkerExchangeTests: XCTestCase {
    func testReceiptFramesDrainBeforeExitCompletion() async throws {
        let exchange = WorkerExchange()
        defer { exchange.close() }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = ["%s\n", "hello", "verified-result"]
        process.standardOutput = output
        process.standardError = errors
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            exchange.observe(output.fileHandleForReading, continuation: continuation)
            exchange.observeErrors(errors.fileHandleForReading)
            process.terminationHandler = { process in
                exchange.terminated(code: process.terminationStatus, continuation: continuation)
            }
            do { try process.run() } catch { continuation.finish(throwing: error) }
        }
        var frames: [String] = []
        for try await data in stream { frames.append(String(decoding: data, as: UTF8.self)) }
        XCTAssertEqual(frames, ["hello", "verified-result"])
    }
    func testUnframedOversizeOutputIsRefused() async throws {
        let exchange = WorkerExchange()
        defer { exchange.close() }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        process.arguments = ["-c", "70000", "/dev/zero"]
        process.standardOutput = output
        process.standardError = errors
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            exchange.observe(output.fileHandleForReading, continuation: continuation)
            exchange.observeErrors(errors.fileHandleForReading)
            process.terminationHandler = { process in
                exchange.terminated(code: process.terminationStatus, continuation: continuation)
            }
            do { try process.run() } catch { continuation.finish(throwing: error) }
        }
        do {
            for try await _ in stream {}
            XCTFail("Oversized worker output accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
        process.waitUntilExit()
    }
}
