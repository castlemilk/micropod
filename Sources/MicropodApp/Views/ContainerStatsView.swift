import Charts
import MicropodCore
import SwiftUI

/// Live resource usage for one container (sampled via `container stats`).
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

    private var stats: Micropod_V1_ContainerStats? {
        store.statsByID[containerID]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    ChartTimeWindowPicker(window: $window)
                }
                if let stats {
                    HStack(spacing: 24) {
                        statTile("CPU", "\(Int(stats.cpuPercent))%", icon: "cpu")
                        statTile("Memory", ByteFormat.string(stats.memoryUsedBytes), icon: "memorychip")
                        statTile(
                            "Memory limit", ByteFormat.string(stats.memoryLimitBytes), icon: "externaldrive")
                        statTile("Network Rx", ByteFormat.string(stats.networkRxBytes), icon: "arrow.down")
                        statTile("Network Tx", ByteFormat.string(stats.networkTxBytes), icon: "arrow.up")
                        statTile("PIDs", "\(stats.pids)", icon: "list.number")
                    }
                } else {
                    Text("No stats — container must be running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let samples = history.filter { $0.timestamp >= Date().addingTimeInterval(-window.duration) }
                let chartSamples = downsample(samples, maxPoints: 360)

                GroupBox("CPU %") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("CPU %", point.cpu)
                            )
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYScale(domain: 0...max(100, (chartSamples.map(\.cpu).max() ?? 0) + 10))
                    .frame(height: 120)
                }

                GroupBox("Memory") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Memory", Double(point.memoryBytes) / 1_048_576)
                            )
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartYAxisLabel("MiB")
                    .frame(height: 120)
                }

                GroupBox("Network") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Rx", point.netRxRate / 1024)
                            )
                            .foregroundStyle(.green)
                            .interpolationMethod(.catmullRom)
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Tx", point.netTxRate / 1024)
                            )
                            .foregroundStyle(.blue)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale(["Rx": .green, "Tx": .blue])
                    .chartLegend(position: .trailing)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }

                GroupBox("Disk I/O") {
                    Chart {
                        ForEach(chartSamples, id: \.timestamp) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Read", point.blockReadRate / 1024)
                            )
                            .foregroundStyle(.orange)
                            .interpolationMethod(.catmullRom)
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Write", point.blockWriteRate / 1024)
                            )
                            .foregroundStyle(.purple)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                    .chartForegroundStyleScale(["Read": .orange, "Write": .purple])
                    .chartLegend(position: .trailing)
                    .chartYAxisLabel("KiB/s")
                    .frame(height: 120)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.statsSnapshot?.sampledAt) { _, _ in
            appendHistory()
        }
        .onAppear { appendHistory() }
    }

    private func appendHistory() {
        guard let stats else { return }
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
        // Cap covers a 3 h window at the ~5 s visible sampling cadence.
        if history.count > 2500 {
            history.removeFirst(history.count - 2500)
        }
        previousStats = stats
        previousSampleTime = now
    }

    private func statTile(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
        }
    }
}
