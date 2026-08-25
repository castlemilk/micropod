import Foundation

/// Computes what is actually IN USE so cleanup decisions are grounded:
/// which images are referenced by (running or stopped) containers, which
/// volumes are mounted, and what a prune would reclaim. Works off the same
/// service protocols every surface (CLI / API / shim / MCP) already uses.
public struct UsageService: Sendable {
    private let containers: any ContainerServing
    private let images: any ImageServing
    private let volumes: any VolumeServing

    public init(
        containers: any ContainerServing,
        images: any ImageServing,
        volumes: any VolumeServing
    ) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    public struct ImageUsage: Sendable {
        public let image: Micropod_V1_Image
        public let usedByContainerIDs: [String]
        public var inUse: Bool { !usedByContainerIDs.isEmpty }
    }

    public struct VolumeUsage: Sendable {
        public let volume: Micropod_V1_Volume
        public let usedByContainerIDs: [String]
        public var inUse: Bool { !usedByContainerIDs.isEmpty }
    }

    public struct ContainerUsage: Sendable {
        public let container: Micropod_V1_Container
        public var running: Bool { container.state.lowercased() == "running" }
    }

    public struct Report: Sendable {
        public let images: [ImageUsage]
        public let volumes: [VolumeUsage]
        public let containers: [ContainerUsage]
        public var reclaimableImageBytes: UInt64 {
            images.filter { !$0.inUse }.reduce(0) { $0 + $1.image.sizeBytes }
        }
        public var reclaimableVolumeBytes: UInt64 {
            volumes.filter { !$0.inUse }.reduce(0) { $0 + $1.volume.sizeBytes }
        }
        public var stoppedContainerCount: Int {
            containers.filter { !$0.running }.count
        }
    }

    public func report() async throws -> Report {
        async let listedContainers = containers.list()
        async let listedImages = images.list()
        async let listedVolumes = volumes.list()
        let (containerList, imageList, volumeList) = try await (
            listedContainers, listedImages, listedVolumes
        )

        // Image usage: normalize refs both ways so "alpine:3.20" (image
        // list) matches "docker.io/library/alpine:3.20" (container refs).
        var byNormalizedRef = [String: [String]]()
        for container in containerList {
            byNormalizedRef[Self.normalize(container.image), default: []].append(container.id)
        }
        let imageUsage = imageList.map { image -> ImageUsage in
            let users =
                (byNormalizedRef[Self.normalize(image.id)] ?? [])
                + image.names.flatMap { byNormalizedRef[Self.normalize($0)] ?? [] }
            return ImageUsage(image: image, usedByContainerIDs: users.uniqued())
        }

        // Volume usage: the real runtime reports each mount's source as the
        // volume's backing-file path; the mock uses the volume name. Match
        // both.
        var mountsBySource = [String: [String]]()
        for container in containerList {
            for mount in container.mounts where !mount.source.isEmpty {
                mountsBySource[mount.source, default: []].append(container.id)
            }
        }
        let volumeUsage = volumeList.map { volume -> VolumeUsage in
            let users =
                (mountsBySource[volume.source] ?? []) + (mountsBySource[volume.id] ?? [])
            return VolumeUsage(volume: volume, usedByContainerIDs: users.uniqued())
        }

        return Report(
            images: imageUsage,
            volumes: volumeUsage,
            containers: containerList.map(ContainerUsage.init))
    }

    /// Strips docker.io/library/ and any digest suffix, lowercases — so
    /// "docker.io/library/alpine:3.20" ≡ "alpine:3.20" ≡ "library/alpine:3.20".
    public static func normalize(_ reference: String) -> String {
        var ref = reference.lowercased()
        if let at = ref.firstIndex(of: "@") {
            ref = String(ref[ref.startIndex..<at])
        }
        for prefix in ["docker.io/library/", "docker.io/", "library/", "index.docker.io/library/"] {
            if ref.hasPrefix(prefix) {
                ref = String(ref.dropFirst(prefix.count))
                break
            }
        }
        return ref
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
