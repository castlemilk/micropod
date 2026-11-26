import Foundation

/// `micropod run|create --cache … --cache-scope …`, as container labels.
///
/// On the hvf machine the guest engine attaches dependency caches to every
/// container by default and reads its per-container choices from labels,
/// which every Docker client can set:
///
/// | flag | label |
/// |---|---|
/// | `--cache auto`, `--cache off`, `--cache go,npm`, `--cache +cargo,-npm` | `io.micropod.cache` |
/// | `--cache-scope projA` | `io.micropod.cache.scope` |
///
/// A label the request already carries under the same key (or its
/// `com.micropod.cache[.scope]` alias) wins over the flag. Without either
/// flag nothing is added: the default is the guest's.
///
/// Other runtimes have no per-tool caches: `--cache off` becomes the shim's
/// `com.micropod.cache.shared=false`, `--cache auto` adds nothing, and a
/// tool list or a scope is refused.
public enum ContainerCacheOptions {
    public static let label = "io.micropod.cache"
    public static let scopeLabel = "io.micropod.cache.scope"
    /// Aliases the guest reads too; a request carrying one keeps it.
    public static let labelAliases = ["com.micropod.cache"]
    public static let scopeLabelAliases = ["com.micropod.cache.scope"]
    /// The Docker shim's existing off switch, for runtimes other than hvf.
    public static let sharedLabel = "com.micropod.cache.shared"

    /// Names a tool list may use: the group `go` (gomod + gobuild) and the
    /// guest engine's cache kinds.
    public static let tools = [
        "go", "gomod", "gobuild", "npm", "pnpm", "yarn", "yarnberry", "pip", "uv", "cargo", "corepack",
        "maven", "gradle", "bun", "sccache", "playwright",
    ]

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// `auto`, `off`, or a comma list of tools, each optionally prefixed
    /// with `+` (force it on) or `-` (leave it out); lower-cased, spaces
    /// and empty items dropped.
    public static func normalizedCache(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "auto" || value == "off" { return value }
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty else {
            throw Invalid(message: "--cache wants auto, off or a comma list of tools, got '\(raw)'")
        }
        for item in items {
            let name = item.first == "+" || item.first == "-" ? String(item.dropFirst()) : item
            if name == "auto" || name == "off" {
                throw Invalid(message: "--cache \(name) cannot be combined with tool names (got '\(raw)')")
            }
            guard tools.contains(name) else {
                throw Invalid(
                    message: "--cache: unknown tool '\(name)' (known: \(tools.joined(separator: ", ")))")
            }
        }
        return items.joined(separator: ",")
    }

    /// `^[a-z0-9][a-z0-9_-]{0,62}$`, the guest engine's scope grammar.
    public static func isValidScope(_ scope: String) -> Bool {
        let bytes = Array(scope.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        guard (1...63).contains(bytes.count), alphanumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { alphanumeric($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    public static func validatedScope(_ raw: String) throws -> String {
        guard isValidScope(raw) else {
            throw Invalid(
                message: "--cache-scope '\(raw)' must match ^[a-z0-9][a-z0-9_-]{0,62}$ (lower-case letters, digits, "
                    + "'_' and '-'; at most 63)")
        }
        return raw
    }

    /// `request` with its `cache`/`cacheScope` turned into labels for
    /// `runtime` and cleared; unchanged when it sets neither. Throws for an
    /// invalid value, or one `runtime` cannot honour.
    public static func applying(to request: ContainerRunRequest, runtime: String) throws -> ContainerRunRequest {
        guard request.cache != nil || request.cacheScope != nil else { return request }
        let cache = try request.cache.map(normalizedCache)
        let scope = try request.cacheScope.map(validatedScope)
        var request = request
        request.cache = nil
        request.cacheScope = nil
        let present = Set(request.labels.map(\.key))
        func add(_ key: String, _ value: String, aliases: [String]) {
            guard !present.contains(key), !aliases.contains(where: present.contains) else { return }
            request.labels.append(LabelSpec(key: key, value: value))
        }
        if runtime == "hvf" {
            if let cache { add(label, cache, aliases: labelAliases) }
            if let scope { add(scopeLabel, scope, aliases: scopeLabelAliases) }
            return request
        }
        if scope != nil || (cache != nil && cache != "auto" && cache != "off") {
            throw Invalid(
                message: "runtime '\(runtime)' has no per-tool dependency caches: --cache <tools> and --cache-scope "
                    + "need --runtime hvf (--cache auto|off work everywhere)")
        }
        if cache == "off" { add(sharedLabel, "false", aliases: []) }
        return request
    }

    /// `applying(to:runtime:)` for engines: an invalid value is an
    /// `invalidArgument` error.
    public static func admitted(_ request: ContainerRunRequest, runtime: String) throws -> ContainerRunRequest {
        do {
            return try applying(to: request, runtime: runtime)
        } catch let invalid as Invalid {
            throw MicropodError.message("invalidArgument: \(invalid.message)")
        }
    }
}
