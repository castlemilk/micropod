import Foundation
import MicropodCore

/// How a merged listing says where a volume came from. `Micropod_V1_Volume`
/// has no runtime field, so a volume kept by an engine other than Apple's
/// carries this label in listings; Apple's volumes are listed exactly as
/// the Apple runtime reports them.
public enum RuntimeStamp {
    public static let volumeLabel = "com.micropod.runtime"

    /// The runtime a listed volume came from ("apple" when unstamped).
    public static func runtime(of volume: Micropod_V1_Volume) -> String {
        volume.labels[volumeLabel] ?? "apple"
    }
}

/// Where one volume or image call goes.
enum ResourceTarget<Store: Sendable>: Sendable {
    case apple
    case engine(name: String, store: Store)

    var name: String {
        switch self {
        case .apple: "apple"
        case .engine(let name, _): name
        }
    }
}

/// Engine selection shared by `VolumeRouter` and `ImageRouter`, mirroring
/// `RuntimeRouter`: a call that makes something takes the requested
/// runtime, else the default one; a call on an existing name goes to the
/// engine that has it. With no other engine enabled that keeps `what`,
/// every call goes straight to Apple, as before routing existed.
struct ResourceRouting<Store: Sendable>: Sendable {
    /// nil: this process routes nothing (`MICROPOD_ENGINES=apple`, a
    /// dedicated runtime account).
    let registry: EngineRegistry?
    let store: @Sendable (any RuntimeEngine) -> Store?
    /// "volumes" or "images", for messages.
    let what: String

    var defaultName: String { registry?.defaultName ?? "apple" }

    /// Enabled non-Apple engines that keep `what`, in routing order.
    func engines() -> [(name: String, store: Store)] {
        guard let registry else { return [] }
        return registry.extraEngines().compactMap { engine in store(engine).map { (engine.name, $0) } }
    }

    /// `runtime`, validated like `RuntimeRouter.target`. With none named,
    /// the default engine when it keeps `what`; otherwise Apple, where
    /// these calls always went.
    func target(_ runtime: String?) async throws -> ResourceTarget<Store> {
        if let runtime, !runtime.isEmpty {
            return try await named(runtime)
        }
        guard let (name, engine, store) = defaultEngine() else { return .apple }
        try await requireAvailable(engine)
        return .engine(name: name, store: store)
    }

    /// The default runtime when it is an engine that keeps `what`.
    private func defaultEngine() -> (String, any RuntimeEngine, Store)? {
        let name = defaultName
        guard name != "apple", let registry, let engine = registry.engine(name), let store = store(engine)
        else { return nil }
        return (name, engine, store)
    }

    /// True when `target(runtime)` is Apple without asking anything: no
    /// runtime named and the default keeps no `what` of its own. Streams
    /// then come straight from Apple's service, exactly as before routing.
    func targetsApple(_ runtime: String?) -> Bool {
        (runtime ?? "").isEmpty && defaultEngine() == nil
    }

    /// True when no other engine could own a name: by-name calls are Apple's.
    func ownersAreApple(_ runtime: String?) -> Bool {
        (runtime ?? "").isEmpty && engines().isEmpty
    }

    /// The engine `runtime` names, enabled and keeping `what`.
    func named(_ runtime: String) async throws -> ResourceTarget<Store> {
        if runtime == "apple" { return .apple }
        guard let registry else {
            throw MicropodError.message(
                "failedPrecondition: runtime '\(runtime)' is not routed by this process (it manages the apple "
                    + "runtime only)")
        }
        guard let engine = registry.engine(runtime) else {
            throw MicropodError.message(
                "failedPrecondition: unknown runtime '\(runtime)' (known: "
                    + "\(EngineRegistry.engineNames.joined(separator: ", ")))")
        }
        guard registry.isEnabled(runtime) else {
            throw MicropodError.message(
                "failedPrecondition: runtime '\(runtime)' is disabled — enable it with UpdateRuntime")
        }
        guard let store = store(engine) else {
            throw MicropodError.unsupported("runtime '\(runtime)' does not keep \(what) of its own")
        }
        try await requireAvailable(engine)
        return .engine(name: runtime, store: store)
    }

