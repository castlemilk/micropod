import MicropodCore
import SwiftUI

/// Topology view: a bipartite graph of networks (left) and their attached
/// containers (right), edges from the live model. Click a network for its
/// detail sheet.
struct NetworkTopologyView: View {
    @Bindable var store: AppStore
    @State private var selectedNetwork: NetworkDetailSelection?

    private let networkNodeWidth: CGFloat = 180
    private let networkNodeHeight: CGFloat = 46
    private let containerNodeWidth: CGFloat = 150
    private let containerNodeHeight: CGFloat = 34
    private let columnGap: CGFloat = 90
    private let vSpacing: CGFloat = 16
    private let topPad: CGFloat = 16

    private var networks: [Micropod_V1_Network] {
        store.networks
    }

    /// Containers with at least one network attachment (the edges).
    private var attachedContainers: [Micropod_V1_Container] {
        store.containers.filter { !$0.networks.isEmpty }
    }

    var body: some View {
        GeometryReader { geo in
            let leftX = topPad + networkNodeWidth / 2
            let rightX = geo.size.width - topPad - containerNodeWidth / 2
            let nodeAreaHeight = max(height, geo.size.height)
            let networkYs = yPositions(count: networks.count, height: nodeAreaHeight)
            let containerYs = yPositions(count: attachedContainers.count, height: nodeAreaHeight)

            ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    // Edges behind nodes.
                    Canvas { context, size in
                        for (nIndex, network) in networks.enumerated() {
                            let nY = networkYs[nIndex]
                            let start = CGPoint(x: leftX + networkNodeWidth / 2, y: nY + networkNodeHeight / 2)
                            for (cIndex, container) in attachedContainers.enumerated() {
                                guard container.networks.contains(network.id) else { continue }
                                let cY = containerYs[cIndex]
                                let end = CGPoint(x: rightX - containerNodeWidth / 2, y: cY + containerNodeHeight / 2)
                                var path = Path()
                                path.move(to: start)
                                path.addLine(to: end)
                                context.stroke(path, with: .color(.accentColor.opacity(0.35)), lineWidth: 1.2)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: height)

                    // Network nodes.
                    ForEach(Array(networks.enumerated()), id: \.offset) { index, network in
                        networkNode(network)
                            .frame(width: networkNodeWidth, height: networkNodeHeight)
                            .position(x: leftX, y: networkYs[index])
                            .accessibilityLabel(
                                "Network \(network.id) — \(network.ipv4Subnet.isEmpty ? String(localized: "no subnet") : network.ipv4Subnet)"
                            )
                            .accessibilityHint(String(localized: "Click for details"))
                            .onTapGesture {
                                selectedNetwork = NetworkDetailSelection(network: network)
                            }
                    }

                    // Container nodes.
                    ForEach(Array(attachedContainers.enumerated()), id: \.offset) { index, container in
                        containerNode(container)
                            .frame(width: containerNodeWidth, height: containerNodeHeight)
                            .position(x: rightX, y: containerYs[index])
                            .accessibilityLabel(
                                "Container \(container.id) — \(container.state)\(container.ipv4Address.isEmpty ? "" : " at \(container.ipv4Address)")"
                            )
                    }
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)
            }
        }
        .sheet(item: $selectedNetwork) { selection in
            NetworkDetailSheet(store: store, network: selection.network)
        }
        .onChange(of: store.networks) { _, _ in }
        .onChange(of: store.containers) { _, _ in }
    }

    private var height: CGFloat {
        let count = max(networks.count, attachedContainers.count)
        return max(280, CGFloat(count) * (max(networkNodeHeight, containerNodeHeight) + vSpacing) + topPad * 2)
    }

    /// Evenly distributes `count` node centers down `height`.
    private func yPositions(count: Int, height: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let usable = height - topPad * 2
        let step = usable / CGFloat(count)
        return (0..<count).map { topPad + step * (CGFloat($0) + 0.5) }
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
                if network.builtin {
                    Text(String(localized: "builtin")).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if !network.ipv4Subnet.isEmpty {
                Text(network.ipv4Subnet)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    @ViewBuilder
    private func containerNode(_ container: Micropod_V1_Container) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(container.state == "running" ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(container.id)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !container.ipv4Address.isEmpty {
                Text(container.ipv4Address)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
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
