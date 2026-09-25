import Foundation
import SwiftProtobuf

/// Typed facade over the `micropod.v1` services. Wraps a `ConnectClient`
/// (transport + interceptor chain) with one method per RPC.
///
///     let client = MicropodClient(baseURL: URL(string: "http://localhost:45454")!)
///     let ref = try await client.run(.with { $0.image = "alpine:3.20" })
public struct MicropodClient: Sendable {
    /// The API is grouped into per-domain services; method names are unique
    /// across services, so the facade keeps a flat surface and maps each
    /// method to its service for the Connect path.
    private static let methodService: [String: String] = [
        "ListContainers": "ContainerService",
        "RunContainer": "ContainerService",
        "CreateContainer": "ContainerService",
        "StartContainer": "ContainerService",
        "StopContainer": "ContainerService",
        "RestartContainer": "ContainerService",
        "KillContainer": "ContainerService",
        "DeleteContainer": "ContainerService",
        "StreamContainerLogs": "ContainerService",
        "GetStats": "ContainerService",
        "Exec": "ContainerService",
        "ListImages": "ImageService",
        "PullImage": "ImageService",
        "DeleteImage": "ImageService",
        "ListVolumes": "VolumeService",
        "CreateVolume": "VolumeService",
        "DeleteVolume": "VolumeService",
        "GetVolumePolicy": "VolumeService",
        "SetVolumePolicy": "VolumeService",
        "ListNetworks": "NetworkService",
        "CreateNetwork": "NetworkService",
        "DeleteNetwork": "NetworkService",
        "ComposeUp": "ComposeService",
        "ComposeDown": "ComposeService",
        "GetSystem": "SystemService",
        "GetUsage": "SystemService",
        "CheckForUpdates": "SystemService",
        "GetUpdateStatus": "SystemService",
        "ApplyUpdate": "SystemService",
        "GetK8sStatus": "K8sService",
        "GetK8sConfig": "K8sService",
        "SetK8sConfig": "K8sService",
        "K8sUp": "K8sService",
        "K8sDown": "K8sService",
        "GetKubeconfig": "K8sService",
    ]

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
        "/micropod.v1.\(Self.methodService[method] ?? "MicropodService")/\(method)"
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

    // MARK: - Usage + policy

    /// What a cleanup would reclaim: images/volumes with their referencing
    /// containers.
    public func usage() async throws -> Micropod_V1_UsageReport {
        try await connect.unary(path: path("GetUsage"), request: Micropod_V1_Empty())
    }

    /// Shared named-volume mount policy.
    public func volumePolicy() async throws -> Micropod_V1_VolumePolicy {
        try await connect.unary(path: path("GetVolumePolicy"), request: Micropod_V1_Empty())
    }

    /// Replace the volume mount policy; returns the stored policy.
    public func setVolumePolicy(_ policy: Micropod_V1_VolumePolicy) async throws -> Micropod_V1_VolumePolicy {
        try await connect.unary(path: path("SetVolumePolicy"), request: policy)
    }

    // MARK: - App updates

    /// Trigger a background update check in the desktop app.
    public func checkForUpdates() async throws -> Micropod_V1_UpdateStatus {
        try await connect.unary(path: path("CheckForUpdates"), request: Micropod_V1_Empty())
    }

    /// Last-known updater status.
    public func updateStatus() async throws -> Micropod_V1_UpdateStatus {
        try await connect.unary(path: path("GetUpdateStatus"), request: Micropod_V1_Empty())
    }

    /// Quit the app so a downloaded update installs and relaunches.
    public func applyUpdate() async throws -> Micropod_V1_UpdateStatus {
        try await connect.unary(path: path("ApplyUpdate"), request: Micropod_V1_Empty())
    }

    // MARK: - Compose

    /// Server-streaming compose-up progress; the terminal event carries
    /// `name` and `done`.
    public func composeUp(
        _ request: Micropod_V1_ComposeUpRequest
    ) -> AsyncThrowingStream<Micropod_V1_ComposeUpEvent, Error> {
        connect.serverStream(path: path("ComposeUp"), request: request)
    }

    public func composeDown(_ request: Micropod_V1_ComposeDownRequest) async throws {
        _ = try await connect.unary(path: path("ComposeDown"), request: request, response: Micropod_V1_Empty.self)
    }

    // MARK: - Kubernetes (opt-in engine)

    /// Engine enablement + live cluster state.
    public func k8sStatus() async throws -> Micropod_V1_K8sStatus {
        try await connect.unary(path: path("GetK8sStatus"), request: Micropod_V1_Empty())
    }

    /// Persisted engine config (defaults if never enabled).
    public func k8sConfig() async throws -> Micropod_V1_K8sConfig {
        try await connect.unary(path: path("GetK8sConfig"), request: Micropod_V1_Empty())
    }

    /// Persist engine config; `enabled=false` disables the feature.
    public func setK8sConfig(_ config: Micropod_V1_K8sConfig) async throws -> Micropod_V1_K8sConfig {
        try await connect.unary(path: path("SetK8sConfig"), request: config)
    }

    /// Create or resume the cluster VM — server-streaming progress; the
    /// terminal event carries `done` and the cluster `status`.
    public func k8sUp(
        _ request: Micropod_V1_K8sUpRequest = .init()
    ) -> AsyncThrowingStream<Micropod_V1_K8sUpEvent, Error> {
        connect.serverStream(path: path("K8sUp"), request: request)
    }

    /// Remove the cluster VM and its state.
    public func k8sDown() async throws {
        _ = try await connect.unary(path: path("K8sDown"), request: Micropod_V1_Empty(), response: Micropod_V1_Empty.self)
    }

    /// Host kubeconfig (path + contents, server already at the VM address).
    public func kubeconfig() async throws -> Micropod_V1_GetKubeconfigResponse {
        try await connect.unary(path: path("GetKubeconfig"), request: Micropod_V1_Empty())
    }
}
