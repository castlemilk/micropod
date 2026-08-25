import Foundation
import MicropodCore

enum DebugCommands {
    struct Check {
        var name: String
        var ok: Bool
        var detail: String
    }

    static func doctor(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--json", "--quiet", "-q"],
            valueFlags: [],
            commandName: "doctor")
        var checks: [Check] = []

        let cliURL = services.client.executableURL
        if FileManager.default.isExecutableFile(atPath: cliURL.path) {
            checks.append(Check(name: "container-cli", ok: true, detail: cliURL.path))
        } else {
            checks.append(
                Check(name: "container-cli", ok: false, detail: "not found at \(cliURL.path)"))
        }

        var status: Micropod_V1_SystemStatus?
        var probeElapsed: TimeInterval?
        do {
            let started = Date()
            status = try await services.system.status()
            probeElapsed = Date().timeIntervalSince(started)
            checks.append(
                Check(
                    name: "runtime",
                    ok: status?.status.lowercased() == "running",
                    detail:
                        "\(status?.status ?? "?") (probe \(String(format: "%.2f", probeElapsed ?? 0))s)"
                ))
            if let probeElapsed, probeElapsed > 3 {
                checks.append(
                    Check(
                        name: "probe-latency", ok: false,
                        detail: String(format: "status probe took %.1fs — apiserver may be wedged", probeElapsed)))
            }
            if let apiVersion = status?.apiServerVersion, let cliVersion = status?.cliVersion {
                let apiSemver =
                    apiVersion.firstMatch(of: /\d+\.\d+(\.\d+)?/).map { String($0.0) } ?? apiVersion
                let cliSemver =
                    cliVersion.firstMatch(of: /\d+\.\d+(\.\d+)?/).map { String($0.0) } ?? cliVersion
                if !apiSemver.isEmpty, apiSemver != cliSemver {
                    checks.append(
                        Check(
                            name: "version-skew", ok: false,
                            detail: "cli \(cliSemver) vs apiserver \(apiSemver)"))
                }
            }
        } catch {
            checks.append(Check(name: "runtime", ok: false, detail: errorMessage(error)))
        }

        let machines = (try? await services.machines.list()) ?? []
        for machine in machines where machine.state?.lowercased() != "running" {
            checks.append(Check(name: "machine-\(machine.name)", ok: false, detail: machine.state ?? "unknown"))
        }
        if !machines.isEmpty {
            checks.append(Check(name: "machines", ok: true, detail: machines.map(\.name).joined(separator: ", ")))
        }

        let containers = try await services.containers.list()
        let crashed = containers.filter { container in
            guard let code = Int(container.exitCode), code != 0 else { return false }
            return container.state.lowercased() != "running"
        }
        if crashed.isEmpty {
            checks.append(Check(name: "crashed-containers", ok: true, detail: "none"))
        } else {
            let summary =
                crashed
                .map { "\($0.id)(exit \($0.exitCode))" }
                .joined(separator: ", ")
            checks.append(Check(name: "crashed-containers", ok: false, detail: summary))
        }

        let duplicatePorts = findDuplicatePorts(containers)
        if duplicatePorts.isEmpty {
            checks.append(Check(name: "port-conflicts", ok: true, detail: "none"))
        } else {
            checks.append(Check(name: "port-conflicts", ok: false, detail: duplicatePorts))
        }

        var diskSummary = ""
        if let usage = try? await services.system.diskUsage() {
            diskSummary =
                "images \(ByteFormat.string(usage.images.sizeBytes)), containers "
                + "\(ByteFormat.string(usage.containers.sizeBytes)), volumes "
                + "\(ByteFormat.string(usage.volumes.sizeBytes)); reclaimable "
                + ByteFormat.string(usage.totalReclaimableBytes)
            checks.append(Check(name: "disk-usage", ok: true, detail: diskSummary))
        } else {
            checks.append(Check(name: "disk-usage", ok: false, detail: "unavailable"))
        }

        var kernelInfo = ""
        if let properties = try? await services.machines.properties() {
            for (_, entries) in properties.sorted(by: { $0.key < $1.key }) {
                for (key, value) in entries.sorted(by: { $0.key < $1.key })
                where key.lowercased().contains("kernel") {
                    kernelInfo += "\(key)=\(value.displayString) "
                }
            }
            if kernelInfo.isEmpty {
                kernelInfo = "no kernel properties reported"
            }
            checks.append(Check(name: "kernel", ok: true, detail: kernelInfo.trimmingCharacters(in: .whitespaces)))
        }

        var errorLines: [String] = []
        if let logs = try? await services.system.systemLogs(last: "5m") {
            errorLines = logs.split(separator: "\n").map(String.init).filter {
                ($0.localizedCaseInsensitiveContains("error") || $0.contains("panic")
                    || $0.localizedCaseInsensitiveContains("fatal"))
                    && !$0.contains("container must be running")
            }
            checks.append(
                Check(
                    name: "apiserver-errors(5m)", ok: errorLines.isEmpty,
                    detail: errorLines.isEmpty ? "clean" : "\(errorLines.count) lines"))
        }

        if parsed.has("--json") {
            let payload = checks.map { check in
                [
                    "check": check.name,
                    "ok": check.ok ? "true" : "false",
                    "detail": check.detail,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8) ?? "")
        } else if parsed.has("-q") || parsed.has("--quiet") {
            for check in checks where !check.ok {
                print("\(check.name): \(check.detail)")
            }
        } else {
            print(Ansi.paint("micropod doctor", Ansi.bold))
            for check in checks {
                let icon = check.ok ? Ansi.ok("") : Ansi.fail("")
                print("  \(icon)\(check.name.pad(toWidth: 22)) \(check.detail)")
            }
            let failed = checks.filter { !$0.ok }.count
            if failed == 0 {
                print("\n\(Ansi.ok("all checks passed"))")
            } else {
                print("\n\(Ansi.fail("\(failed) check(s) failed"))")
            }
        }
        if checks.contains(where: { !$0.ok }) {
            MicropodCLI.exitOverride = ExitCode.failure
        }
    }

    static func findDuplicatePorts(_ containers: [Micropod_V1_Container]) -> String {
        var seen = [Int: String]()
        var conflicts = [String]()
        for container in containers where container.state.lowercased() == "running" {
            for port in container.publishedPorts {
                let hostPort = Int(port.hostPort)
                guard hostPort > 0 else { continue }
                if let previous = seen[hostPort], previous != container.id {
                    conflicts.append(":\(hostPort) held by \(previous) and \(container.id)")
                }
                seen[hostPort] = container.id
            }
        }
        return conflicts.joined(separator: "; ")
    }
}
