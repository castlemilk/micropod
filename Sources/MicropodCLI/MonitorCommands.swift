import Foundation
import MicropodCore
import SwiftProtobuf

enum MonitorCommands {
    static func statsOnce(_ args: [String], _ services: Services) async throws {
        _ = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "stats")
        _ = try await services.stats.snapshot()
        let snapshot = try await services.stats.snapshot()
        if MicropodCLI.jsonOutput {
            print(try String(data: snapshot.jsonUTF8Data(), encoding: .utf8) ?? "{}")
            return
        }
        let rows = snapshot.containers.map { stats in
            [
                stats.id,
                String(format: "%.1f%%", stats.cpuPercent),
                ByteFormat.string(stats.memoryUsedBytes),
                ByteFormat.string(stats.memoryLimitBytes),
                ByteFormat.string(stats.networkRxBytes),
                ByteFormat.string(stats.networkTxBytes),
                "\(stats.pids)",
            ]
        }
        print(
            renderTable(
                headers: ["ID", "CPU%", "MEM USED", "MEM LIMIT", "NET RX", "NET TX", "PIDS"],
                rows: rows))
    }

    static func top(_ args: [String], _ services: Services) async throws {
        let expanded = expandAliases(args, aliases: ["-n": "--interval"])
        let parsed = try parseArgs(
            expanded,
            boolFlags: [],
            valueFlags: ["--interval", "--sort", "--count"],
            commandName: "top")
        let interval = Double(parsed.value("--interval") ?? "") ?? 2.0
        guard interval > 0 else { throw UsageError(message: "top: --interval must be > 0") }
        let sortKey = (parsed.value("--sort") ?? "cpu").lowercased()
        let maxSamples = parsed.intValue("--count", default: 0)

        var previousNet = [String: (rx: UInt64, tx: UInt64)]()
        var samples = 0
        while true {
            if maxSamples > 0 && samples >= maxSamples { break }
            do {
                try await renderTopFrame(services, interval: interval, sortKey: sortKey, previousNet: &previousNet)
            } catch is CancellationError {
                break
            }
            samples += 1
            if maxSamples == 0 || samples < maxSamples {
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            if !MicropodCLI.isTTY() && maxSamples == 0 && samples >= 1 { break }
        }
    }

    static func renderTopFrame(
        _ services: Services, interval: Double, sortKey: String,
        previousNet: inout [String: (rx: UInt64, tx: UInt64)]
    ) async throws {
        let snapshot = try await services.stats.snapshot()
        var rows = snapshot.containers.map { stats -> [String] in
            var netRate = ""
            if let previous = previousNet[stats.id] {
                let rxRate = Double(Int64(stats.networkRxBytes) - Int64(previous.rx)) / interval
                let txRate = Double(Int64(stats.networkTxBytes) - Int64(previous.tx)) / interval
                netRate =
                    "\(ByteFormat.string(Int64(max(0, rxRate))))/s ↓ \(ByteFormat.string(Int64(max(0, txRate))))/s ↑"
            }
            previousNet[stats.id] = (stats.networkRxBytes, stats.networkTxBytes)
            return [
                stats.id,
                String(format: "%.1f", stats.cpuPercent),
                ByteFormat.string(stats.memoryUsedBytes),
                memoryPercent(stats),
                netRate.isEmpty ? "—" : netRate,
                "\(stats.pids)",
            ]
        }
        switch sortKey {
        case "mem", "memory":
            rows.sort {
                memValue($0[2]) > memValue($1[2])
            }
        case "name", "id":
            rows.sort { $0[0] < $1[0] }
        default:
            rows.sort {
                Double($0[1].replacingOccurrences(of: "%", with: "")) ?? 0
                    > Double($1[1].replacingOccurrences(of: "%", with: "")) ?? 0
            }
        }

        let table = renderTable(
            headers: ["ID", "CPU%", "MEM", "MEM%", "NET", "PIDS"], rows: rows)
        if MicropodCLI.isTTY() {
            print("\u{1b}[H\u{1b}[2J\u{1b}[3J", terminator: "")
        }
        print("\(Ansi.paint("micropod top", Ansi.bold))  \(timestamp())  (interval \(interval)s — ctrl-c to quit)")
        print(table.isEmpty ? "no running containers" : table)
    }

    static func memoryPercent(_ stats: Micropod_V1_ContainerStats) -> String {
        guard stats.memoryLimitBytes > 0 else { return "—" }
        return String(format: "%.1f%%", Double(stats.memoryUsedBytes) / Double(stats.memoryLimitBytes) * 100)
    }

    static func memValue(_ text: String) -> Double {
        let numberPart = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        let value = Double(numberPart) ?? 0
        switch unit.lowercased() {
        case "kb": return value * 1024
        case "mb": return value * 1024 * 1024
        case "gb": return value * 1024 * 1024 * 1024
        case "tb": return value * 1024 * 1024 * 1024 * 1024
        default: return value
        }
    }

    struct ContainerObservation: Equatable {
        var id: String
        var image: String
        var state: String
        var ipv4Address: String
        var exitCode: String
    }

    static func observe(_ containers: [Micropod_V1_Container]) -> [String: ContainerObservation] {
        Dictionary(
            uniqueKeysWithValues:
                containers.map {
                    (
                        $0.id,
                        ContainerObservation(
                            id: $0.id, image: $0.image, state: $0.state.lowercased(),
                            ipv4Address: $0.ipv4Address, exitCode: $0.exitCode)
                    )
                })
    }

    static func watch(_ args: [String], _ services: Services) async throws {
        let expanded = expandAliases(args, aliases: ["-n": "--interval"])
        let parsed = try parseArgs(
            expanded,
            boolFlags: ["--all"],
            valueFlags: ["--interval"],
            commandName: "watch")
        let interval = Double(parsed.value("--interval") ?? "") ?? 2.0
        guard interval > 0 else { throw UsageError(message: "watch: --interval must be > 0") }

        var known = observe(try await services.containers.list())
        print("\(Ansi.paint("watching container events", Ansi.dim)) every \(interval)s — ctrl-c to stop")

        while true {
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            guard let fresh = try? await services.containers.list() else { continue }
            let observed = observe(fresh)
            let trackAll = parsed.has("--all")
            func tracked(_ observation: ContainerObservation) -> Bool {
                trackAll || observation.state == "running"
            }
            for (id, before) in known {
                if let after = observed[id] {
                    if after.state != before.state {
                        guard trackAll || after.state == "running" || before.state == "running" else { continue }
                        emitWatchEvent(
                            jsonMode: MicropodCLI.jsonOutput, kind: "state", id: id,
                            detail: "\(before.state) → \(after.state)")
                    } else if after.ipv4Address != before.ipv4Address, !after.ipv4Address.isEmpty {
                        emitWatchEvent(
                            jsonMode: MicropodCLI.jsonOutput, kind: "address", id: id,
                            detail: "\(before.ipv4Address) → \(after.ipv4Address)")
                    } else if after.exitCode != before.exitCode, !after.exitCode.isEmpty {
                        emitWatchEvent(
                            jsonMode: MicropodCLI.jsonOutput, kind: "exit", id: id, detail: "code \(after.exitCode)")
                    }
                } else {
                    emitWatchEvent(jsonMode: MicropodCLI.jsonOutput, kind: "removed", id: id, detail: before.state)
                }
            }
            for (id, after) in observed where known[id] == nil {
                guard tracked(after) else { continue }
                emitWatchEvent(
                    jsonMode: MicropodCLI.jsonOutput, kind: "created", id: id, detail: "\(after.image) (\(after.state))"
                )
            }
            known = observed
        }
    }

    static func emitWatchEvent(jsonMode: Bool, kind: String, id: String, detail: String) {
        if jsonMode {
            let data = try? JSONSerialization.data(
                withJSONObject: [
                    "ts": ISO8601DateFormatter().string(from: Date()),
                    "event": kind, "id": id, "detail": detail,
                ], options: [.sortedKeys])
            print(String(data: data ?? Data(), encoding: .utf8) ?? "")
        } else {
            print("[\(timestamp())] \(kind.pad(toWidth: 8)) \(id)  \(detail)")
        }
    }
}

extension String {
    func pad(toWidth width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
