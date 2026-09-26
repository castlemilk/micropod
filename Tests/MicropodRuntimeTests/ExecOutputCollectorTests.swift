import Foundation
import XCTest

@testable import MicropodRuntime

/// Non-TTY exec output collection (O15). The exec's stdout/stderr pipes are
/// handed to the apiserver over XPC; collection ends on EOF of both pipes,
/// or — when some other holder keeps a write end open — on a short quiet
/// drain after the exit. No live runtime: a plain `Pipe` stands in for the
/// guest's stdio and a closure for `containerWait`.
final class ExecOutputCollectorTests: XCTestCase {

    /// The XPC fd object must not leave a descriptor behind in this process:
    /// once the message is gone and the caller closes its write end, the read
    /// end sees EOF. A leaked dup is what kept every exec waiting out the
    /// quiet window instead of returning on EOF.
    func testXPCFileHandleLeavesNoWriteEndOpenInThisProcess() throws {
        let pipe = Pipe()
        try Self.sendOverXPCMessage(pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()

        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var byte: UInt8 = 0
        let n = read(fd, &byte, 1)
        XCTAssertEqual(n, 0, "read end must see EOF (got \(n), errno \(errno)): a write-end dup leaked")
    }

    /// Boxes the handle in a message that is released before returning.
    private static func sendOverXPCMessage(_ handle: FileHandle) throws {
        let message = XPCMessage(route: "test.fd")
        try message.set(key: "fd", value: handle)
    }

    /// Output larger than the pipe buffer, written right up to the exit, is
    /// captured in full, and the call returns on EOF without waiting out the
    /// old 100 ms quiet window.
    func testFastExitCapturesAllOutputAndReturnsOnEOF() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ExecOutputCollector(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)

        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let outWrite = stdout.fileHandleForWriting
        let errWrite = stderr.fileHandleForWriting
        let writer = Thread {
            outWrite.write(payload)
            errWrite.write(Data("boom\n".utf8))
            try? outWrite.close()
            try? errWrite.close()
        }
        writer.start()

        // "Process exit": the writer has finished (the pipe can't hold 1 MiB,
        // so this also proves reading runs while the process does).
        while !writer.isFinished { try await Task.sleep(for: .milliseconds(1)) }
        let exited = ContinuousClock.now
        let output = await collector.finish(quiet: .seconds(2), cap: .seconds(3))
        let elapsed = ContinuousClock.now - exited

        XCTAssertEqual(output.stdout.count, payload.count)
        XCTAssertEqual(output.stdout, payload, "stdout must not be truncated")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "boom\n")
        XCTAssertLessThan(elapsed, .milliseconds(50), "EOF on both pipes ends collection")
    }

    /// Output that trails the exit event but precedes EOF is still captured:
    /// EOF, not the exit, is what ends collection.
    func testOutputTrailingTheExitEventIsCapturedUpToEOF() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ExecOutputCollector(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        try stderr.fileHandleForWriting.close()

        let outWrite = stdout.fileHandleForWriting
        Task.detached {
            try? await Task.sleep(for: .milliseconds(30))
            outWrite.write(Data("late\n".utf8))
            try? outWrite.close()
        }
        let output = await collector.finish(quiet: .seconds(2), cap: .seconds(3))
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "late\n")
    }

    /// A write end held open elsewhere (never EOF) ends collection after the
    /// short quiet drain — with the data that did arrive — not the full cap.
    func testNeverEOFEndsAfterTheQuietDrain() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ExecOutputCollector(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        stdout.fileHandleForWriting.write(Data("partial\n".utf8))
        // Neither write end is closed: EOF never arrives.

        let started = ContinuousClock.now
        let output = await collector.finish(quiet: .milliseconds(20), cap: .seconds(3))
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "partial\n")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(20))
        XCTAssertLessThan(elapsed, .milliseconds(500), "the quiet drain bounds a never-EOF, not the 3 s cap")
        withExtendedLifetime(stdout) {}
        withExtendedLifetime(stderr) {}
    }

    /// The cap bounds a pipe that keeps producing after the exit.
    func testCapBoundsAPipeThatNeverGoesQuiet() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ExecOutputCollector(stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading)
        let outWrite = stdout.fileHandleForWriting
        let chatter = Task.detached {
            while !Task.isCancelled {
                outWrite.write(Data("x".utf8))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { chatter.cancel() }

        let started = ContinuousClock.now
        let output = await collector.finish(quiet: .milliseconds(50), cap: .milliseconds(200))
        let elapsed = ContinuousClock.now - started

        XCTAssertFalse(output.stdout.isEmpty)
        XCTAssertLessThan(elapsed, .milliseconds(600))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
        withExtendedLifetime(stderr) {}
    }
}
