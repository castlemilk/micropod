import Foundation
import MicropodCore
import SwiftProtobuf

enum SystemCommands {
    static func status(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "status")
        guard !parsed.has("--help") else {
            print("usage: micropod status [--json]")
            return
        }
        let status = try await services.system.status()
        if MicropodCLI.jsonOutput {
            print(try String(data: status.jsonUTF8Data(), encoding: .utf8) ?? "{}")
            return
        }
        let stateIcon =
            status.status.lowercased() == "running"
            ? Ansi.ok(status.status) : Ansi.fail(status.status)
        print("runtime:  \(stateIcon)")
        print("cli:      \(status.cliVersion)")
        print("apiserver: \(status.apiServerVersion)")
        if !status.appRoot.isEmpty { print("approot:  \(status.appRoot)") }
    }

    static func version(_ services: Services) async throws {
        let status = try await services.system.status()
        print("micropod-cli \(CLIVersion.current)")
        print("container cli \(status.cliVersion)")
        print("apiserver \(status.apiServerVersion)")
    }

    static func df(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "df")
        _ = parsed
        async let diskTask = services.system.diskUsage()
        async let reportTask = services.usage.report()
        let (usage, report) = try await (diskTask, reportTask)

        if MicropodCLI.jsonOutput {
            let payload: [String: Any] = [
                "images": report.images.map { entry -> [String: Any] in
                    [
                        "id": entry.image.id,
                        "names": entry.image.names,
                        "sizeBytes": entry.image.sizeBytes,
                        "createdAt": entry.image.createdAt,
                        "usedByContainerIDs": entry.usedByContainerIDs,
                        "inUse": entry.inUse,
                    ]
                },
                "volumes": report.volumes.map { entry -> [String: Any] in
                    [
                        "id": entry.volume.id,
                        "sizeBytes": entry.volume.sizeBytes,
                        "createdAt": entry.volume.createdAt,
                        "usedByContainerIDs": entry.usedByContainerIDs,
                        "inUse": entry.inUse,
                    ]
                },
                "reclaimableImageBytes": report.reclaimableImageBytes,
                "reclaimableVolumeBytes": report.reclaimableVolumeBytes,
                "stoppedContainerCount": report.stoppedContainerCount,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(try String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        func row(_ name: String, _ category: Micropod_V1_DiskCategory) -> [String] {
            [
                name,
                ByteFormat.string(category.sizeBytes),
                ByteFormat.string(category.active),
                "\(category.total)",
                ByteFormat.string(category.reclaimableBytes),
            ]
        }
        let rows = [
            row("containers", usage.containers),
            row("images", usage.images),
            row("volumes", usage.volumes),
        ]
        print(renderTable(headers: ["TYPE", "SIZE", "ACTIVE", "COUNT", "RECLAIMABLE"], rows: rows))

        // Per-image usage: what's actually safe to delete.
        let imageRows = report.images
            .sorted { $0.image.sizeBytes > $1.image.sizeBytes }
            .map { entry -> [String] in
                [
                    entry.image.names.first ?? entry.image.id,
                    ByteFormat.string(entry.image.sizeBytes),
                    entry.inUse ? "\(entry.usedByContainerIDs.count) container(s)" : "unused",
                    entry.image.createdAt.isEmpty ? "-" : String(entry.image.createdAt.prefix(10)),
                ]
            }
        print("\nIMAGES")
        print(renderTable(headers: ["IMAGE", "SIZE", "IN USE", "CREATED"], rows: imageRows))

        if !report.volumes.isEmpty {
            let volumeRows = report.volumes
                .sorted { $0.volume.sizeBytes > $1.volume.sizeBytes }
                .map { entry -> [String] in
                    [
                        entry.volume.id,
                        ByteFormat.string(entry.volume.sizeBytes),
                        entry.inUse ? "\(entry.usedByContainerIDs.count) container(s)" : "unused",
                        entry.volume.createdAt.isEmpty ? "-" : String(entry.volume.createdAt.prefix(10)),
                    ]
                }
            print("\nVOLUMES")
            print(renderTable(headers: ["VOLUME", "SIZE", "IN USE", "CREATED"], rows: volumeRows))
        }

        print("")
        print(
            "Reclaimable: \(ByteFormat.string(report.reclaimableImageBytes)) images + "
                + "\(ByteFormat.string(report.reclaimableVolumeBytes)) volumes, "
                + "\(report.stoppedContainerCount) stopped container(s)")
        print("Cleanup: micropod prune [--dry-run] [--images] [--volumes] [--all]")
    }

    /// System-level prune: stopped containers, dangling (or with --all every
    /// unused) image, and unused volumes — with a dry-run preview grounded
    /// in live in-use computation.
    static func systemPrune(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args, boolFlags: ["--dry-run", "--images", "--volumes", "--all"], valueFlags: [],
            commandName: "prune")
        let report = try await services.usage.report()

        let pruneImages = parsed.has("--images") || parsed.has("--all")
        let pruneVolumes = parsed.has("--volumes") || parsed.has("--all")
        let dryRun = parsed.has("--dry-run")

        let stoppedIDs = report.containers.filter { !$0.running }.map { $0.container.id }
        let unusedImages = report.images.filter { !$0.inUse }
        let unusedVolumes = pruneVolumes ? report.volumes.filter { !$0.inUse } : []
        // Bare prune keeps docker's default: dangling images only. --images /
        // --all escalate to every unused image.
        let danglingOnly = !pruneImages

        if dryRun {
            print("Dry run — would remove:")
            print("  \(stoppedIDs.count) stopped container(s)")
            let imageBytes = danglingOnly ? 0 : unusedImages.reduce(0) { $0 + $1.image.sizeBytes }
            print(
                "  \(danglingOnly ? "dangling" : "\(unusedImages.count) unused") image(s)"
                    + (danglingOnly ? "" : ", \(ByteFormat.string(imageBytes))"))
            print(
                "  \(unusedVolumes.count) unused volume(s), "
                    + ByteFormat.string(unusedVolumes.reduce(0) { $0 + $1.volume.sizeBytes }))
            if !danglingOnly {
                for image in unusedImages {
                    print("    image \(image.image.names.first ?? image.image.id)")
                }
            }
            for volume in unusedVolumes {
                print("    volume \(volume.volume.id)")
            }
            return
        }

        var reclaimed: UInt64 = 0
        for id in stoppedIDs {
            if (try? await services.containers.delete(id, force: true)) != nil {
                print("deleted container \(id)")
            }
        }

        let imagesBefore = try await services.images.list()
        _ = try? await services.images.prune(danglingOnly: danglingOnly)
        let imagesAfter = try await services.images.list()
        let imageIDsAfter = Set(imagesAfter.map { $0.id })
        let deletedImages = imagesBefore.filter { !imageIDsAfter.contains($0.id) }
        reclaimed += deletedImages.reduce(0) { $0 + $1.sizeBytes }
        for image in deletedImages {
            print("deleted image \(image.names.first ?? image.id)")
        }

        if pruneVolumes {
            let volumesBefore = try await services.volumes.list()
            _ = try? await services.volumes.prune()
            let volumesAfter = try await services.volumes.list()
            let volumeIDsAfter = Set(volumesAfter.map { $0.id })
            let deletedVolumes = volumesBefore.filter { !volumeIDsAfter.contains($0.id) }
            reclaimed += deletedVolumes.reduce(0) { $0 + $1.sizeBytes }
            for volume in deletedVolumes {
                print("deleted volume \(volume.id)")
            }
        }
        print("Reclaimed ~\(ByteFormat.string(reclaimed))")
    }

    static func machines(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            try await machineList([], services)
            return
        }
        switch sub {
        case "ls", "list": try await machineList(Array(args.dropFirst()), services)
        case "create":
            let parsed = try parseArgs(
                Array(args.dropFirst()),
                boolFlags: [],
                valueFlags: ["--name", "--cpus", "--memory"],
                commandName: "machine create")
            guard let image = parsed.positionals.first else {
                throw UsageError(message: "machine create <image> [--name n] [--cpus n] [--memory 2GB]")
            }
            try await services.machines.create(
                image: image,
                name: parsed.value("--name"),
                cpus: parsed.value("--cpus"),
                memory: parsed.value("--memory"))
            print("Created machine")
        case "rm", "delete":
            let parsed = try parseArgs(
                Array(args.dropFirst()), boolFlags: [], valueFlags: [], commandName: "machine rm")
            guard let name = parsed.positionals.first else {
                throw UsageError(message: "machine rm <name>")
            }
            try await services.machines.delete(name)
            print("Deleted machine \(name)")
        case "stop":
            let parsed = try parseArgs(
                Array(args.dropFirst()), boolFlags: [], valueFlags: [], commandName: "machine stop")
            guard let name = parsed.positionals.first else {
                throw UsageError(message: "machine stop <name>")
            }
            try await services.machines.stop(name)
            print("Stopped machine \(name)")
        case "run":
            let parsed = try parseArgs(
                Array(args.dropFirst()),
                boolFlags: [],
                valueFlags: ["--env", "-e", "--workdir", "-w"],
                commandName: "machine run")
            guard let name = parsed.positionals.first else {
                throw UsageError(
                    message: "machine run <name> [--env K=V]... [--workdir dir] -- <exe> [args...]")
            }
            let command = Array(parsed.positionals.dropFirst())
            guard !command.isEmpty else {
                throw UsageError(
                    message: "machine run <name> [--env K=V]... [--workdir dir] -- <exe> [args...]")
            }
            var extraArgs: [String] = []
            for env in parsed.values("--env") + parsed.values("-e") { extraArgs += ["--env", env] }
            if let workdir = parsed.value("--workdir") ?? parsed.value("-w") {
                extraArgs += ["--workdir", workdir]
            }
            for try await chunk in services.machines.runStreaming(
                name: name, extraArgs: extraArgs, command: command)
            {
                FileHandle.standardOutput.write(chunk)
            }
        case "properties":
            let properties = try await services.machines.properties()
            if MicropodCLI.jsonOutput {
                let data = try JSONSerialization.data(withJSONObject: properties, options: [.prettyPrinted])
                print(String(data: data, encoding: .utf8) ?? "")
                return
            }
            for (section, entries) in properties.sorted(by: { $0.key < $1.key }) {
                print(Ansi.paint(section, Ansi.bold))
                for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                    print("  \(key): \(value.displayString)")
                }
            }
        default:
            if sub.hasPrefix("-") {
                try await machineList(args, services)
            } else {
                throw UsageError(message: "unknown machines subcommand '\(sub)'")
            }
        }
    }

    static func machineList(_ args: [String], _ services: Services) async throws {
        _ = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "machines")
        let machines = try await services.machines.list()
        if MicropodCLI.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(machines)
            print(String(data: data, encoding: .utf8) ?? "")
            return
        }
        let rows = machines.map { machine in
            [
                machine.name + (machine.defaultMachine == true ? " *" : ""),
                machine.state ?? "—",
                machine.ip ?? "—",
                machine.cpus.map { "\($0)" } ?? "—",
                machine.memory ?? "—",
                relativeAge(from: machine.created ?? ""),
            ]
        }
        print(renderTable(headers: ["NAME", "STATE", "IP", "CPUS", "MEMORY", "CREATED"], rows: rows))
    }

    static func system(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            throw UsageError(message: "system start|stop|logs|status")
        }
        switch sub {
        case "start":
            try await services.system.start()
            print("Runtime started")
        case "stop":
            try await services.system.stop()
            print("Runtime stopped")
        case "status":
            try await status([], services)
        case "logs":
            try await systemLogs(Array(args.dropFirst()), services)
        default:
            throw UsageError(message: "unknown system subcommand '\(sub)'")
        }
    }

    static func systemLogs(_ args: [String], _ services: Services) async throws {
        let expanded = expandAliases(args, aliases: ["-n": "--last"])
        let parsed = try parseArgs(
            expanded,
            boolFlags: ["--follow", "-f"],
            valueFlags: ["--last", "--level"],
            commandName: "system logs")
        let last = parsed.value("--last") ?? "5m"
        let output = try await services.system.systemLogs(last: last)
        var lines = output.split(separator: "\n").map(String.init)
        if let level = parsed.value("--level")?.lowercased() {
            lines =
                level == "error" || level == "err"
                ? lines.filter {
                    $0.localizedCaseInsensitiveContains("error") || $0.localizedCaseInsensitiveContains("fail")
                        || $0.localizedCaseInsensitiveContains("panic")
                }
                : lines.filter { $0.lowercased().contains(level) }
        }
        if parsed.has("--follow") {
            for line in lines { print(line) }
            while true {
                try await Task.sleep(for: .seconds(2))
                let fresh = try await services.system.systemLogs(last: last).split(separator: "\n").map(String.init)
                for line in fresh.suffix(from: min(lines.count, fresh.count)) where !lines.contains(line) {
                    print(line)
                }
            }
        } else {
            for line in lines { print(line) }
        }
    }
}

enum CLIVersion {
    static let current = "0.1.0"
}