    private func requireAvailable(_ engine: any RuntimeEngine) async throws {
        let probe = await engine.probe()
        guard probe.available else {
            throw MicropodError.message("failedPrecondition: runtime '\(engine.name)' unavailable: \(probe.reason)")
        }
    }

    /// The engine that has `name`: the named runtime when one is given;
    /// else the default runtime if it has it; else the first other engine
    /// that has it (non-Apple engines in routing order, then Apple). With
    /// no owner the default runtime answers — Apple, unless the default is
    /// an engine that keeps `what` — with its own "not found". Apple is
    /// asked (a listing) only when that changes the outcome.
    func owner(
        _ name: String, runtime: String?, owns: (Store, String) async -> Bool, appleOwns: () async -> Bool
    ) async throws -> ResourceTarget<Store> {
        if let runtime, !runtime.isEmpty { return try await named(runtime) }
        let engines = engines()
        guard !engines.isEmpty else { return .apple }
        var owners: [(name: String, store: Store)] = []
        for engine in engines where await owns(engine.store, name) { owners.append(engine) }
        let preferred = defaultName
        if let owner = owners.first(where: { $0.name == preferred }) {
            return .engine(name: owner.name, store: owner.store)
        }
        if preferred == "apple" {
            guard let other = owners.first, await !appleOwns() else { return .apple }
            return .engine(name: other.name, store: other.store)
        }
        if let other = owners.first { return .engine(name: other.name, store: other.store) }
        if await appleOwns() { return .apple }
        if let fallback = engines.first(where: { $0.name == preferred }) {
            return .engine(name: fallback.name, store: fallback.store)
        }
        return .apple
    }

    /// Apple's listing merged with every other engine's, best-effort like
    /// `RuntimeRouter.list`: a failure of Apple's is the listing's failure
    /// unless another engine is the default and Apple is merely down.
    func merged<Item: Sendable>(
        runtime: String?, apple: () async throws -> [Item], engine: (Store) async throws -> [Item]
    ) async throws -> [(runtime: String, item: Item)] {
        if let runtime, !runtime.isEmpty {
            switch try await named(runtime) {
            case .apple: return try await apple().map { ("apple", $0) }
            case .engine(let name, let store): return try await engine(store).map { (name, $0) }
            }
        }
        var all: [(runtime: String, item: Item)] = []
        do {
            all = try await apple().map { ("apple", $0) }
        } catch {
            guard defaultName != "apple", RuntimeRouter.appleRuntimeIsDown(error) else { throw error }
        }
        for (name, store) in engines() {
            guard let listed = try? await engine(store) else { continue }
            all += listed.map { (name, $0) }
        }
        return all
    }
}

// MARK: - Volumes

/// `VolumeServing` over Apple's volume service and every enabled engine
/// that keeps volumes of its own (docker, hvf). Listings merge and stamp
/// the non-Apple entries (`RuntimeStamp.volumeLabel`); create goes to the
/// requested or default runtime; delete to the engine that has the name;
/// prune to every engine that can. Clones are Apple's alone.
public struct VolumeRouter: VolumeServing {
    public let apple: any VolumeServing
    let routing: ResourceRouting<any EngineVolumeServing>

    /// `registry` nil routes nothing: every call is Apple's.
    public init(apple: any VolumeServing, registry: EngineRegistry?) {
        self.apple = apple
        routing = ResourceRouting(registry: registry, store: { $0.volumeStore }, what: "volumes")
    }

    public func list() async throws -> [Micropod_V1_Volume] { try await list(runtime: nil) }

