import Foundation
import MicropodCore

/// Polls the runtime container list and synthesizes Docker-shaped events
/// (create/start/die/destroy) for /events subscribers, drives AutoRemove,
/// and records exit codes for wait conditions. The Apple CLI has no native
/// event stream, so a 500 ms diff poll is the compat surface.
actor EventsHub {
    typealias SubscriberID = UUID

    struct Subscription {
        let id: UUID
        let filters: [String: [String]]
        let continuation: AsyncStream<Data>.Continuation
    }

    private let containers: any ContainerServing
    private var subscriptions: [Subscription] = []
    private var known: [String: Observation] = [:]
    private let interval: Double

    struct Observation: Equatable {
        var state: String
        var image: String
        var labels: [String: String]
    }

    init(containers: any ContainerServing, interval: Double = 0.5) {
        self.containers = containers
        self.interval = interval
    }

    func start(state: ShimState) async {
        if let initial = try? await containers.list() {
            known = observe(initial)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            // Quiesce: with no /events subscribers, no AutoRemove containers
            // and no restart policies to supervise, polling is pure
            // background CLI load.
            let autoRemoveCount = await state.autoRemoveContainerIDs.count
            let supervisingRestarts = await state.hasRestartPolicies
            guard !subscriptions.isEmpty || autoRemoveCount > 0 || supervisingRestarts else {
                continue
            }
            guard let current = try? await containers.list() else { continue }
            await reconcile(current, state: state)
        }
    }

    func subscribe(filters: [String: [String]]) async -> (UUID, AsyncStream<Data>) {
        let id = UUID()
        // Snapshot BEFORE registering: a container created while this list is
        // in flight stays unknown to reconcile and correctly surfaces as a
        // create event; one in the snapshot is silently absorbed as
        // pre-existing. The reverse order would swallow fresh creates.
        let snapshot = try? await containers.list()
        let stream = AsyncStream<Data> { continuation in
            subscriptions.append(
                Subscription(id: id, filters: filters, continuation: continuation))
        }
        if let snapshot {
            reseed(snapshot)
        }
        return (id, stream)
    }

    private func reseed(_ current: [Micropod_V1_Container]) {
        for entry in current where known[entry.id] == nil {
            known[entry.id] = Observation(
                state: entry.state.lowercased(), image: entry.image, labels: entry.labels)
        }
    }

    func unsubscribe(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
    }

    /// Docker-style restart-policy supervision (the Apple runtime has none).
    /// Honors always / unless-stopped / on-failure with exponential backoff
    /// that resets after 10s of stable running, and MaximumRetryCount.
    private func superviseRestart(id: String, exitCode: Int, state: ShimState) async {
        guard let create = await state.createRequest(for: id),
            let policy = create.HostConfig?.RestartPolicy,
            let name = policy.Name?.lowercased(),
            name != "no", name != ""
        else { return }

        let intentional = await state.isIntentionalStop(id)
        switch name {
        case "always":
            break  // restart even after explicit stop
        case "unless-stopped":
            if intentional { return }
        case "on-failure":
            guard exitCode != 0 else { return }
            if let maxRetries = policy.MaximumRetryCount,
                await state.restartAttemptCount(id) >= maxRetries
            {
                return
            }
        default:
            return
        }

        _ = await state.ranStably(id)
        let delay = await state.nextRestartDelay(id)
        let containers = self.containers
        let hubState = state
        let target = id
        let policyName = name
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard await hubState.isIntentionalStop(target) == false || policyName == "always"
            else { return }
            try? await containers.start(target)
        }
    }

    private func observe(_ list: [Micropod_V1_Container]) -> [String: Observation] {
        var result = [String: Observation]()
        for entry in list {
            result[entry.id] = Observation(
                state: entry.state.lowercased(), image: entry.image, labels: entry.labels)
        }
        return result
    }

    private func reconcile(_ current: [Micropod_V1_Container], state: ShimState) async {
        let observed = observe(current)

        for entry in current {
            let id = entry.id
            let after = observed[id]!
            guard let before = known[id] else {
                await emit("container", "create", after, id: id)
                // A container first observed already exited ran and died
                // entirely between polls — it still needs its die event,
                // restart-policy supervision and AutoRemove reap.
                //
                // The Apple runtime reports "stopped" for a container that was
                // created and never started, exactly as it does for one that
                // ran and exited, so state alone cannot tell them apart. Only
                // `status.startedDate` can. Reaping on state alone deletes a
                // brand-new `--rm` container in the window between the client's
                // create and its start, which then fails with 404.
                let terminal = ["stopped", "exited", "dead"]
                if terminal.contains(after.state),
                    await hasEverStarted(id: id, state: state)
                {
                    await handleExit(entry: entry, observation: after, state: state)
                }
                continue
            }
            guard before.state != after.state else { continue }
            let wasLive = before.state == "running"
            let isLive = after.state == "running"
            if isLive {
                await emit("container", "start", after, id: id)
                await state.noteRunning(id)
                await state.clearIntentionalStop(id)
            } else if wasLive || before.state == "created" || before.state == "creating" {
                await handleExit(entry: entry, observation: after, state: state)
            }
        }
        for (id, before) in known where observed[id] == nil {
            await emit("container", "destroy", before, id: id)
            await state.forget(id: id)
        }
        known = observed
    }

    /// Whether this container ever actually ran.
    ///
    /// Answered from shim state where possible — a container we started has
    /// run; one we created and never started has not — because the alternative
    /// is a `container inspect` process on every poll, which at the events
    /// loop's cadence starves the runtime. Only a container this shim never
    /// created (started out of band) needs the runtime asked.
    private func hasEverStarted(id: String, state: ShimState) async -> Bool {
        // An attached run still in flight has not exited, whatever the runtime
        // currently reports: the container reads "stopped" for the moments
        // between /start and actually running, and reaping on that deletes an
        // AutoRemove container out from under its own run.
        if await state.isAttachRunning(id: id) { return false }
        if await state.hasStarted(id: id) { return true }
        if await state.createRequest(for: id) != nil { return false }
        guard let raw = try? await containers.inspect(id) else { return false }
        return DockerMapper.hasEverStarted(rawInspect: raw)
    }

    /// Die event + exit bookkeeping + restart-policy supervision + the
    /// AutoRemove reap — shared by the observed-transition path and the
    /// "already exited when first seen" path.
    private func handleExit(
        entry: Micropod_V1_Container, observation: Observation, state: ShimState
    ) async {
        let id = entry.id
        // The runtime rarely reports exit codes; treat missing as 0.
        let code = Int(entry.exitCode) ?? 0
        await state.noteExit(id: id, code: code)
        await emit(
            "container", "die", observation, id: id,
            extraAttributes: ["exitCode": "\(code)"])
        await superviseRestart(id: id, exitCode: code, state: state)
        if let create = await state.createRequest(for: id),
            create.HostConfig?.AutoRemove == true,
            await !state.isAttachRunning(id: id)
        {
            try? await containers.delete(id, force: true)
        }
    }

    private func emit(
        _ type: String, _ action: String, _ observation: Observation, id: String,
        extraAttributes: [String: String] = [:]
    ) async {
        let now = Date()
        var attributes = observation.labels
        attributes["image"] = observation.image
        attributes["name"] = id
        for (key, value) in extraAttributes {
            attributes[key] = value
        }
        let event = DockerEvent(
            Type: type, Action: action,
            Actor: DockerEvent.Actor(ID: id, Attributes: attributes),
            time: Int64(now.timeIntervalSince1970),
            timeNano: Int64(now.timeIntervalSince1970 * 1_000_000_000),
            status: action, id: id, from: observation.image)
        guard let data = try? JSONEncoder().encode(event) else { return }
        let line = data + Data("\n".utf8)
        for subscription in subscriptions where matches(subscription.filters, event) {
            subscription.continuation.yield(line)
        }
    }

    private func matches(_ filters: [String: [String]], _ event: DockerEvent) -> Bool {
        for (key, values) in filters {
            switch key {
            case "type":
                if !values.contains(event.Type) { return false }
            case "event":
                if !values.contains(event.Action) { return false }
            case "container":
                if !values.contains(event.id) && !values.contains(event.Actor.ID) { return false }
            case "image":
                if !values.contains(event.from) { return false }
            case "label", "labels":
                for value in values {
                    let parts = value.split(separator: "=", maxSplits: 1)
                    let labelKey = String(parts[0])
                    let expected = parts.count > 1 ? String(parts[1]) : nil
                    guard let actual = event.Actor.Attributes[labelKey] else { return false }
                    if let expected, actual != expected { return false }
                }
            default:
                break
            }
        }
        return true
    }
}
