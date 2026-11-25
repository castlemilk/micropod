import Darwin
import Foundation
import MicropodCore

/// Local terminal state for one attached Docker exec. The guest owns the PTY
/// and its line discipline. The host relays control characters byte for byte.
struct DockerExecTerminal: Sendable {
    struct Size: Equatable, Sendable {
        let rows: UInt16
        let columns: UInt16
        var consoleSize: [UInt16] { [rows, columns] }
        var query: [String: String] { ["h": String(rows), "w": String(columns)] }
    }

    private let input: FileHandle?
    private let display: FileHandle?

    init(input: FileHandle?, output: FileHandle) throws {
        if let input, isatty(input.fileDescriptor) != 1 {
            throw MicropodError.message("invalidArgument: interactive TTY exec requires a terminal on stdin")
        }
        self.input = input
        display = isatty(output.fileDescriptor) == 1 ? output : nil
    }

    var canResize: Bool { display != nil }

    var size: Size? {
        guard let display else { return nil }
        var window = winsize()
        guard ioctl(display.fileDescriptor, TIOCGWINSZ, &window) == 0, window.ws_row > 0, window.ws_col > 0 else {
            return nil
        }
        return Size(rows: window.ws_row, columns: window.ws_col)
    }

    func withRawInput(_ body: () throws -> Void) throws {
        guard let input else { return try body() }
        let fd = input.fileDescriptor
        var previous = termios()
        try Self.terminalCall { tcgetattr(fd, &previous) }
        var raw = previous
        cfmakeraw(&raw)
        try Self.terminalCall { tcsetattr(fd, TCSANOW, &raw) }
        defer { try? Self.terminalCall { tcsetattr(fd, TCSANOW, &previous) } }
        try body()
    }

    private static func terminalCall(_ perform: () -> Int32) throws {
        while perform() == -1 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// Observe SIGWINCH without changing the process's signal disposition.
    /// Sample after registration to cover a resize during the start handshake.
    func watchSize(_ notify: @escaping @Sendable (Size) -> Void) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        let sample: @Sendable () -> Void = { if let size { notify(size) } }
        source.setEventHandler(handler: sample)
        source.activate()
        sample()
        return source
    }
}