    /// One runtime's volumes when `runtime` is given.
    public func list(runtime: String?) async throws -> [Micropod_V1_Volume] {
        try await routing.merged(runtime: runtime, apple: { try await apple.list() }, engine: { try await $0.list() })
            .map { entry in
                guard entry.runtime != "apple" else { return entry.item }
                var volume = entry.item
                volume.labels[RuntimeStamp.volumeLabel] = entry.runtime
                return volume
            }
    }

    public func create(name: String, size: String?, labels: [String], options: [String]) async throws {
        try await create(name: name, size: size, labels: labels, options: options, runtime: nil)
    }

    public func create(name: String, size: String?, labels: [String], options: [String], runtime: String?)
        async throws
    {
        switch try await routing.target(runtime) {
        case .apple:
            try await apple.create(name: name, size: size, labels: labels, options: options)
        case .engine(_, let store):
            let labels = labels.filter { !$0.hasPrefix(RuntimeStamp.volumeLabel + "=") }
            try await store.create(name: name, size: size, labels: labels, options: options)
        }
    }

    public func delete(_ name: String) async throws { try await delete(name, runtime: nil) }

    public func delete(_ name: String, runtime: String?) async throws {
        switch try await owner(name, runtime: runtime) {
        case .apple: try await apple.delete(name)
        case .engine(_, let store): try await store.delete(name)
        }
    }

    /// Which runtime `delete` would act on.
    public func runtime(of name: String, requested: String? = nil) async throws -> String {
        try await owner(name, runtime: requested).name
    }

    private func owner(_ name: String, runtime: String?) async throws -> ResourceTarget<any EngineVolumeServing> {
        try await routing.owner(
            name, runtime: runtime, owns: { await $0.owns($1) },
            appleOwns: { (try? await apple.list())?.contains { $0.id == name } ?? false })
    }

    /// Apple's prune, then each other engine's that has one (an engine
    /// without prune is skipped), one report line per engine.
    public func prune() async throws -> String { try await prune(runtime: nil) }

    public func prune(runtime: String?) async throws -> String {
        if let runtime, !runtime.isEmpty {
            switch try await routing.named(runtime) {
            case .apple: return try await apple.prune()
            case .engine(_, let store): return try await store.prune()
            }
        }
        var reports = [try await apple.prune()]
        for (name, store) in routing.engines() {
            if let report = try? await store.prune(), !report.isEmpty { reports.append("\(name): \(report)") }
        }
        return reports.joined(separator: "\n")
    }

    public func clone(source: String, name: String, size: String?, labels: [String]) async throws
        -> Micropod_V1_Volume
    {
        try requireApple(try await owner(source, runtime: nil), "volume clones")
        return try await apple.clone(source: source, name: name, size: size, labels: labels)
    }

    public func commitClone(containerID: String, volume: String) async throws -> UInt64 {
        try requireApple(try await owner(volume, runtime: nil), "volume clones")
        return try await apple.commitClone(containerID: containerID, volume: volume)
    }

    private func requireApple(_ target: ResourceTarget<any EngineVolumeServing>, _ what: String) throws {
        guard case .engine(let name, _) = target else { return }
        throw MicropodError.unsupported("runtime '\(name)' does not support \(what) (they are Apple runtime only)")
    }
}

// MARK: - Images

/// `ImageServing` over Apple's image service and every enabled engine that
/// keeps images of its own. Listings merge (`listByRuntime` says where each
/// came from — `Micropod_V1_Image` has no field for it); pull and load go
/// to the requested or default runtime; by-reference calls to the engine
/// that has the image. Push, save, load and build stay Apple's unless an
/// engine is named, which then refuses them as unsupported.
public struct ImageRouter: ImageServing {
    public let apple: any ImageServing
    let routing: ResourceRouting<any EngineImageServing>

    public init(apple: any ImageServing, registry: EngineRegistry?) {
        self.apple = apple
        routing = ResourceRouting(registry: registry, store: { $0.imageStore }, what: "images")
    }

    public struct Listed: Sendable, Equatable {
        public let runtime: String
        public let image: Micropod_V1_Image
    }

