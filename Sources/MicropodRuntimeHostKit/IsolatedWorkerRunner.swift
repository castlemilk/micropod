import Darwin
import Foundation
import MicropodCore

/// The child announces its kernel incarnation and waits for stdin. The root
/// owner fsyncs that incarnation before delivering an action. A lost launcher
/// cannot turn an unrecorded child into a late runtime mutation.
public struct IsolatedWorkerRunner: Sendable {
    public init() {}
    public func run(
        identity: IsolatedRuntimeIdentity, workerSHA256: String, request: IsolatedRuntimeWorkerRequest,
        willBegin: @escaping @Sendable (RuntimeProcessBirth) async throws -> Void = { _ in }
    ) async throws -> IsolatedRuntimeObservation {
        guard geteuid() == 0 else {
            throw MicropodError.message("Only the approved runtime helper can launch the private worker")
        }
        try identity.validate()
        let worker = try RootRuntimeStorage.worker(digest: workerSHA256)
        guard try ManagedRuntimeInstaller.sha256(worker) == workerSHA256 else {
            throw MicropodError.message("The managed runtime worker changed")
        }
        try RuntimeCodeIdentity.verifyExecutable(worker, identifier: IsolatedRuntimePolicy.helperIdentifier)
        let data = try JSONEncoder().encode(request)
        let child = WorkerExchange()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "asuser", String(identity.serviceUID), worker.path, "--enter-worker",
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MICROPOD_ISOLATED_RUNTIME": "1",
            "CONTAINER_APP_ROOT": IsolatedRuntimePolicy.appRoot.path,
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            child.observe(output.fileHandleForReading, continuation: continuation)
            child.observeErrors(errors.fileHandleForReading)
            process.terminationHandler = { process in
                child.terminated(code: process.terminationStatus, continuation: continuation)
            }
            do { try process.run() } catch { continuation.finish(throwing: error) }
        }
        // The launcher timeout closes stdin and ends this wait. It never
        // silently releases a fence or replays an action that was delivered.
        let timer = Task {
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled {
                child.timedOut()
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
            }
        }
        defer {
            timer.cancel()
            child.close()
            try? input.fileHandleForWriting.close()
        }
        var frames = stream.makeAsyncIterator()
        guard let hello = try await frames.next(), hello.count <= 4096 else {
            throw MicropodError.message("Private worker did not announce its identity")
        }
        let birth = try JSONDecoder().decode(RuntimeProcessBirth.self, from: hello)
        guard birth.uid == identity.serviceUID, try RuntimeProcessBirth.read(birth.pid) == birth else {
            throw MicropodError.message("Private worker incarnation did not match")
        }
        try Task.checkCancellation()
        try await willBegin(birth)
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        guard let response = try await frames.next(), response.count <= 65536 else {
            throw MicropodError.message("Private worker result was not received")
        }
        // Await the final exit as well as the JSON receipt. Descendants cannot
        // turn a partial response into a successful action acknowledgement.
        while try await frames.next() != nil {}
        let observation = try JSONDecoder().decode(IsolatedRuntimeObservation.self, from: response)
        guard observation.serviceUID == identity.serviceUID,
            observation.bootstrapDomain == "user/\(identity.serviceUID)", try birth.hasExited()
        else {
            throw MicropodError.message("Private worker completion or identity is unconfirmed")
        }
        return observation
    }
}

final class WorkerExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var diagnostic = Data()
    private var handles: [FileHandle] = []
    private var timeout = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exitCode: Int32?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private func readChunk(_ handle: FileHandle) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 8192)
        var count: Int
        repeat { count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
        if count < 0 {
            lock.withLock { continuation?.finish(throwing: MicropodError.message("Private worker pipe read failed")) }
            return nil
        }
        return Data(bytes.prefix(count))
    }
    func observe(_ handle: FileHandle, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        lock.withLock {
            handles.append(handle)
            self.continuation = continuation
        }
        handle.readabilityHandler = { [self] handle in
            guard let chunk = readChunk(handle) else { return }
            lock.withLock {
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    stdoutEOF = true
                    finishIfComplete()
                    return
                }
                buffer.append(chunk)
                guard buffer.count <= 65536 else {
                    continuation.finish(throwing: MicropodError.message("Private worker output exceeded its limit"))
                    return
                }
                while let end = buffer.firstIndex(of: 10) {
                    continuation.yield(Data(buffer.prefix(upTo: end)))
                    buffer.removeSubrange(...end)
                }
            }
        }
    }
    func observeErrors(_ handle: FileHandle) {
        lock.withLock { handles.append(handle) }
        handle.readabilityHandler = { [self] handle in
            guard let chunk = readChunk(handle) else { return }
            lock.withLock {
                if diagnostic.count < 8192 { diagnostic.append(chunk.prefix(8192 - diagnostic.count)) }
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    stderrEOF = true
                    finishIfComplete()
                }
            }
        }
    }
    func timedOut() {
        lock.withLock {
            timeout = true
            continuation?.finish(
                throwing: MicropodError.message("Private worker timed out; recovery verification is required"))
        }
    }
    func terminated(code: Int32, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        lock.withLock {
            exitCode = code
            finishIfComplete()
        }
    }
    private func finishIfComplete() {
        guard stdoutEOF, stderrEOF, let exitCode else { return }
        if timeout {
            continuation?.finish(
                throwing: MicropodError.message("Private worker timed out; recovery verification is required"))
        } else if exitCode != 0 {
            continuation?.finish(
                throwing: MicropodError.message("Private worker failed: " + String(decoding: diagnostic, as: UTF8.self))
            )
        } else {
            continuation?.finish()
        }
        continuation = nil
    }
    func close() {
        let closing = lock.withLock {
            let closing = handles
            handles.removeAll()
            continuation = nil
            return closing
        }
        for handle in closing {
            handle.readabilityHandler = nil
            try? handle.close()
        }
    }
}
