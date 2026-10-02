import Charts
import MicropodCore
import SwiftUI

/// Resource usage for one container: persisted history (MetricsStore)
/// plus live samples (via `container stats`).
struct ContainerStatsView: View {
    @Bindable var store: AppStore
    let containerID: String

    struct HistoryPoint {
        let timestamp: Date
        let cpu: Double
        let memoryBytes: UInt64
        let netRxRate: Double
        let netTxRate: Double
        let blockReadRate: Double
        let blockWriteRate: Double
    }

    @State private var history: [HistoryPoint] = []
    @State private var previousStats: Micropod_V1_ContainerStats?
    @State private var previousSampleTime: Date?
    @State private var window: ChartTimeWindow = .fifteenMinutes
    @State private var historyTarget: String?

    private struct HistoryRequest: Equatable {
        let target: String
        let window: ChartTimeWindow
        let visible: Bool
    }

    private var stats: Micropod_V1_ContainerStats? {
        guard store.isRuntimeRunning, store.clientAvailable,
            store.containers.contains(where: { $0.id == containerID && $0.state == "running" })
        else { return nil }
        return store.statsByID[containerID]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    ChartTimeWindowPicker(window: $window)
                }
                if let stats {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading,
                        spacing: 12
                    ) {
                        statTile(
                            "CPU", "\(Int(stats.cpuPercent))%", icon: "cpu", fallback: "cpu", color: Tokens.Chart.cpu)
                        statTile(
                            "Memory", ByteFormat.string(stats.memoryUsedBytes), icon: "memory", fallback: "memorychip",
                            color: Tokens.Chart.memory)
                        statTile(
                            "Memory limit", ByteFormat.string(stats.memoryLimitBytes), icon: "memory",
                            fallback: "memorychip", color: Tokens.Chart.memory)
                        statTile(
                            "Network Rx", ByteFormat.string(stats.networkRxBytes), icon: "network", fallback: "network",
                            color: Tokens.Chart.networkRx)
                        statTile(
                            "Network Tx", ByteFormat.string(stats.networkTxBytes), icon: "network", fallback: "network",
                            color: Tokens.Chart.networkTx)
                        statTile(
                            "PIDs", "\(stats.pids)", icon: "pids", fallback: "list.number",
                            color: Tokens.Palette.secondary)
                    }
                } else {
                    Text("Live readings unavailable. Recorded history remains available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let samples = history.filter { $0.timestamp >= Date().addingTimeInterval(-window.duration) }
                let chartSamples = downsample(samples, maxPoints: 360)

                PanelCard(title: "CPU %", icon: "cpu") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("CPU %", point.cpu)
                            )
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .foregroundStyle(Tokens.Chart.cpu)
                    .chartYScale(domain: 0...max(100, (chartSamples.map(\.cpu).max() ?? 0) + 10))
                    .frame(height: 120)
                }

                PanelCard(title: "Memory", icon: "memory") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Memory", Double(point.memoryBytes) / 1_048_576)
                            )
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .foregroundStyle(Tokens.Chart.memory)
                    .chartYAxisLabel("MiB")
                    .frame(height: 120)
                }

                PanelCard(title: "Network", icon: "network") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Rx", point.netRxRate / 1024)
                            )
                            .foregroundStyle(Tokens.Chart.networkRx)
                            .interpolationMethod(.catmullRom)
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Tx", point.netTxRate / 1024)
                            )
                            .foregroundStyle(Tokens.Chart.networkTx)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale(["Rx": Tokens.Chart.networkRx, "Tx": Tokens.Chart.networkTx])
                    .chartLegend(position: .bottom)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }

                PanelCard(title: "Disk I/O", icon: "storage") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Read", point.blockReadRate / 1024)
                            )
                            .foregroundStyle(Tokens.Chart.diskRead)
                            .interpolationMethod(.catmullRom)
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Write", point.blockWriteRate / 1024)
                            )
                            .foregroundStyle(Tokens.Chart.diskWrite)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale(["Read": Tokens.Chart.diskRead, "Write": Tokens.Chart.diskWrite])
                    .chartLegend(position: .bottom)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.Palette.canvas)
        .onChange(of: store.statsSnapshot?.sampledAt) { _, _ in
            appendHistory()
        }
        // Open with the persisted history (recorded while this view was
        // closed, even with the window hidden), then keep appending live.
        .task(id: HistoryRequest(target: containerID, window: window, visible: store.mainWindowVisible)) {
            if historyTarget != containerID {
                historyTarget = containerID
                history = []
                previousStats = nil
                previousSampleTime = nil
            }
            guard store.mainWindowVisible else { return }
            await loadHistory()
        }
    }

    private func loadHistory() async {
        guard store.metrics != nil, let metricsStore = MetricsStore.shared else { return appendHistory() }
        let id = containerID
        let range = window.duration
        let points = await Task.detached(priority: .utility) {
            metricsStore.history(.container, id, range: range).points
        }.value
        guard !Task.isCancelled, id == containerID else { return }
        let stored = points.map {
            HistoryPoint(
                timestamp: $0.timestamp, cpu: $0.average.cpuPercent,
                memoryBytes: UInt64(max(0, $0.average.memoryUsedBytes)),
                netRxRate: $0.average.networkRxRate, netTxRate: $0.average.networkTxRate,
                blockReadRate: $0.average.blockReadRate, blockWriteRate: $0.average.blockWriteRate)
        }
        let newest = stored.last?.timestamp ?? .distantPast
        history = stored + history.filter { $0.timestamp > newest }
        appendHistory()
    }

    private func appendHistory() {
        guard store.mainWindowVisible, historyTarget == containerID, let stats else { return }
        let now = Date()
        let deltas: StatsDeltas
        if let previous = previousStats, let previousTime = previousSampleTime, previousTime < now {
            deltas = statsDeltas(
                previous: previous, current: stats, seconds: now.timeIntervalSince(previousTime))
        } else {
            deltas = StatsDeltas(netRxRate: 0, netTxRate: 0, blockReadRate: 0, blockWriteRate: 0)
        }
        history.append(
            HistoryPoint(
                timestamp: now, cpu: stats.cpuPercent, memoryBytes: stats.memoryUsedBytes,
                netRxRate: deltas.netRxRate, netTxRate: deltas.netTxRate,
                blockReadRate: deltas.blockReadRate, blockWriteRate: deltas.blockWriteRate))
        // Cap covers a 3 h window at the ~5 s visible sampling cadence (and
        // the stored tiers' ~2900 points for longer windows).
        if history.count > 3000 {
            history.removeFirst(history.count - 3000)
        }
        previousStats = stats
        previousSampleTime = now
    }

    private func statTile(_ label: String, _ value: String, icon: String, fallback: String, color: Color) -> some View {
        WorkspaceMetric(title: label, value: value, icon: icon, color: color, fallback: fallback)
            .help(value)
    }
}