    public func listByRuntime(runtime: String? = nil) async throws -> [Listed] {
        try await routing.merged(runtime: runtime, apple: { try await apple.list() }, engine: { try await $0.list() })
            .map { Listed(runtime: $0.runtime, image: $0.item) }
    }

    public func list() async throws -> [Micropod_V1_Image] { try await listByRuntime().map(\.image) }

    // MARK: Pull

    public func pull(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        pull(reference, platform: platform, runtime: nil)
    }

    public func pull(_ reference: String, platform: String?, runtime: String?)
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        if routing.targetsApple(runtime) { return apple.pull(reference, platform: platform) }
        return routed { router in
            switch try await router.routing.target(runtime) {
            case .apple: return router.apple.pull(reference, platform: platform)
            case .engine(_, let store): return store.pull(reference, platform: platform)
            }
        }
    }

    /// Apple's pull keeps its API budget semantics; another engine's pull
    /// is one attempt, cancelled at the caller's deadline.
    public func pullForAPI(_ reference: String, platform: String?, budget: ImagePullBudget, runtime: String?)
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        if routing.targetsApple(runtime) { return applePullForAPI(reference, platform: platform, budget: budget) }
        return routed { router in
            switch try await router.routing.target(runtime) {
            case .apple:
                return router.applePullForAPI(reference, platform: platform, budget: budget)
            case .engine(_, let store):
                return Self.bounded(
                    store.pull(reference, platform: platform), by: budget.deadline, reference: reference)
            }
        }
    }

    private func applePullForAPI(_ reference: String, platform: String?, budget: ImagePullBudget)
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        guard let service = apple as? ImageService else { return apple.pull(reference, platform: platform) }
        return service.pullForAPI(reference, platform: platform, budget: budget)
    }

    static func bounded(_ inner: AsyncThrowingStream<ProgressEvent, Error>, by deadline: Date?, reference: String)
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        guard let deadline else { return inner }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in inner { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let timer = Task {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { try? await Task.sleep(for: .milliseconds(Int64(remaining * 1000))) }
                guard !Task.isCancelled else { return }
                task.cancel()
                continuation.finish(
                    throwing: MicropodError.message("deadlineExceeded: pull of \(reference) passed its deadline"))
            }
            continuation.onTermination = { _ in
                task.cancel()
                timer.cancel()
            }
        }
    }

    /// A stream whose source is chosen asynchronously.
    private func routed(
        _ choose: @escaping @Sendable (ImageRouter) async throws -> AsyncThrowingStream<ProgressEvent, Error>
    )
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        let router = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in try await choose(router) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: By reference

    private func owner(_ reference: String, runtime: String?) async throws -> ResourceTarget<any EngineImageServing> {
        try await routing.owner(
            reference, runtime: runtime, owns: { await $0.owns($1) },
            appleOwns: {
                guard let images = try? await apple.list() else { return false }
                return images.contains { $0.id == reference }
                    || localImageIsPresent(reference, in: localImageReferenceInventory(from: images))
            })
    }

    /// Which runtime a by-reference call on `reference` would act on.
    public func runtime(of reference: String, requested: String? = nil) async throws -> String {
        try await owner(reference, runtime: requested).name
    }

    public func delete(_ reference: String, force: Bool) async throws {
        try await delete(reference, force: force, runtime: nil)
    }

    public func delete(_ reference: String, force: Bool, runtime: String?) async throws {
        switch try await owner(reference, runtime: runtime) {
        case .apple: try await apple.delete(reference, force: force)
        case .engine(_, let store): try await store.delete(reference, force: force)
        }
    }

    public func tag(source: String, target: String) async throws {
        try await tag(source: source, target: target, runtime: nil)
    }

    public func tag(source: String, target: String, runtime: String?) async throws {
        switch try await owner(source, runtime: runtime) {
        case .apple: try await apple.tag(source: source, target: target)
        case .engine(_, let store): try await store.tag(source: source, target: target)
        }
    }

    public func inspect(_ reference: String) async throws -> Data { try await inspect(reference, runtime: nil) }

    public func inspect(_ reference: String, runtime: String?) async throws -> Data {
        switch try await owner(reference, runtime: runtime) {
        case .apple: return try await apple.inspect(reference)
        case .engine(_, let store): return try await store.inspect(reference)
        }
    }

    public func prune(danglingOnly: Bool) async throws -> String {
        try await prune(danglingOnly: danglingOnly, runtime: nil)
    }

    /// Apple's prune, then each other engine's that has one.
    public func prune(danglingOnly: Bool, runtime: String?) async throws -> String {
        if let runtime, !runtime.isEmpty {
            switch try await routing.named(runtime) {
            case .apple: return try await apple.prune(danglingOnly: danglingOnly)
            case .engine(_, let store): return try await store.prune(danglingOnly: danglingOnly)
            }
        }
        var reports = [try await apple.prune(danglingOnly: danglingOnly)]
        for (name, store) in routing.engines() {
            if let report = try? await store.prune(danglingOnly: danglingOnly), !report.isEmpty {
                reports.append("\(name): \(report)")
            }
        }
        return reports.joined(separator: "\n")
    }

    // MARK: Apple-only operations

    /// Refuses a named non-Apple runtime for `operation`.
    private func requireApple(_ runtime: String?, _ operation: String) async throws {
        guard let runtime, !runtime.isEmpty, runtime != "apple" else { return }
        let target = try await routing.named(runtime)
        throw MicropodError.unsupported("runtime '\(target.name)' does not support \(operation)")
    }

    /// The owner of `reference` must be Apple.
    private func requireAppleOwner(_ reference: String, runtime: String?, _ operation: String) async throws {
        try await requireApple(runtime, operation)
        if case .engine(let name, _) = try await owner(reference, runtime: runtime) {
            throw MicropodError.unsupported("runtime '\(name)' does not support \(operation)")
        }
    }

    public func push(_ reference: String, platform: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        push(reference, platform: platform, runtime: nil)
    }

    public func push(_ reference: String, platform: String?, runtime: String?)
        -> AsyncThrowingStream<ProgressEvent, Error>
    {
        if routing.ownersAreApple(runtime) { return apple.push(reference, platform: platform) }
        return routed { router in
            try await router.requireAppleOwner(reference, runtime: runtime, "image push")
            return router.apple.push(reference, platform: platform)
        }
    }

    public func build(_ request: ContainerBuildRequest) -> AsyncThrowingStream<ProgressEvent, Error> {
        build(request, runtime: nil)
    }

    /// No other engine builds yet, so an unnamed build stays Apple's even
    /// when another engine is the default (as before routing).
    public func build(_ request: ContainerBuildRequest, runtime: String?) -> AsyncThrowingStream<ProgressEvent, Error> {
        if (runtime ?? "").isEmpty || runtime == "apple" { return apple.build(request) }
        return routed { router in
            try await router.requireApple(runtime, "build")
            return router.apple.build(request)
        }
    }

    public func save(_ reference: String, to outputPath: String) async throws {
        try await save(reference, to: outputPath, runtime: nil)
    }

    public func save(_ reference: String, to outputPath: String, runtime: String?) async throws {
        try await requireAppleOwner(reference, runtime: runtime, "image save")
        try await apple.save(reference, to: outputPath)
    }

    public func saveAll(_ references: [String], to outputPath: String) async throws {
        for reference in references { try await requireAppleOwner(reference, runtime: nil, "image save") }
        try await apple.saveAll(references, to: outputPath)
    }

    public func load(from inputPath: String) async throws { try await load(from: inputPath, runtime: nil) }

    /// Like build: unnamed loads stay Apple's.
    public func load(from inputPath: String, runtime: String?) async throws {
        try await requireApple(runtime, "image load")
        try await apple.load(from: inputPath)
    }
}
