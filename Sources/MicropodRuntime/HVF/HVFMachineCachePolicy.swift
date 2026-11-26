import Foundation
import MicropodCore

/// The machine-wide dependency-cache policy: the optional `cache` section
/// of machine.json, rendered for the guest engine as
/// `<root>/run/guest-config/cache-policy.json`.
///
/// The guest engine attaches the caches of every container started through
/// the machine's Docker socket by this policy; per container, the labels
/// `io.micropod.cache` and `io.micropod.cache.scope` refine it. Keys this
/// host does not know are kept in machine.json and passed to the guest as
/// they are, so a newer guest's settings survive an older CLI.
///
/// ```json
/// {
///   "allowedScopes" : ["*"],
///   "buildkit" : { "registerBuildx" : false },
///   "defaultScope" : "default",
///   "goTrimpath" : true,
///   "mode" : "auto",
///   "pnpmLegacyEnv" : true,
///   "tools" : ["gomod", "gobuild", "npm", "pnpm", "yarn", "yarnberry", "pip", "uv", "cargo", "corepack"],
///   "version" : 1
/// }
/// ```
public struct HVFMachineCachePolicy: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// The rendered file's name in `HVFMachineLayout.guestConfigDirectory`.
    public static let fileName = "cache-policy.json"

    public enum Mode: String, Codable, Sendable, Equatable, CaseIterable {
        /// Attach every enabled tool's cache to every container.
        case auto
        /// Attach nothing, whatever a container asks for.
        case off
    }

    /// `buildkit` settings: what `machine start` does about BuildKit.
    public struct BuildKit: Codable, Sendable, Equatable {
        /// `machine start` installs the fallback buildx builder
        /// (`machine builder install`) when the engine cannot serve
        /// `docker build` on its Docker socket.
        public var registerBuildx: Bool
        /// Unknown keys, passed through.
        public var extra: [String: JSONValue]

        public init(registerBuildx: Bool = false, extra: [String: JSONValue] = [:]) {
            self.registerBuildx = registerBuildx
            self.extra = extra
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: HVFJSONKey.self)
            registerBuildx = try c.decodeIfPresent(Bool.self, forKey: HVFJSONKey("registerBuildx")) ?? false
            extra = try HVFJSONKey.unknown(in: c, known: ["registerBuildx"])
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: HVFJSONKey.self)
            try c.encode(registerBuildx, forKey: HVFJSONKey("registerBuildx"))
            for (key, value) in extra { try c.encode(value, forKey: HVFJSONKey(key)) }
        }
    }

    /// The guest engine's cache kinds, in its table order.
    public static let toolKinds = [
        "gomod", "gobuild", "npm", "pnpm", "yarn", "yarnberry", "pip", "uv", "cargo", "corepack",
        "maven", "gradle", "bun", "sccache", "playwright",
    ]
    /// Names that stand for several kinds.
    public static let toolGroups: [String: [String]] = ["go": ["gomod", "gobuild"]]
    /// Every name a tool list may use: the kinds and the groups.
    public static var toolNames: [String] { ["go"] + toolKinds }

    public var version: Int
    public var mode: Mode
    /// The scope a container without one gets. "" attaches caches only to
    /// containers that name a scope.
    public var defaultScope: String
    /// Scopes containers may name: exact names, or a prefix ending in `*`
    /// (`"*"` allows every scope). A disallowed scope fails the create
    /// (HTTP 400) rather than falling back.
    public var allowedScopes: [String]
    /// The kinds (or groups) that attach; the rendered file names kinds only.
    public var tools: [String]
    /// Append ` -trimpath` to GOFLAGS when the Go build cache attaches.
    public var goTrimpath: Bool
    /// Also set `npm_config_store_dir`, which pnpm 9 and 10 read (pnpm 11
    /// and later read only `pnpm_config_store_dir`).
    public var pnpmLegacyEnv: Bool
    /// Fleet L0 sharing: share verified content-addressed downloads (gomod,
    /// npm, pnpm, yarn, pip, uv, cargo, corepack) in scope `global` even when
    /// containers specify a project scope, keeping L1 build caches scoped.
    public var sharedL0: Bool
    /// Optional L0 rig Go proxy URL (e.g. `http://10.43.0.1:5555/go,direct`).
    public var goProxy: String?
    /// Optional L0 rig npm registry URL (e.g. `http://10.43.0.1:5555/npm`).
    public var npmRegistry: String?
    /// Optional total cache byte ceiling enforced by the bounded LRU janitor.
    public var maxBytes: UInt64?
    /// Optional idle age cap in days enforced by the bounded LRU janitor.
    public var maxAgeDays: Int?
    /// Optional free-space floor on the guest cache filesystem triggering
    /// pressure-responsive LRU eviction.
    public var minFreeBytes: UInt64?
    public var buildkit: BuildKit
    /// Unknown keys, passed through to machine.json and the guest.
    public var extra: [String: JSONValue]

    public init(
        version: Int = HVFMachineCachePolicy.currentVersion, mode: Mode = .auto, defaultScope: String = "default",
        allowedScopes: [String] = ["*"], tools: [String] = HVFMachineCachePolicy.toolKinds, goTrimpath: Bool = true,
        pnpmLegacyEnv: Bool = true, sharedL0: Bool = false, goProxy: String? = nil, npmRegistry: String? = nil,
        maxBytes: UInt64? = nil, maxAgeDays: Int? = nil, minFreeBytes: UInt64? = nil,
        buildkit: BuildKit = BuildKit(), extra: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.mode = mode
        self.defaultScope = defaultScope
        self.allowedScopes = allowedScopes
        self.tools = tools
        self.goTrimpath = goTrimpath
        self.pnpmLegacyEnv = pnpmLegacyEnv
        self.sharedL0 = sharedL0
        self.goProxy = goProxy
        self.npmRegistry = npmRegistry
        self.maxBytes = maxBytes
        self.maxAgeDays = maxAgeDays
        self.minFreeBytes = minFreeBytes
        self.buildkit = buildkit
        self.extra = extra
    }

    static let knownKeys: Set<String> = [
        "version", "mode", "defaultScope", "allowedScopes", "tools", "goTrimpath", "pnpmLegacyEnv",
        "sharedL0", "goProxy", "npmRegistry", "maxBytes", "maxAgeDays", "minFreeBytes", "buildkit",
    ]

    /// Missing keys take their defaults, like the rest of machine.json.
    public init(from decoder: any Decoder) throws {
        let defaults = HVFMachineCachePolicy()
        let c = try decoder.container(keyedBy: HVFJSONKey.self)
        func key(_ name: String) -> HVFJSONKey { HVFJSONKey(name) }
        version = try c.decodeIfPresent(Int.self, forKey: key("version")) ?? defaults.version
        if let raw = try c.decodeIfPresent(String.self, forKey: key("mode")) {
            guard let mode = Mode(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key("mode"), in: c, debugDescription: "cache mode must be auto or off, got '\(raw)'")
            }
            self.mode = mode
        } else {
            mode = defaults.mode
        }
        defaultScope = try c.decodeIfPresent(String.self, forKey: key("defaultScope")) ?? defaults.defaultScope
        allowedScopes = try c.decodeIfPresent([String].self, forKey: key("allowedScopes")) ?? defaults.allowedScopes
        tools = try c.decodeIfPresent([String].self, forKey: key("tools")) ?? defaults.tools
        goTrimpath = try c.decodeIfPresent(Bool.self, forKey: key("goTrimpath")) ?? defaults.goTrimpath
        pnpmLegacyEnv = try c.decodeIfPresent(Bool.self, forKey: key("pnpmLegacyEnv")) ?? defaults.pnpmLegacyEnv
        sharedL0 = try c.decodeIfPresent(Bool.self, forKey: key("sharedL0")) ?? defaults.sharedL0
        goProxy = try c.decodeIfPresent(String.self, forKey: key("goProxy")).flatMap { $0.isEmpty ? nil : $0 }
        npmRegistry = try c.decodeIfPresent(String.self, forKey: key("npmRegistry")).flatMap { $0.isEmpty ? nil : $0 }
        maxBytes = try c.decodeIfPresent(UInt64.self, forKey: key("maxBytes")).flatMap { $0 > 0 ? $0 : nil }
        maxAgeDays = try c.decodeIfPresent(Int.self, forKey: key("maxAgeDays")).flatMap { $0 > 0 ? $0 : nil }
        minFreeBytes = try c.decodeIfPresent(UInt64.self, forKey: key("minFreeBytes")).flatMap { $0 > 0 ? $0 : nil }
        buildkit = try c.decodeIfPresent(BuildKit.self, forKey: key("buildkit")) ?? defaults.buildkit
        extra = try HVFJSONKey.unknown(in: c, known: Self.knownKeys)
    }

    /// As machine.json keeps it: `tools` exactly as configured.
    public func encode(to encoder: any Encoder) throws {
        try encode(to: encoder, tools: tools)
    }

    private func encode(to encoder: any Encoder, tools: [String]) throws {
        var c = encoder.container(keyedBy: HVFJSONKey.self)
        try c.encode(version, forKey: HVFJSONKey("version"))
        try c.encode(mode.rawValue, forKey: HVFJSONKey("mode"))
        try c.encode(defaultScope, forKey: HVFJSONKey("defaultScope"))
        try c.encode(allowedScopes, forKey: HVFJSONKey("allowedScopes"))
        try c.encode(tools, forKey: HVFJSONKey("tools"))
        try c.encode(goTrimpath, forKey: HVFJSONKey("goTrimpath"))
        try c.encode(pnpmLegacyEnv, forKey: HVFJSONKey("pnpmLegacyEnv"))
        if sharedL0 { try c.encode(sharedL0, forKey: HVFJSONKey("sharedL0")) }
        if let goProxy, !goProxy.isEmpty { try c.encode(goProxy, forKey: HVFJSONKey("goProxy")) }
        if let npmRegistry, !npmRegistry.isEmpty { try c.encode(npmRegistry, forKey: HVFJSONKey("npmRegistry")) }
        if let maxBytes, maxBytes > 0 { try c.encode(maxBytes, forKey: HVFJSONKey("maxBytes")) }
        if let maxAgeDays, maxAgeDays > 0 { try c.encode(maxAgeDays, forKey: HVFJSONKey("maxAgeDays")) }
        if let minFreeBytes, minFreeBytes > 0 { try c.encode(minFreeBytes, forKey: HVFJSONKey("minFreeBytes")) }
        try c.encode(buildkit, forKey: HVFJSONKey("buildkit"))
        for (name, value) in extra where !Self.knownKeys.contains(name) {
            try c.encode(value, forKey: HVFJSONKey(name))
        }
    }

    // MARK: Validation

    /// `^[a-z0-9][a-z0-9_-]{0,62}$`, the guest engine's scope grammar.
    public static func isValidScope(_ scope: String) -> Bool {
        let bytes = Array(scope.utf8)
        guard (1...63).contains(bytes.count), isLowerAlphanumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy {
            isLowerAlphanumeric($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
        }
    }

    private static func isLowerAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// `*`, a scope name, or a scope-name prefix followed by `*`.
    public static func isValidScopePattern(_ pattern: String) -> Bool {
        if pattern == "*" { return true }
        guard pattern.hasSuffix("*") else { return isValidScope(pattern) }
        return isValidScope(String(pattern.dropLast()))
    }

    /// Whether `allowedScopes` admits `scope`.
    public func allows(scope: String) -> Bool {
        allowedScopes.contains { pattern in
            if pattern == "*" || pattern == scope { return true }
            return pattern.hasSuffix("*") && scope.hasPrefix(String(pattern.dropLast()))
        }
    }

    /// Expands groups, drops repeats and orders by the guest's table; throws
    /// for a name the guest does not know.
    public static func normalizedTools(_ names: [String]) throws -> [String] {
        var kinds = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let group = toolGroups[name] {
                kinds.formUnion(group)
            } else if toolKinds.contains(name) {
                kinds.insert(name)
            } else {
                throw MicropodError.message(
                    "invalidArgument: hvf cache policy: unknown tool '\(raw)' (known: \(toolNames.joined(separator: ", ")))"
                )
            }
        }
        return toolKinds.filter(kinds.contains)
    }

    public func validate() throws {
        func invalid(_ detail: String) -> MicropodError { .message("invalidArgument: hvf cache policy: \(detail)") }
        guard version == Self.currentVersion else {
            throw MicropodError.message(
                "failedPrecondition: hvf cache policy version \(version) is not supported (want \(Self.currentVersion))"
            )
        }
        if !defaultScope.isEmpty, !Self.isValidScope(defaultScope) {
            throw invalid("default scope '\(defaultScope)' must match ^[a-z0-9][a-z0-9_-]{0,62}$ (or be empty)")
        }
        for pattern in allowedScopes where !Self.isValidScopePattern(pattern) {
            throw invalid("allowed scope '\(pattern)' must be '*', a scope name, or a scope-name prefix ending in '*'")
        }
        // A default scope the allow-list refuses would fail every create.
        if !defaultScope.isEmpty, !allows(scope: defaultScope) {
            throw invalid(
                "default scope '\(defaultScope)' is not in the allowed scopes [\(allowedScopes.joined(separator: ", "))]"
            )
        }
        _ = try Self.normalizedTools(tools)
        if let goProxy, !goProxy.isEmpty {
            let parts = goProxy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty,
                parts.allSatisfy({
                    $0 == "direct" || $0 == "off" || $0.hasPrefix("http://") || $0.hasPrefix("https://")
                })
            else {
                throw invalid("goProxy '\(goProxy)' entries must be http://, https://, direct, or off")
            }
        }
        if let npmRegistry, !npmRegistry.isEmpty {
            guard npmRegistry.hasPrefix("http://") || npmRegistry.hasPrefix("https://") else {
                throw invalid("npmRegistry '\(npmRegistry)' must start with http:// or https://")
            }
        }
        if let maxAgeDays, maxAgeDays < 0 {
            throw invalid("maxAgeDays must be non-negative")
        }
    }

    // MARK: Rendering

    /// The guest engine's copy: this policy with `tools` as kinds in table
    /// order, sorted keys, one trailing newline.
    public func render() throws -> Data {
        try validate()
        let rendered = RenderedPolicy(policy: self, tools: try Self.normalizedTools(tools))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(rendered) + Data("\n".utf8)
    }

    private struct RenderedPolicy: Encodable {
        let policy: HVFMachineCachePolicy
        let tools: [String]
        func encode(to encoder: any Encoder) throws { try policy.encode(to: encoder, tools: tools) }
    }

    /// `caches: …` in `machine status`.
    public var summary: String {
        switch mode {
        case .off: return "off"
        case .auto:
            let scope =
                defaultScope.isEmpty ? "no default scope (only containers naming a scope)" : "scope \(defaultScope)"
            let kinds = (try? Self.normalizedTools(tools)) ?? tools
            let which = kinds == Self.toolKinds ? "" : ", tools \(kinds.joined(separator: ","))"
            return "auto, \(scope)\(which)"
        }
    }
}

