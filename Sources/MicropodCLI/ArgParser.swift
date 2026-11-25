import Foundation

struct UsageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Global options can follow the subcommand. An exec's command and arguments
/// belong to the guest, even when they use the same flag names as Micropod.
struct GlobalArguments {
    var arguments: [String] = []
    var json = false
    var noColor = false
    var cliPath: String?

    init(_ values: [String]) {
        var rest = values[...]
        var execContainerSeen = false
        while let value = rest.popFirst() {
            if arguments.first == "exec" {
                if value == "--" || (execContainerSeen && !value.hasPrefix("-")) {
                    arguments.append(value)
                    arguments.append(contentsOf: rest)
                    break
                }
                if ContainerCommands.execValueOptions.contains(value) {
                    arguments.append(value)
                    if let optionValue = rest.popFirst() { arguments.append(optionValue) }
                    continue
                }
                if !value.hasPrefix("-") { execContainerSeen = true }
            }
            switch value {
            case "--json": json = true
            case "--no-color": noColor = true
            case "--cli" where !rest.isEmpty: cliPath = rest.removeFirst()
            default: arguments.append(value)
            }
        }
    }
}

struct ParsedArgs {
    let positionals: [String]
    private let flags: Set<String>
    private let options: [String: [String]]

    init(
        positionals: [String], flags: Set<String> = [], options: [String: [String]] = [:]
    ) {
        self.positionals = positionals
        self.flags = flags
        self.options = options
    }

    func has(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { options[name]?.last }
    func value(_ name: String, default fallback: String) -> String { options[name]?.last ?? fallback }
    func values(_ name: String) -> [String] { options[name] ?? [] }
    func intValue(_ name: String, default fallback: Int) -> Int {
        guard let raw = options[name]?.last, let parsed = Int(raw) else { return fallback }
        return parsed
    }
    func doubleValue(_ name: String) -> Double? {
        options[name]?.last.flatMap(Double.init)
    }
    func requirePositional(_ index: Int, _ label: String) throws -> String {
        guard index < positionals.count else {
            throw UsageError(message: "missing <\(label)>")
        }
        return positionals[index]
    }
}

/// `aliases` maps alternate spellings (usually short flags) onto a declared
/// name, so `-a` and `--all` both read back as `has("--all")`. Only flag
/// positions are rewritten — never positionals or anything after `--`, so a
/// container command's own `-e` or `-u` passes through untouched.
func parseArgs(
    _ args: [String], boolFlags: Set<String>, valueFlags: Set<String>,
    aliases: [String: String] = [:], commandName: String, passthroughAfter: Int? = nil
) throws -> ParsedArgs {
    var positionals: [String] = []
    var flags = Set<String>()
    var options = [String: [String]]()
    var index = 0
    var onlyPositionals = false

    while index < args.count {
        let arg = args[index]
        if onlyPositionals || arg == "-" || !arg.hasPrefix("-") {
            positionals.append(arg)
            if positionals.count == passthroughAfter { onlyPositionals = true }
            index += 1
            continue
        }
        if arg == "--" {
            onlyPositionals = true
            index += 1
            continue
        }
        var name = arg
        var inlineValue: String?
        if let eq = arg.firstIndex(of: "=") {
            name = String(arg[arg.startIndex..<eq])
            inlineValue = String(arg[arg.index(after: eq)...])
        }
        let spelled = name
        name = aliases[name] ?? name
        if name == spelled, inlineValue == nil, !name.hasPrefix("--"), name.count > 2 {
            let shortFlags = name.dropFirst().compactMap { aliases["-" + String($0)] }
            if shortFlags.count == name.count - 1 && shortFlags.allSatisfy(boolFlags.contains) {
                flags.formUnion(shortFlags)
                index += 1
                continue
            }
        }
        guard boolFlags.contains(name) || valueFlags.contains(name) else {
            throw UsageError(message: "\(commandName): unknown flag \(spelled)")
        }
        if valueFlags.contains(name) {
            if let inlineValue {
                options[name, default: []].append(inlineValue)
            } else {
                index += 1
                guard index < args.count else {
                    throw UsageError(message: "\(commandName): flag \(spelled) requires a value")
                }
                options[name, default: []].append(args[index])
            }
        } else {
            flags.insert(name)
        }
        index += 1
    }
    return ParsedArgs(positionals: positionals, flags: flags, options: options)
}
