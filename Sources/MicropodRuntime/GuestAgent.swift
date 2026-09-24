import Containerization
import ContainerizationOS
import Foundation
import MicropodCore
import NIOCore
import NIOPosix

/// Direct client for `vminitd`, the gRPC agent running as PID 1 inside
/// every container VM.
///
/// The connection path is: `containerDial` XPC → host fd connected to the
/// guest's vsock port (default 1024) → `Vminitd` wraps it in an HTTP/2
/// gRPC transport. This bypasses the apiserver for guest-side operations
/// and exposes calls the CLI doesn't surface: per-category cgroup stats,
/// real exit codes via `WaitProcess`, real signal delivery via
/// `kill(pid:signal:)`, guest env/filesystem ops, and `sysctl`.
///
/// The generated stubs come from `SandboxContext.proto` in
/// `apple/containerization` — pinned to the same version the installed
/// runtime's `vminit` image was built from.
public final class GuestAgent: Sendable {
    /// The default vsock port `vminitd` listens on.
    public static let vminitdPort: UInt32 = 1024

    private let api: APIServerClient
    private let group: any EventLoopGroup

    /// - Parameter group: shared NIO group for gRPC transports. Callers own
    ///   the lifecycle; use ``makeGroup()`` for a default.
    public init(api: APIServerClient, group: any EventLoopGroup) {
        self.api = api
        self.group = group
    }

    /// A suitable shared event loop group (singleton).
    public static let sharedGroup: any EventLoopGroup = MultiThreadedEventLoopGroup(
        numberOfThreads: 2)

    /// `Vminitd` client connected to the container's guest agent.
    /// Caller should `close()` it when done.
    public func vminitd(id: String) async throws -> GuestConnection {
        let handle = try await api.dial(id: id, port: Self.vminitdPort)
        do {
            let agent = try await Vminitd(connection: handle, group: group)
            return GuestConnection(agent: agent, handle: handle)
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Opens a raw byte stream to any guest vsock port — the primitive
    /// behind the API server's vsock bridge endpoint.
    public func openVsock(id: String, port: UInt32) async throws -> FileHandle {
        try await api.dial(id: id, port: port)
    }

    /// Rich per-category stats straight from the guest's cgroups.
    public func statistics(
        id: String, categories: StatCategory = .all
    ) async throws -> [ContainerStatistics] {
        let conn = try await vminitd(id: id)
        defer { Task { try? await conn.close() } }
        return try await conn.agent.containerStatistics(containerIDs: [id], categories: categories)
    }

    /// Sends a real signal to a guest pid — works where
    /// `container kill --signal TERM` can't deliver (e.g. processes that
    /// aren't the init/exec entrypoints).
    public func killGuestProcess(id: String, pid: Int32, signal: Int32) async throws -> Int32 {
        let conn = try await vminitd(id: id)
        defer { Task { try? await conn.close() } }
        return try await conn.agent.kill(pid: pid, signal: signal)
    }

    /// Waits for a guest process to exit; returns its exit status.
    public func waitProcess(id: String, processID: String, containerID: String? = nil) async throws
        -> ExitStatus
    {
        let conn = try await vminitd(id: id)
        defer { Task { try? await conn.close() } }
        return try await conn.agent.waitProcess(id: processID, containerID: containerID ?? id)
    }
}

/// A live `Vminitd` client plus the `FileHandle` that owns its vsock fd.
///
/// `Vminitd` only borrows `connection.fileDescriptor` — the NIO channel
/// registers the raw fd with kqueue but holds no reference to the handle.
/// If the handle deallocated it would close the fd underneath the channel
/// (EBADF precondition in kevent), so the two must travel together.
public struct GuestConnection: Sendable {
    public let agent: Vminitd
    private let handle: FileHandle

    init(agent: Vminitd, handle: FileHandle) {
        self.agent = agent
        self.handle = handle
    }

    /// Closes the gRPC channel, then the underlying fd (NIO may already
    /// have closed it — the error is ignored).
    public func close() async throws {
        try await agent.close()
        try? handle.close()
    }
}
