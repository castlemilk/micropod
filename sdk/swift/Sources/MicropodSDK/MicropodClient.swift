import Foundation
import SwiftProtobuf

/// Typed facade over `micropod.v1.MicropodService`. Wraps a `ConnectClient`
/// (transport + interceptor chain) with one method per RPC.
///
///     let client = MicropodClient(baseURL: URL(string: "http://localhost:45454")!)
///     let ref = try await client.run(.with { $0.image = "alpine:3.20" })
public struct MicropodClient: Sendable {
    private static let service = "micropod.v1.MicropodService"

    public let connect: ConnectClient

    public init(connect: ConnectClient) {
        self.connect = connect
    }

    /// Client with the standard chain: tracing → retry → timeout.
    public init(
        baseURL: URL,
        retry: RetryPolicy = .default,
        timeout: Duration = .seconds(30),
        traceProvider: TraceContextProvider? = RootTraceContextProvider(),
        session: URLSession = .shared
    ) {
        self.connect = .standard(
            baseURL: baseURL,
            retry: retry,
            timeout: timeout,
            traceProvider: traceProvider,
            session: session
        )
    }

    private func path(_ method: String) -> String {
        "/\(Self.service)/\(method)"
    }

    // MARK: - System

    public func system() async throws -> Micropod_V1_SystemSnapshot {
        try await connect.unary(path: path("GetSystem"), request: Micropod_V1_Empty())
    }

    public func stats(_ request: Micropod_V1_GetStatsRequest = .init()) async throws -> Micropod_V1_GetStatsResponse {
        try await connect.unary(path: path("GetStats"), request: request)
    }

    // MARK: - Containers

    public func listContainers() async throws -> Micropod_V1_ListContainersResponse {
        try await connect.unary(path: path("ListContainers"), request: Micropod_V1_Empty())
    }

    public func run(_ request: Micropod_V1_RunContainerRequest) async throws -> Micropod_V1_ContainerRef {
        try await connect.unary(path: path("RunContainer"), request: request)
    }

    public func create(_ request: Micropod_V1_RunContainerRequest) async throws -> Micropod_V1_ContainerRef {
        try await connect.unary(path: path("CreateContainer"), request: request)
    }

    public func start(_ ref: Micropod_V1_ContainerRef) async throws {
        _ = try await connect.unary(path: path("StartContainer"), request: ref, response: Micropod_V1_Empty.self)
    }

    public func stop(_ ref: Micropod_V1_ContainerRef) async throws {
        _ = try await connect.unary(path: path("StopContainer"), request: ref, response: Micropod_V1_Empty.self)
    }

    public func restart(_ ref: Micropod_V1_ContainerRef) async throws {
        _ = try await connect.unary(path: path("RestartContainer"), request: ref, response: Micropod_V1_Empty.self)
    }

    public func kill(_ ref: Micropod_V1_ContainerRef) async throws {
        _ = try await connect.unary(path: path("KillContainer"), request: ref, response: Micropod_V1_Empty.self)
    }

    public func delete(_ request: Micropod_V1_DeleteContainerRequest) async throws {
        _ = try await connect.unary(path: path("DeleteContainer"), request: request, response: Micropod_V1_Empty.self)
    }

    /// Server-streaming log chunks for a container.
    public func streamLogs(
        _ request: Micropod_V1_StreamLogsRequest
    ) -> AsyncThrowingStream<Micropod_V1_LogChunk, Error> {
        connect.serverStream(path: path("StreamContainerLogs"), request: request)
    }

    public func exec(_ request: Micropod_V1_ExecRequest) async throws -> Micropod_V1_ExecResponse {
        try await connect.unary(path: path("Exec"), request: request)
    }

    // MARK: - Images

    public func listImages() async throws -> Micropod_V1_ListImagesResponse {
        try await connect.unary(path: path("ListImages"), request: Micropod_V1_Empty())
    }

    /// Server-streaming pull progress lines.
    public func pullImage(
        _ request: Micropod_V1_PullImageRequest
    ) -> AsyncThrowingStream<Micropod_V1_ProgressLine, Error> {
        connect.serverStream(path: path("PullImage"), request: request)
    }

    public func deleteImage(_ request: Micropod_V1_DeleteImageRequest) async throws {
        _ = try await connect.unary(path: path("DeleteImage"), request: request, response: Micropod_V1_Empty.self)
    }

    // MARK: - Volumes

    public func listVolumes() async throws -> Micropod_V1_ListVolumesResponse {
        try await connect.unary(path: path("ListVolumes"), request: Micropod_V1_Empty())
    }

    public func createVolume(_ request: Micropod_V1_CreateVolumeRequest) async throws {
        _ = try await connect.unary(path: path("CreateVolume"), request: request, response: Micropod_V1_Empty.self)
    }

    public func deleteVolume(_ request: Micropod_V1_DeleteVolumeRequest) async throws {
        _ = try await connect.unary(path: path("DeleteVolume"), request: request, response: Micropod_V1_Empty.self)
    }

    // MARK: - Networks

    public func listNetworks() async throws -> Micropod_V1_ListNetworksResponse {
        try await connect.unary(path: path("ListNetworks"), request: Micropod_V1_Empty())
    }

    public func createNetwork(_ request: Micropod_V1_CreateNetworkRequest) async throws {
        _ = try await connect.unary(path: path("CreateNetwork"), request: request, response: Micropod_V1_Empty.self)
    }

    public func deleteNetwork(_ request: Micropod_V1_DeleteNetworkRequest) async throws {
        _ = try await connect.unary(path: path("DeleteNetwork"), request: request, response: Micropod_V1_Empty.self)
    }
}
