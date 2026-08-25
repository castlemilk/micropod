import Foundation

struct UsageError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
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

func parseArgs(
    _ args: [String], boolFlags: Set<String>, valueFlags: Set<String>, commandName: String
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
        guard boolFlags.contains(name) || valueFlags.contains(name) else {
            throw UsageError(message: "\(commandName): unknown flag \(name)")
        }
        if valueFlags.contains(name) {
            if let inlineValue {
                options[name, default: []].append(inlineValue)
            } else {
                index += 1
                guard index < args.count else {
                    throw UsageError(message: "\(commandName): flag \(name) requires a value")
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

func expandAliases(_ args: [String], aliases: [String: String]) -> [String] {
    args.map { aliases[$0] ?? $0 }
}
