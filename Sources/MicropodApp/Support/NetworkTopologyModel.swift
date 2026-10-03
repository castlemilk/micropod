import Foundation
import MicropodCore

/// Index attachments once, rather than scanning every container for every
/// network during each paint. Duplicate attachments produce only one edge.
struct NetworkTopologyModel {
    struct Edge: Equatable {
        let networkIndex: Int
        let containerIndex: Int
    }

    let networks: [Micropod_V1_Network]
    let containers: [Micropod_V1_Container]
    let edges: [Edge]

    init(networks: [Micropod_V1_Network], containers: [Micropod_V1_Container]) {
        self.networks = networks
        self.containers = containers.filter { !$0.networks.isEmpty }
        let networkIndices = Dictionary(
            networks.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        var edges: [Edge] = []
        for (containerIndex, container) in self.containers.enumerated() {
            for networkID in Set(container.networks) {
                guard let networkIndex = networkIndices[networkID] else { continue }
                edges.append(Edge(networkIndex: networkIndex, containerIndex: containerIndex))
            }
        }
        self.edges = edges
    }
}

@MainActor
final class NetworkTopologyCache {
    private var containerRevision: UInt64?
    private var networkRevision: UInt64?
    private var cachedModel = NetworkTopologyModel(networks: [], containers: [])

    func model(
        networks: [Micropod_V1_Network], containers: [Micropod_V1_Container],
        containerRevision: UInt64, networkRevision: UInt64
    ) -> NetworkTopologyModel {
        if self.containerRevision != containerRevision || self.networkRevision != networkRevision {
            cachedModel = NetworkTopologyModel(networks: networks, containers: containers)
            self.containerRevision = containerRevision
            self.networkRevision = networkRevision
        }
        return cachedModel
    }
}
