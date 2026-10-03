import MicropodCore
import SwiftUI

/// Topology view: a bipartite graph of networks (left) and their attached
/// containers (right), edges from the live model. Click a network for its
/// detail sheet.
struct NetworkTopologyView: View {
    @Bindable var store: AppStore
    @State private var selectedNetwork: NetworkDetailSelection?
    @State private var topologyCache = NetworkTopologyCache()
    @State private var scrollOffset = CGPoint.zero

    private let networkNodeWidth: CGFloat = 180
    private let networkNodeHeight: CGFloat = 46
    private let containerNodeWidth: CGFloat = 150
    private let containerNodeHeight: CGFloat = 34
    private let columnGap: CGFloat = 90
    private let vSpacing: CGFloat = 16
    private let topPad: CGFloat = 16

    var body: some View {
        let model = topologyCache.model(
            networks: store.networks, containers: store.containers,
            containerRevision: store.workloadMetadataRevision,
            networkRevision: store.networkInventoryRevision)
        GeometryReader { geo in
            let diagramWidth = max(geo.size.width, networkNodeWidth + columnGap + containerNodeWidth + topPad * 2)
            let count = max(model.networks.count, model.containers.count)
            let naturalHeight = CGFloat(count) * (networkNodeHeight + vSpacing) + topPad * 2
            let nodeAreaHeight = max(280, naturalHeight, geo.size.height)
            let networkStep = (nodeAreaHeight - topPad * 2) / CGFloat(max(1, model.networks.count))
            let containerStep = (nodeAreaHeight - topPad * 2) / CGFloat(max(1, model.containers.count))
            let edgeStartX = topPad + networkNodeWidth - scrollOffset.x
            let edgeEndX = diagramWidth - topPad - containerNodeWidth - scrollOffset.x

            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.networks, id: \.id) { network in
                            networkNode(network)
                                .frame(width: networkNodeWidth, height: networkNodeHeight)
                                .frame(height: networkStep)
                                .accessibilityLabel(
                                    "Network \(network.id) — \(network.ipv4Subnet.isEmpty ? String(localized: "no subnet") : network.ipv4Subnet)"
                                )
                                .accessibilityHint(String(localized: "Click for details"))
                                .onTapGesture {
                                    selectedNetwork = NetworkDetailSelection(network: network)
                                }
                        }
                    }
                    .frame(width: networkNodeWidth)
                    Spacer(minLength: columnGap)
                    LazyVStack(spacing: 0) {
                        ForEach(model.containers, id: \.id) { container in
                            containerNode(container)
                                .frame(width: containerNodeWidth, height: containerNodeHeight)
                                .frame(height: containerStep)
                                .accessibilityLabel(
                                    "Container \(container.id) — \(container.state)\(container.ipv4Address.isEmpty ? "" : " at \(container.ipv4Address)")"
                                )
                        }
                    }
                    .frame(width: containerNodeWidth)
                }
                .padding(topPad)
                .frame(width: diagramWidth, height: nodeAreaHeight, alignment: .topLeading)
            }
            .onScrollGeometryChange(for: CGPoint.self) {
                $0.contentOffset
            } action: { _, offset in
                scrollOffset = offset
            }
            .overlay(alignment: .topLeading) {
                // A viewport-sized canvas avoids a bitmap as tall as the
                // entire graph. The lazy columns allocate only nearby nodes.
                Canvas { context, size in
                    var path = Path()
                    for edge in model.edges {
                        let startY = topPad + networkStep * (CGFloat(edge.networkIndex) + 0.5) - scrollOffset.y
                        let endY = topPad + containerStep * (CGFloat(edge.containerIndex) + 0.5) - scrollOffset.y
                        guard max(startY, endY) >= 0, min(startY, endY) <= size.height else { continue }
                        path.move(to: CGPoint(x: edgeStartX, y: startY))
                        path.addLine(to: CGPoint(x: edgeEndX, y: endY))
                    }
                    context.stroke(path, with: .color(.accentColor.opacity(0.35)), lineWidth: 1.2)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .allowsHitTesting(false)
            }
        }
        .sheet(item: $selectedNetwork) { selection in
            NetworkDetailSheet(store: store, network: selection.network)
        }
    }

    @ViewBuilder
    private func networkNode(_ network: Micropod_V1_Network) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text(network.id)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(network.id)
                if network.builtin {
                    Text(String(localized: "builtin")).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if !network.ipv4Subnet.isEmpty {
                Text(network.ipv4Subnet)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(network.ipv4Subnet)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Color.accentColor.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }

    private func containerNode(_ container: Micropod_V1_Container) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ContainerStateStyle.color(for: container.state))
                    .frame(width: 6, height: 6)
                Text(container.id)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(container.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !container.ipv4Address.isEmpty {
                Text(container.ipv4Address)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(container.ipv4Address)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }

}

/// Identifiable wrapper for presenting a network in a sheet.
struct NetworkDetailSelection: Identifiable {
    let id: String
    let network: Micropod_V1_Network
    init(network: Micropod_V1_Network) {
        self.id = network.id
        self.network = network
    }
}
