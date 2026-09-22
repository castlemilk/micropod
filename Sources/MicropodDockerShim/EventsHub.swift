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

    /// Read-through cache to invalidate on observed transitions (out-of-band
    /// changes from other clients). Nil in unit tests that drive reconcile
    /// directly.
    private let readCache: ReadThroughCache?

    init(containers: any ContainerServing, interval: Double = 0.5, readCache: ReadThroughCache? = nil) {
        self.containers = containers
        self.interval = interval
        self.readCache = readCache
    }

    func start(state: ShimState) async {
        if let initial = try? await containers.list() {
            known = observe(initial)
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            // Quiesce: with no /events subscribers, no AutoRemove containers,
            // no restart policies and no healthchecks to supervise, polling
            // is pure background CLI load.
            let autoRemoveCount = await state.autoRemoveContainerIDs.count
            let supervisingRestarts = await state.hasRestartPolicies
            let supervisingHealth = await state.hasHealthChecks
            let syncingHosts = await state.hasCustomNetworks
            let busy =
                !subscriptions.isEmpty || autoRemoveCount > 0 || supervisingRestarts
                || supervisingHealth || syncingHosts
            guard busy else {
                continue
            }
            guard let current = try? await containers.list() else { continue }
            await reconcile(current, state: state)
            await probeHealthChecks(current: current, state: state)
            await syncHostsFiles(current: current, state: state)
        }
    }

    /// Managed /etc/hosts DNS (custom networks serve no name records):
    /// rewrite each network's hosts file when membership changed. Only
    /// running containers resolve (matching dockerd), named by Docker name,
    /// ids, compose service label and requested aliases.
    private func syncHostsFiles(current: [Micropod_V1_Container], state: ShimState) async {
        var groups: [String: [HostsFile.Member]] = [:]
        for entry in current where entry.state.lowercased() == "running" {
            guard !entry.ipv4Address.isEmpty else { continue }
            let ip = DockerMapper.plainIP(entry.ipv4Address)
            var names = [entry.id, String(entry.id.prefix(12))]
            if let dockerName = await state.dockerName(for: entry.id),
                dockerName != entry.id
            {
                names.insert(dockerName, at: 0)
            }
            if let service = entry.labels["com.docker.compose.service"], !service.isEmpty {
                names.append(service)
            }
            if let create = await state.createRequest(for: entry.id),
                let endpoints = create.NetworkingConfig?.EndpointsConfig
            {
                for (network, settings) in endpoints {
                    if entry.networks.contains(network) {
                        names += settings.Aliases ?? []
                    }
                }
            }
            for network in entry.networks where network != "default" && !network.isEmpty {
                groups[network, default: []].append(HostsFile.Member(ip: ip, names: names))
            }
        }
        let touched = HostsFile.sync(membersByNetwork: groups)
        if !touched.isEmpty {
            fputs("[shim] hosts updated: \(touched.joined(separator: ","))\n", stderr)
        }
    }

    /// Healthcheck probing (the Apple runtime has none): exec due probes for
    /// running supervised containers, sequentially to bound CLI load.
    private func probeHealthChecks(current: [Micropod_V1_Container], state: ShimState) async {
        let runningIDs = Set(
            current.filter { $0.state.lowercased() == "running" }.map(\.id))
        guard !runningIDs.isEmpty else { return }
        let containers = self.containers
        for id in await state.healthDueIDs(runningIDs: runningIDs) {
            guard let spec = await state.healthSpec(id: id) else { continue }
            await probeHealth(id: id, spec: spec, containers: containers, state: state)
        }
    }

    private func probeHealth(
        id: String, spec: ShimState.HealthSpec,
        containers: any ContainerServing, state: ShimState
    ) async {
        await state.noteProbeStarted(id: id, intervalS: spec.intervalS)
        let command: [String]
        switch spec.test.first {
        case "CMD-SHELL":
            command = ["sh", "-c", spec.test.dropFirst().joined(separator: " ")]
        default:
            command = Array(spec.test.dropFirst())  // CMD
        }
        guard !command.isEmpty else {
            await state.recordProbe(id: id, success: true, output: "")
            return
        }
        // Race the exec against the configured timeout: a hung probe counts
        // as failed without stalling cadence, and its late result is dropped
        // rather than recorded out of order. Only the Sendable service
        // crosses into the group; all state access stays outside it.
        let outcome: (Bool, String)? = await withTaskGroup(of: (Bool, String)?.self) { group in
            group.addTask {
                do {
                    let output = try await containers.exec(
                        ContainerExecRequest(containerID: id, arguments: command))
                    return (true, output)
                } catch {
                    if case MicropodError.cliFailure(_, let code, let stderr) = error {
                        return (false, "exit \(code): \(stderr)")
                    }
                    return (false, "\(error)")
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(spec.timeoutS))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let (success, output) = outcome else {
            await state.recordProbe(
                id: id, success: false, output: "probe timed out after \(spec.timeoutS)s")
            return
        }
        await state.recordProbe(id: id, success: success, output: output)
    }

    func subscribe(filters: [String: [String]], state: ShimState) async -> (UUID, AsyncStream<Data>) {
        let id = UUID()
        // Snapshot BEFORE registering: a container created while this list is
        // in flight stays unknown to reconcile and correctly surfaces as a
        // create event; one in the snapshot is silently absorbed as
        // pre-existing. The reverse order would swallow fresh creates.
        let snapshot = try? await containers.list()
        // Eager stream/continuation pair (NOT the lazy trailing-closure
        // form): the continuation must be usable from actor-isolated emit()
        // with no executor/lifetime subtleties in between.
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let subID = id
        // Unsubscribe when the consumer goes away (client disconnect ends
        // handle()'s for-await, firing this): otherwise every /events
        // subscriber leaks permanently — the hub never finishes streams —
        // and the quiesce guard below never sleeps again.
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(subID) }
        }
        subscriptions.append(
            Subscription(id: id, filters: filters, continuation: continuation))
        if let snapshot {
            await reseed(snapshot, state: state)
        }
        return (id, stream)
    }

    /// Absorbs a snapshot as pre-existing state WITHOUT emitting. The Apple
    /// runtime reports a created-never-started container as "stopped",
    /// exactly like an exited one — so for containers THIS shim created but
    /// never started, record `created`: the truth the runtime won't tell.
    /// Otherwise a fast container that runs+exits between polls is absorbed
    /// as stopped, no transition ever fires, no die event is emitted, and
    /// every legacy-events waiter (docker ≤26 `start -a`, which negotiates
    /// API 1.24) hangs forever. With the correction, the next polls see
    /// created→running (start) and →stopped (die) normally.
    private func reseed(_ current: [Micropod_V1_Container], state: ShimState) async {
        for entry in current where known[entry.id] == nil {
            var recordedState = entry.state.lowercased()
            if recordedState == "stopped",
                await state.createRequest(for: entry.id) != nil,
                await !state.hasStarted(id: entry.id)
            {
                recordedState = "created"
                syntheticCreated.insert(entry.id)
            }
            known[entry.id] = Observation(
                state: recordedState, image: entry.image, labels: entry.labels)
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

    /// Containers recorded as synthetic `created` (see reconcile): the Apple
    /// runtime reports created-never-started as "stopped", so without the
    /// marker a genuinely-never-started container is indistinguishable from
    /// a deferred fast exit. Only synthetic entries consult hasEverStarted.
    private var syntheticCreated: Set<String> = []

    private func reconcile(_ current: [Micropod_V1_Container], state: ShimState) async {
        let observed = observe(current)
        let previousKnown = known

        for entry in current {
            let id = entry.id
            let after = observed[id]!
            // Baseline the health start period on every running observation
            // (idempotent): covers shim restarts where no start transition
            // fires but supervision re-derives from persisted specs.
            if after.state == "running" {
                await state.noteHealthRunning(id: id)
            }
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
                //
                // When an attached run is still in flight, hasEverStarted is
                // deliberately blind (the container reads "stopped" in the
                // window between /start and actually running) — mark it
                // synthetic-`created` instead of absorbing the stopped
                // sighting. The next polls then re-evaluate (below) instead
                // of losing the die event forever.
                let terminal = ["stopped", "exited", "dead"]
                if terminal.contains(after.state) {
                    if await hasEverStarted(id: id, state: state) {
                        await handleExit(entry: entry, observation: after, state: state)
                    } else if await state.isAttachRunning(id: id) {
                        syntheticCreated.insert(id)
                    }
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
                // A (re)start resets health supervision to starting; the
                // running stamp below baselines the start period.
                await state.resetHealth(id: id)
                await state.noteHealthRunning(id: id)
                syntheticCreated.remove(id)
            } else if wasLive {
                await handleExit(entry: entry, observation: after, state: state)
                syntheticCreated.remove(id)
            } else if before.state == "created" || before.state == "creating" {
                if syntheticCreated.contains(id) {
                    // Synthetic entry (see above): only a proven run may
                    // exit it. Still vetoed → keep the marker for next poll.
                    // Veto lifted without ever running → settle to observed.
                    if await hasEverStarted(id: id, state: state) {
                        await handleExit(entry: entry, observation: after, state: state)
                        syntheticCreated.remove(id)
                    } else if await state.isAttachRunning(id: id) == false {
                        syntheticCreated.remove(id)
                    }
                } else {
                    // Genuine created (mock distinguishes; Apple never
                    // reports it) — historical behavior.
                    await handleExit(entry: entry, observation: after, state: state)
                }
            }
        }
        for (id, before) in known where observed[id] == nil {
            await emit("container", "destroy", before, id: id)
            await state.forget(id: id)
            syntheticCreated.remove(id)
        }
        known = observed
        // Re-apply synthetic-`created` AFTER the bulk assignment, or it
        // silently absorbs the deferred exits (see above).
        for id in syntheticCreated {
            if var kept = observed[id] {
                kept.state = "created"
                known[id] = kept
            } else {
                // Vanished while deferred (rm'd mid-veto): drop the marker;
                // the destroy branch above already fired for it.
                syntheticCreated.remove(id)
            }
        }
        // Out-of-band change observed (another client, direct CLI use):
        // drop cached reads so the next API call is fresh. No-op when
        // nothing changed (the common case) — zero cost.
        if known != previousKnown {
            await readCache?.invalidateContainers()
        }
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
