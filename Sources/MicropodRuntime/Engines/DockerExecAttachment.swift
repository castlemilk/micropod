import CPtyShim
import Darwin
import Foundation
import MicropodCore

extension DockerClient {
    func startAttachedExec(
        _ execPath: String, stdin: FileHandle?, stdout: FileHandle, stderr: FileHandle, terminal: DockerExecTerminal?
    ) async throws {
        try Task.checkCancellation()
        let path = execPath + "/start"
        guard let terminal else {
            let payload = Data(#"{"Detach":false,"Tty":false}"#.utf8)
            return try await transferExec(path, payload: payload, stdin: stdin, stdout: stdout, stderr: stderr, terminal: nil)
        }
        let size = terminal.size
        var options: [String: Any] = ["Detach": false, "Tty": true]
        if let size { options["ConsoleSize"] = size.consoleSize }
        let payload = try JSONSerialization.data(withJSONObject: options)
        guard terminal.canResize else {
            return try await transferExec(path, payload: payload, stdin: stdin, stdout: stdout, stderr: stderr, terminal: terminal)
        }

        let (sizes, changes) = AsyncStream<DockerExecTerminal.Size>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var last = size
                for await size in sizes where size != last {
                    guard !Task.isCancelled else { return }
                    if let response = try? await request("POST", execPath + "/resize", query: size.query, timeout: .seconds(3)),
                        (200..<300).contains(response.status)
                    {
                        last = size
                    }
                }
            }
            defer {
                changes.finish()
                group.cancelAll()
            }
            try await transferExec(path, payload: payload, stdin: stdin, stdout: stdout, stderr: stderr, terminal: terminal) {
                changes.yield($0)
            }
        }
    }

    private func transferExec(
        _ path: String, payload: Data, stdin: FileHandle?, stdout: FileHandle, stderr: FileHandle,
        terminal: DockerExecTerminal?, onResize: (@Sendable (DockerExecTerminal.Size) -> Void)? = nil
    ) async throws {
        let output = try DockerExecOutput(stdout: stdout, stderr: stderr)
        try await withTaskCancellationHandler {
            try await withRequestSocket("POST", path, length: payload.count, timeout: nil, upgrade: true) {
                socket, head in
                try socket.write(head + payload)
                var reader = HTTPReader(socket: socket)
                let (status, headers) = try reader.readHead()
                let upgraded = status == 101 && headers["upgrade"]?.lowercased() == "tcp"
                if !upgraded {
                    guard status == 200 else {
                        if status == 101 {
                            throw MicropodError.unsupported("docker exec returned an unknown upgrade")
                        }
                        let body = try reader.readBody(headers: headers, limit: 1_048_576)
                        throw Self.error(status: status, Response(status: status, body: body).message)
                    }
                    let media = headers["content-type"]?.lowercased().split(separator: ";").first?
                        .trimmingCharacters(in: .whitespaces)
                    guard
                        media == "application/vnd.docker.raw-stream"
                            || media == "application/vnd.docker.multiplexed-stream"
                    else {
                        throw MicropodError.unsupported("docker exec returned no attached stream")
                    }
                    guard stdin == nil else {
                        throw MicropodError.unsupported("docker exec stdin requires a connection upgrade")
                    }
                }
                // A Docker output-only client still sends EOF on its write half.
                // Keep reading until the guest finishes sending stdout and stderr.
                let source = stdin === FileHandle.nullDevice ? nil : stdin
                if upgraded && source == nil { Darwin.shutdown(socket.fd, SHUT_WR) }
                if let terminal {
                    let watcher = onResize.map { terminal.watchSize($0) }
                    defer { watcher?.cancel() }
                    try terminal.withRawInput {
                        let input = try source.map { try DockerExecInput(source: $0, socket: socket) }
                        try reader.readBody(headers: upgraded ? [:] : headers) { try output.write(stream: 1, bytes: $0) }
                        try input?.finish()
                    }
                } else {
                    let input = try source.map { try DockerExecInput(source: $0, socket: socket) }
                    var decoder = DockerExecFrames()
                    try reader.readBody(headers: upgraded ? [:] : headers) { chunk in
                        try decoder.consume(chunk, output: output)
                    }
                    try input?.finish()
                    try decoder.finish()
                }
            }
        } onCancel: {
            output.cancel()
        }
    }
}

private final class DockerExecOutput: @unchecked Sendable {
    private let sink: OpaquePointer

    init(stdout: FileHandle, stderr: FileHandle) throws {
        for handle in [stdout, stderr] where handle !== FileHandle.nullDevice && handle.fileDescriptor < 0 {
            throw POSIXError(.EBADF)
        }
        var created: OpaquePointer?
        let error = micropod_exec_sink_create(stdout.fileDescriptor, stderr.fileDescriptor, &created)
        guard error == 0, let created else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        sink = created
    }

    func write(stream: UInt8, bytes: Data) throws {
        let error = bytes.withUnsafeBytes { raw in
            micropod_exec_sink_write(sink, stream == 2 ? 2 : 1, raw.baseAddress, raw.count)
        }
        if error == ECANCELED { throw CancellationError() }
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }

    func cancel() { micropod_exec_sink_cancel(sink) }
    deinit { micropod_exec_sink_destroy(sink) }
}

/// Stop the native pump when the peer exits even if a borrowed stdin is still open.
private final class DockerExecInput {
    private var pump: OpaquePointer?

    init(source: FileHandle, socket: Socket) throws {
        guard source.fileDescriptor >= 0 else { throw POSIXError(.EBADF) }
        let error = micropod_exec_input_start(source.fileDescriptor, socket.fd, &pump)
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }

    func finish() throws {
        guard let active = pump else { return }
        pump = nil
        let error = micropod_exec_input_stop(active)
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }

    deinit {
        if let pump { _ = micropod_exec_input_stop(pump) }
    }
}

/// stdcopy frame lengths can exceed both an HTTP chunk and the socket buffer.
/// Retain only an incomplete header and a bounded diagnostic for daemon errors.
private struct DockerExecFrames {
    private var header: [UInt8] = []
    private var stream: UInt8 = 0
    private var remaining = 0
    private var daemonError = Data()

    mutating func consume(_ chunk: Data, output: DockerExecOutput) throws {
        var bytes = chunk[...]
        while !bytes.isEmpty {
            if remaining == 0 {
                let count = min(8 - header.count, bytes.count)
                header.append(contentsOf: bytes.prefix(count))
                bytes = bytes.dropFirst(count)
                guard header.count == 8 else { return }
                stream = header[0]
                guard stream <= 3, header[1...3].allSatisfy({ $0 == 0 }) else {
                    throw MicropodError.message("internal: docker exec: invalid stream header")
                }
                remaining = header[4...7].reduce(0) { ($0 << 8) | Int($1) }
                header.removeAll(keepingCapacity: true)
            }
            let count = min(remaining, bytes.count)
            let payload = bytes.prefix(count)
            if stream == 3 {
                daemonError.append(payload.prefix(4096 - daemonError.count))
            } else if count > 0 {
                try output.write(stream: stream, bytes: payload)
            }
            remaining -= count
            bytes = bytes.dropFirst(count)
            if stream == 3 && remaining == 0 {
                throw MicropodError.message("internal: docker exec: " + String(decoding: daemonError, as: UTF8.self))
            }
        }
    }

    func finish() throws {
        guard header.isEmpty, remaining == 0 else {
            throw MicropodError.message("unavailable: docker exec: truncated stream")
        }
    }
}