// MARK: - The rendered file

extension HVFMachineCachePolicy {
    /// Renders the policy machine.json holds now into
    /// `layout.cachePolicyFile` (temporary file + rename, so the guest
    /// reads the old or the new file and never a torn one), creating the
    /// share directory (0700) first. `fallback` stands in when machine.json
    /// cannot be read: a supervisor passes the configuration it booted with.
    @discardableResult
    public static func writeGuestFile(layout: HVFMachineLayout, fallback: HVFMachineConfig? = nil) throws
        -> HVFMachineCachePolicy
    {
        let config: HVFMachineConfig
        if let fallback {
            config = (try? HVFMachineConfig.load(from: layout.config)) ?? fallback
        } else {
            config = try HVFMachineConfig.load(from: layout.config)
        }
        let policy = config.effectiveCachePolicy
        try write(policy, layout: layout)
        return policy
    }

    public static func write(_ policy: HVFMachineCachePolicy, layout: HVFMachineLayout) throws {
        let directory = layout.guestConfigDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard chmod(directory.path, 0o700) == 0 else { throw HVFFiles.posixError("chmod \(directory.path)") }
        try HVFFiles.writeAtomically(try policy.render(), to: layout.cachePolicyFile)
    }
}

// MARK: - Dynamic JSON keys

/// A coding key for objects whose keys are not all known up front.
struct HVFJSONKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// Every key of `container` outside `known`, as loose JSON.
    static func unknown(in container: KeyedDecodingContainer<HVFJSONKey>, known: Set<String>) throws
        -> [String: JSONValue]
    {
        var extra: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extra
    }
}
