import Foundation

/// Maps decoded CLI JSON into the curated protobuf models shared by the app
/// and the MCP server.
public enum ModelMapper {
    public static func container(from entry: ContainerListEntry) -> Micropod_V1_Container {
        var c = Micropod_V1_Container()
        c.id = entry.id
        c.image = entry.configuration.image?.reference ?? ""
        c.state = entry.status.state ?? "unknown"
        c.createdAt = entry.configuration.creationDate ?? ""

        var resources = Micropod_V1_ContainerResources()
        if let cpus = entry.configuration.resources?.cpus {
            resources.cpus = cpus
        }
        resources.memoryBytes = UInt64(entry.configuration.resources?.memoryInBytes ?? 0)
        c.resources = resources

        let platform = entry.configuration.platform
        var platformParts: [String] = []
        if let os = platform?.os { platformParts.append(os) }
        if let arch = platform?.architecture { platformParts.append(arch) }
        c.platform = platformParts.joined(separator: "/")

        c.publishedPorts = (entry.configuration.publishedPorts ?? []).map { port in
            var p = Micropod_V1_PortMapping()
            if let hp = port.hostPort { p.hostPort = UInt32(hp) }
            if let cp = port.containerPort { p.containerPort = UInt32(cp) }
            p.`protocol` = port.protocolName ?? "tcp"
            return p
        }

        c.mounts = (entry.configuration.mounts ?? []).map { mount in
            var m = Micropod_V1_Mount()
            m.type = mount.typeName
            m.source = mount.source ?? ""
            m.destination = mount.destination ?? ""
            m.readOnly = mount.options?.contains("ro") ?? false
            return m
        }

        c.networks = (entry.configuration.networks ?? []).compactMap { $0.network }

        if let running = entry.status.networks?.first(where: { $0.ipv4Address != nil }),
            let address = running.ipv4Address
        {
            // CIDR → bare address
            c.ipv4Address = address.split(separator: "/").first.map(String.init) ?? address
        }

        c.env = entry.configuration.initProcess?.environment ?? []
        if let labels = entry.configuration.labels {
            c.labels = labels
        }
        c.rosetta = entry.configuration.rosetta ?? false
        c.readOnly = entry.configuration.readOnly ?? false
        c.useInit = entry.configuration.useInit ?? false
        c.ssh = entry.configuration.ssh ?? false
        c.virtualization = entry.configuration.virtualization ?? false
        c.runtimeHandler = entry.configuration.runtimeHandler ?? ""
        if let code = entry.status.exitCode {
            c.exitCode = String(code)
        }
        return c
    }

    public static func image(from entry: ImageListEntry) -> Micropod_V1_Image {
        var image = Micropod_V1_Image()
        image.id = entry.id
        if let name = entry.configuration.name {
            image.names = [name]
        }
        image.createdAt = entry.configuration.creationDate ?? ""
        image.digest = entry.configuration.descriptor?.digest ?? ""
        image.sizeBytes = entry.variants.reduce(UInt64(0)) { $0 + UInt64($1.size ?? 0) }
        image.variants = entry.variants.map { variant in
            var v = Micropod_V1_ImageVariant()
            v.os = variant.config?.os ?? ""
            v.architecture = variant.config?.architecture ?? ""
            if let platform = variant.platform {
                if v.os.isEmpty, let os = platform.os { v.os = os }
                if v.architecture.isEmpty, let arch = platform.architecture { v.architecture = arch }
            }
            return v
        }
        return image
    }

    public static func diskUsage(from response: DiskUsageResponse) -> Micropod_V1_DiskUsage {
        var usage = Micropod_V1_DiskUsage()
        if let containers = response.containers {
            usage.containers = diskCategory(from: containers)
        }
        if let images = response.images {
            usage.images = diskCategory(from: images)
        }
        if let volumes = response.volumes {
            usage.volumes = diskCategory(from: volumes)
        }
        let containersReclaimable = UInt64(response.containers?.reclaimable ?? 0)
        let imagesReclaimable = UInt64(response.images?.reclaimable ?? 0)
        let volumesReclaimable = UInt64(response.volumes?.reclaimable ?? 0)
        usage.totalReclaimableBytes = containersReclaimable + imagesReclaimable + volumesReclaimable
        return usage
    }

    private static func diskCategory(from response: DiskUsageResponse.DiskCategoryResponse) -> Micropod_V1_DiskCategory
    {
        var category = Micropod_V1_DiskCategory()
        category.total = UInt64(response.total ?? 0)
        category.active = UInt64(response.active ?? 0)
        category.sizeBytes = UInt64(response.sizeInBytes ?? 0)
        category.reclaimableBytes = UInt64(response.reclaimable ?? 0)
        return category
    }

    public static func systemStatus(from response: SystemStatusResponse, cliVersion: String) -> Micropod_V1_SystemStatus
    {
        var status = Micropod_V1_SystemStatus()
        status.status = response.status
        status.appRoot = response.appRoot ?? ""
        status.installRoot = response.installRoot ?? ""
        status.apiServerVersion = response.apiServerVersion ?? ""
        status.cliVersion = cliVersion
        return status
    }

    public static func network(from entry: NetworkListEntry) -> Micropod_V1_Network {
        var network = Micropod_V1_Network()
        network.id = entry.id
        network.plugin = entry.configuration.plugin ?? ""
        network.mode = entry.configuration.mode ?? ""
        network.ipv4Gateway = entry.status?.ipv4Gateway ?? ""
        network.ipv4Subnet = entry.status?.ipv4Subnet ?? ""
        network.ipv6Subnet = entry.status?.ipv6Subnet ?? ""
        network.createdAt = entry.configuration.creationDate ?? ""
        network.builtin = entry.configuration.labels?["com.apple.container.resource.role"] == "builtin"
        if let labels = entry.configuration.labels {
            network.labels = labels
        }
        return network
    }

    public static func volume(from entry: VolumeListEntry) -> Micropod_V1_Volume {
        var volume = Micropod_V1_Volume()
        volume.id = entry.id
        volume.driver = entry.configuration.driver ?? ""
        volume.format = entry.configuration.format ?? ""
        volume.sizeBytes = UInt64(entry.configuration.sizeInBytes ?? 0)
        volume.source = entry.configuration.source ?? ""
        volume.createdAt = entry.configuration.creationDate ?? ""
        if let labels = entry.configuration.labels {
            volume.labels = labels
        }
        return volume
    }
}
