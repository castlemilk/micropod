import Foundation
import MicropodCore

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
            boolFlags: ["--quiet", "-q"],
            valueFlags: [],
            commandName: "images")
        let images = try await services.images.list()
        if parsed.has("-q") {
            for image in images { print(image.names.first ?? image.id) }
            return
        }
        if MicropodCLI.jsonOutput {
            emitJSON(images)
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
        print(renderTable(headers: ["REFERENCE", "SIZE", "PLATFORMS", "CREATED"], rows: rows))
    }

    static func inspect(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: [],
            commandName: "image inspect")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "image inspect <ref…>")
        }
        for reference in parsed.positionals {
            let data = try await services.images.inspect(reference)
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func prune(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--all", "-a"],
            valueFlags: [],
            commandName: "image prune")
        let report = try await services.images.prune(danglingOnly: !parsed.has("--all"))
        print(report.isEmpty ? "Pruned" : report)
    }

    static func pull(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--platform"],
            commandName: "pull")
        guard let reference = parsed.positionals.first else {
            throw UsageError(message: "pull <reference> [--platform os/arch]")
        }
        try await drainProgress(
            services.images.pull(reference, platform: parsed.value("--platform")), verb: "Pulling", subject: reference)
        print("Pulled \(reference)")
    }

    static func push(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--platform"],
            commandName: "push")
        guard let reference = parsed.positionals.first else {
            throw UsageError(message: "push <reference> [--platform os/arch]")
        }
        try await drainProgress(
            services.images.push(reference, platform: parsed.value("--platform")), verb: "Pushing", subject: reference)
        print("Pushed \(reference)")
    }

    static func build(_ args: [String], _ services: Services) async throws {
        let expanded = expandAliases(args, aliases: ["-t": "--tag"])
        let parsed = try parseArgs(
            expanded,
            boolFlags: ["--no-cache"],
            valueFlags: ["--tag", "--file", "--target", "--platform", "--build-arg", "--cpus", "--memory"],
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
        try await drainProgress(services.images.build(request), verb: "Building", subject: context)
        let tag = parsed.value("--tag") ?? context
        print("Built \(tag)")
    }

    static func tag(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(args, boolFlags: [], valueFlags: [], commandName: "tag")
        guard parsed.positionals.count == 2 else {
            throw UsageError(message: "tag <source> <target>")
        }
        try await services.images.tag(source: parsed.positionals[0], target: parsed.positionals[1])
        print("Tagged \(parsed.positionals[1])")
    }

    static func rmi(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: ["--force", "-f"],
            valueFlags: [],
            commandName: "rmi")
        guard !parsed.positionals.isEmpty else {
            throw UsageError(message: "rmi <reference…> [--force]")
        }
        for reference in parsed.positionals {
            try await services.images.delete(reference, force: parsed.has("--force"))
            print("Deleted \(reference)")
        }
    }

    static func save(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--output", "-o"],
            commandName: "save")
        guard let reference = parsed.positionals.first else {
            throw UsageError(message: "save <reference> -o <path>")
        }
        guard let path = parsed.value("-o") else {
            throw UsageError(message: "save requires -o <path>")
        }
        try await services.images.save(reference, to: path)
        print("Saved \(reference) → \(path)")
    }

    static func load(_ args: [String], _ services: Services) async throws {
        let parsed = try parseArgs(
            args,
            boolFlags: [],
            valueFlags: ["--input", "-i"],
            commandName: "load")
        guard let path = parsed.value("-i") ?? parsed.positionals.first else {
            throw UsageError(message: "load -i <path>")
        }
        try await services.images.load(from: path)
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
