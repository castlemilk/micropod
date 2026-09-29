import Foundation
import MicropodCore
import MicropodRuntime

/// `micropod sandbox` — ephemeral one-VM-per-run CI sandboxes driven
/// in-process (no apiserver). Dispatched before `Services` resolution so a
/// run never pays the apiserver ping.
enum SandboxCommands {
    static let helpText = """
        micropod sandbox — ephemeral micro-VM per command (CI fast path)

        Usage:
          micropod sandbox run [flags] <image|--from ckpt> [-- cmd…]
          micropod sandbox checkpoint create <name> [flags] <image|--from ckpt> -- cmd…
          micropod sandbox checkpoint ls | rm <name…>
          micropod sandbox prune                     drop cached base disks + stale runs

        Flags:
          --from <ckpt>        boot from a checkpoint instead of an image
          -c, --cpus <n>       vCPUs (default 2)
          -m, --memory <MiB>   memory (default 2048)
          --disk <GiB>         rootfs size for image bases (default 8)
          -v <host:/guest[:ro]> virtiofs mount (repeatable)
          -e <KEY[=val]>       env var (repeatable; bare KEY copies host value)
          -w <dir>             working directory
          --net                attach a NAT network device (off by default)
          --no-tmpfs           keep /tmp on the rootfs instead of RAM
          --tmp-size <MiB>     cap the /tmp tmpfs
          --timeout <sec>      kill the guest after <sec>; exits 124
        """

    static let valueFlags: Set<String> = [
        "--from", "-c", "--cpus", "-m", "--memory", "--disk", "-v", "--volume", "-e", "--env",
        "-w", "--workdir", "--tmp-size", "--timeout",
    ]
    static let boolFlags: Set<String> = ["--net", "--no-tmpfs"]

    /// Raw argv (post `sandbox`) — the guest command after `--` must reach
    /// the VM untouched by the global `--json`/`--no-color` stripping.
    static func main(_ args: [String]) async -> Int32 {
        do {
            switch args.first {
            case "run":
                return try await run(Array(args.dropFirst()), saveAs: nil)
            case "checkpoint", "checkpoints", "ckpt":
                return try await checkpoint(Array(args.dropFirst()))
            case "prune":
                try prune()
                return ExitCode.ok
            case nil, "help", "--help", "-h":
                print(helpText)
                return args.isEmpty ? ExitCode.usage : ExitCode.ok
            default:
                throw UsageError(message: "unknown sandbox command '\(args[0])'")
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("usage: \(error.message)\n".utf8))
            return ExitCode.usage
        } catch {
            FileHandle.standardError.write(Data("error: \(errorMessage(error))\n".utf8))
            return ExitCode.failure
        }
    }

    static func run(_ args: [String], saveAs: String?) async throws -> Int32 {
        // Split at the first `--`: flags + base before, guest argv after.
        let split = args.firstIndex(of: "--")
        let head = split.map { Array(args[..<$0]) } ?? args
        let command = split.map { Array(args[($0 + 1)...]) } ?? []
        let parsed = try parseArgs(
            head, boolFlags: boolFlags, valueFlags: valueFlags, commandName: "sandbox run")

        let base: SandboxVM.Base
        var trailing = parsed.positionals
        if let ckpt = parsed.value("--from") {
            base = .checkpoint(ckpt)
        } else {
            guard !trailing.isEmpty else { throw UsageError(message: "missing <image> or --from") }
            base = .image(trailing.removeFirst())
        }

        var options = SandboxVM.Options(base: base)
        // `sandbox run alpine echo hi` works too — positionals past the
        // image are the command when there's no `--`.
        options.arguments = command.isEmpty ? trailing : command
        options.cpus = Int(parsed.value("--cpus") ?? parsed.value("-c") ?? "") ?? 2
        options.memoryMiB = UInt64(parsed.value("--memory") ?? parsed.value("-m") ?? "") ?? 2048
        if let gib = parsed.value("--disk").flatMap(UInt64.init) {
            options.diskBytes = gib * 1024 * 1024 * 1024
        }
        options.mounts = parsed.values("-v") + parsed.values("--volume")
        options.env = parsed.values("-e") + parsed.values("--env")
        options.workdir = parsed.value("-w") ?? parsed.value("--workdir")
        options.network = parsed.has("--net")
        options.tmpfsTmp = !parsed.has("--no-tmpfs")
        options.tmpSizeMiB = parsed.value("--tmp-size").flatMap(UInt64.init)
        options.timeoutSeconds = parsed.value("--timeout").flatMap(Int64.init)
        options.saveAs = saveAs

        return try await SandboxVM.run(options) { msg in
            FileHandle.standardError.write(Data("sandbox: \(msg)\n".utf8))
        }
    }

    static func checkpoint(_ args: [String]) async throws -> Int32 {
        switch args.first {
        case "create":
            guard args.count > 1, !args[1].hasPrefix("-") else {
                throw UsageError(message: "missing <name>")
            }
            return try await run(Array(args.dropFirst(2)), saveAs: args[1])
        case "ls", "list", nil:
            let items = SandboxVM.listCheckpoints()
            if items.isEmpty { print("no checkpoints") }
            for item in items {
                let mb = Double(item.sizeBytes) / 1_048_576
                print(
                    "\(item.name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
                        + String(format: "%7.0f MB  ", mb) + item.image)
            }
            return ExitCode.ok
        case "rm", "delete":
            let names = Array(args.dropFirst())
            guard !names.isEmpty else { throw UsageError(message: "missing <name>") }
            for name in names {
                try SandboxVM.deleteCheckpoint(name)
                print("removed \(name)")
            }
            return ExitCode.ok
        default:
            throw UsageError(message: "unknown checkpoint command '\(args[0])'")
        }
    }

    static func prune() throws {
        let fm = FileManager.default
        for dir in ["images", "runs"] {
            let url = SandboxVM.root.appendingPathComponent(dir)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        print("pruned cached base disks and stale runs (checkpoints kept)")
    }
}
