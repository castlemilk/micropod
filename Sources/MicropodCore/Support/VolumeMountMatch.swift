import Foundation

/// Containers whose mounts reference a volume, matched by source path or by
/// the volume's id. Pure and CLI-free so it is unit-testable.
public func containersMounted(to volume: Micropod_V1_Volume, in containers: [Micropod_V1_Container])
    -> [Micropod_V1_Container]
{
    guard !volume.source.isEmpty else { return [] }
    return containers.filter { container in
        container.mounts.contains { mount in
            mount.source == volume.source
                || mount.source.contains(volume.id)
                || volume.source.contains(mount.source)
        }
    }
}
