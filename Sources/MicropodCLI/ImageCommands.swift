import Foundation
import MicropodCore
import MicropodRuntime

/// Every image command takes `--runtime r` to pick the engine; without it,
/// listings merge every enabled engine that keeps images, pull goes to the
/// default runtime, and by-reference commands to the engine that has the
/// image (`ImageRouter`).
enum ImageCommands {
    static func listOrSubcommand(_ args: [String], _ services: Services) async throws {
        guard let sub = args.first else {
            try await list([], services)
            return
        }
        switch sub {
        case "ls", "list": try await list(Array(args.dropFirst()), services)
        case "inspect": try await inspect(Array(args.dropFirst()), services)
        case "prune": try await prune(Array(args.dropFirst()), services)
        default:
            if sub.hasPrefix("-") || sub.hasPrefix("--") {
                try await list(args, services)
            } else {
                throw UsageError(message: "unknown image subcommand '\(sub)'")
            }
        }
    }

    static func list(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--quiet"],
            valueFlags: ["--runtime"],
            aliases: ["-q": "--quiet"],
            commandName: "images")
        let listed = try await services.images.listByRuntime(runtime: parsed.value("--runtime"))
        let images = listed.map(\.image)
        if parsed.has("--quiet") {
            for image in images { print(image.names.first ?? image.id) }
            return
        }
        if MicropodCLI.jsonOutput {
            emitImagesJSON(listed)
            return
        }
        let rows = images.map { image -> [String] in
            let platforms = image.variants
                .compactMap { variant -> String? in
                    let parts = [variant.os, variant.architecture].filter { !$0.isEmpty }
                    return parts.isEmpty ? nil : parts.joined(separator: "/")
                }
            return [
                image.names.first ?? image.digest.prefix(19).description,
                ByteFormat.string(image.sizeBytes),
                platforms.joined(separator: ","),
                relativeAge(from: image.createdAt),
            ]
        }
        // A RUNTIME column only once more than one engine is in play, as in `ps`.
        if Set(listed.map(\.runtime)).count > 1 {
            print(
                renderTable(
                    headers: ["REFERENCE", "SIZE", "PLATFORMS", "CREATED", "RUNTIME"],
                    rows: zip(rows, listed).map { $0 + [$1.runtime] }))
            return
        }
        print(renderTable(headers: ["REFERENCE", "SIZE", "PLATFORMS", "CREATED"], rows: rows))
    }

    /// `Micropod_V1_Image` has no runtime field: an image from another
    /// engine gains a `"runtime"` key; Apple's print exactly as before.
    static func emitImagesJSON(_ listed: [ImageRouter.Listed]) {
        let entries = listed.compactMap { entry -> String? in
            guard let data = try? entry.image.jsonUTF8Data() else { return nil }
            guard entry.runtime != "apple",
                var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return String(data: data, encoding: .utf8) }
            object["runtime"] = entry.runtime
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        print("[\(entries.joined(separator: ","))]")
    }

    /// " on <runtime>" after a result line when a non-Apple runtime was named.
    static func onRuntime(_ parsed: ParsedArgs) -> String { ResourceCommands.onRuntime(parsed) }

    static func inspect(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--runtime"],
            commandName: "image inspect")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "image inspect <ref…> [--runtime r]")
        }
        for reference in parsed.positionals {
            let data = try await services.images.inspect(reference, runtime: parsed.value("--runtime"))
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func prune(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--all"],
            valueFlags: ["--runtime"],
            aliases: ["-a": "--all"],
            commandName: "image prune")
        let report = try await services.images.prune(
            danglingOnly: !parsed.has("--all"), runtime: parsed.value("--runtime"))
        print(report.isEmpty ? "Pruned" : report)
    }

    static func pull(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--platform", "--runtime"],
            commandName: "pull")
        guard let reference = parsed.positionals.first else {
            throw UsageError(message: "pull <reference> [--platform os/arch] [--runtime r]")
        }
        try await drainProgress(
            services.images.pull(reference, platform: parsed.value("--platform"), runtime: parsed.value("--runtime")),
            verb: "Pulling", subject: reference)
        print("Pulled \(reference)\(onRuntime(parsed))")
    }

    static func push(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--platform", "--runtime"],
            commandName: "push")
        guard let reference = parsed.positionals.first else {
            throw UsageError(message: "push <reference> [--platform os/arch]")
        }
        try await drainProgress(
            services.images.push(reference, platform: parsed.value("--platform"), runtime: parsed.value("--runtime")),
            verb: "Pushing", subject: reference)
        print("Pushed \(reference)")
    }

    static func build(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--no-cache"],
            valueFlags: [
                "--tag", "--file", "--target", "--platform", "--build-arg", "--cpus", "--memory", "--runtime",
            ],
            aliases: ["-t": "--tag"],
            commandName: "build")
        guard let context = parsed.positionals.first else {
            throw UsageError(message: "build <context-dir> [--tag ref]… [--file Dockerfile]")
        }
        let request = ContainerBuildRequest(
            contextDirectory: context,
            dockerfile: parsed.value("--file"),
            tags: parsed.values("--tag"),
            buildArgs: parsed.values("--build-arg"),
            target: parsed.value("--target"),
            platform: parsed.value("--platform"),
            noCache: parsed.has("--no-cache"),
            cpus: parsed.doubleValue("--cpus"),
            memory: parsed.value("--memory"))
        try await drainProgress(
            services.images.build(request, runtime: parsed.value("--runtime")), verb: "Building", subject: context)
        let tag = parsed.value("--tag") ?? context
        print("Built \(tag)")
    }

    static func tag(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: ["--runtime"], commandName: "tag")
        guard parsed.positionals.count == 2 else {
            throw UsageError(message: "tag <source> <target> [--runtime r]")
        }
        try await services.images.tag(
            source: parsed.positionals[0], target: parsed.positionals[1], runtime: parsed.value("--runtime"))
        print("Tagged \(parsed.positionals[1])")
    }

    static func rmi(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--force"],
            valueFlags: ["--runtime"],
            aliases: ["-f": "--force"],
            commandName: "rmi")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "rmi <reference…> [--force] [--runtime r]")
        }
        for reference in parsed.positionals {
            try await services.images.delete(
                reference, force: parsed.has("--force"), runtime: parsed.value("--runtime"))
            print("Deleted \(reference)")
        }
    }

    static func save(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--output", "--runtime"],
            aliases: ["-o": "--output"],
            commandName: "save")
        guard let reference = parsed.positionals.first else {
            throw UsageError(message: "save <reference> -o <path>")
        }
        guard let path = parsed.value("--output") else {
            throw UsageError(message: "save requires -o <path>")
        }
        try await services.images.save(reference, to: path, runtime: parsed.value("--runtime"))
        print("Saved \(reference) → \(path)")
    }

    static func load(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--input", "--runtime"],
            aliases: ["-i": "--input"],
            commandName: "load")
        guard let path = parsed.value("--input") ?? parsed.positionals.first else {
            throw UsageError(message: "load -i <path>")
        }
        try await services.images.load(from: path, runtime: parsed.value("--runtime"))
        print("Loaded from \(path)")
    }

    static func drainProgress(_ stream: AsyncThrowingStream<ProgressEvent, Error>, verb: String, subject: String)
        async throws
    {
        var lastStageLine = ""
        for try await event in stream {
            if event.stage != nil, event.totalStages != nil {
                lastStageLine = "[\(event.stage!)/\(event.totalStages!)] \(event.stageName ?? "")"
            }
            if !MicropodCLI.jsonOutput {
                print(
                    "\r\(verb) \(subject): \(lastStageLine.isEmpty ? event.line.trimmingCharacters(in: .whitespaces) : "\(lastStageLine) \(event.line.trimmingCharacters(in: .whitespaces))")",
                    terminator: "\r")
            }
        }
        if !MicropodCLI.jsonOutput { print() }
    }
}
