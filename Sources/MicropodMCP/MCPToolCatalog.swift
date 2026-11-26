import Foundation

/// Every tool the server offers, with its parameters: the source of both
/// `tools/list` and the argument checks a call passes before it runs.
enum MCPToolCatalog {
    static func tool(named name: String) -> MCPTool? { byName[name] }

    private static let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

    private static let containerID = MCPParameter.string("id", "Container id or name.", required: true)

    /// `sandbox_run`'s options, which `sandbox_checkpoint_create` shares.
    private static let sandboxOptions: [MCPParameter] = [
        .string("image", "Image to boot (default alpine)."),
        .string("from", "A checkpoint to boot from instead of an image."),
        .integer("cpus", "Virtual CPUs.", in: 1...64),
        .integer("memory", "Memory in MiB.", in: 64...1_048_576),
        .duration("timeout", "Kill the guest after this long (seconds, or e.g. 10m); it then exits 124."),
        .string("workdir", "Working directory in the guest."),
        .list(
            "mounts",
            "host:/guest mounts (guest writes are discarded; host:/guest:rw needs allow_host_writes)."),
        .boolean("allow_net", "Give the guest network access (offline by default)."),
        .boolean("allow_host_writes", "Let :rw mounts write through to the host."),
        .list("allow_hosts", "Hosts the guest may reach; restricts egress to them."),
        .list(
            "secrets",
            "NAME=HOST_ENV@host: the guest sees a placeholder, the host proxy injects the real value on HTTPS to host."
        ),
        .list("env", "KEY=VAL environment entries."),
        .list("expose_host", "Host loopback ports the guest reaches as host.micropod.internal:PORT."),
        .list("ports", "host:guest ports to publish."),
    ]

    /// `k8s_enable` and `k8s_up`'s cluster settings.
    private static let k8sOptions: [MCPParameter] = [
        .string("image", "k3s image."),
        .string("memory", "Cluster VM memory, e.g. 4G."),
        .number("cpus", "Cluster VM CPUs."),
        .boolean("metallb", "Install MetalLB."),
        .boolean("ingress", "Install the ingress controller."),
        .string("lb_pool", "MetalLB address pool, a.b.c.d-e.f.g.h."),
        .string("name", "Cluster name."),
    ]

    static let tools: [MCPTool] = [
        MCPTool(
            name: "runtime_manage",
            description:
                "Manage Apple's dedicated runtime through Micropod's approved helper. Reports durable progress; disruptive actions require idle workloads and qualified rig coordination.",
            parameters: [
                .choice(
                    "action", ["install", "repair", "start", "stop", "restart", "operation", "cancel", "recover"],
                    "What to do.", required: true, noun: "runtime action")
            ]),
        MCPTool(name: "status", description: "Runtime status: running/stopped + CLI + apiserver versions."),
        MCPTool(
            name: "runtime_status",
            description:
                "Apple container dependency state, detected CLI version and setup/recovery action. Read-only; native readiness is unconfirmed without the native API probe."
        ),
        MCPTool(
            name: "list_containers", description: "List all containers (id, state, image, IP) as tab-separated lines."),
        MCPTool(name: "start", description: "Start a container.", parameters: [containerID]),
        MCPTool(name: "stop", description: "Stop a container.", parameters: [containerID]),
        MCPTool(name: "restart", description: "Restart a container (stop then start).", parameters: [containerID]),
        MCPTool(name: "kill", description: "Kill a container.", parameters: [containerID]),
        MCPTool(name: "delete", description: "Force-delete a container.", parameters: [containerID]),
        MCPTool(
            name: "run",
            description: "Run a container (detached).",
            parameters: [
                .string("image", "Image reference.", required: true),
                .string("name", "Container name."),
                .string("memory", "Memory limit, e.g. 512M."),
                .string(
                    "command",
                    "Run by /bin/sh -c instead of the image's default command — e.g. `sleep infinity` keeps a sandbox up for exec."
                ),
                .string(
                    "runtime",
                    "apple | docker | sandbox | ci | hvf; ci is this account's persistent Linux CI worker "
                        + "(`micropod ci start`), hvf is the shared Linux machine, started on first run once "
                        + "installed with `micropod machine install`."),
            ]),
        MCPTool(
            name: "runtimes",
            description:
                "Execution engines micropod can drive (apple VMs, docker, sandbox micro-VMs, the CI worker, "
                + "the shared hvf machine): availability, enabled, default, capabilities. Needs the Micropod API daemon."
        ),
        MCPTool(
            name: "runtime_set_default",
            description: "Set the default engine for new containers.",
            parameters: [.string("name", "apple | docker | sandbox | ci | hvf.", required: true)]),
        MCPTool(
            name: "runtime_update",
            description: "Enable/disable an engine or change its endpoint.",
            parameters: [
                .string("name", "Engine name.", required: true),
                .boolean("enabled", "Enable or disable the engine."),
                .string("endpoint", "Docker only: unix:///path or tcp://host:port."),
            ]),
        MCPTool(
            name: "exec",
            description: "Run a command in a running container.",
            parameters: [containerID, .string("command", "Shell command, run by /bin/sh -c.", required: true)]),
        MCPTool(
            name: "logs",
            description: "The last log lines of a container.",
            parameters: [containerID, .integer("lines", "How many lines (default 100).", in: 1...10_000)]),
        MCPTool(name: "stats", description: "Resource usage for all running containers (memory/CPU/net)."),
        MCPTool(name: "inspect", description: "Pretty-printed container inspect JSON.", parameters: [containerID]),
        MCPTool(
            name: "list_machines",
            description: "List container machines — persistent VMs (e.g. keep-alive CI): id, state, IP, CPUs, memory."
        ),
        MCPTool(
            name: "metrics_history",
            description: """
                Resource usage over time, as recorded by the Micropod app (10 s points for 3 h, 1 min for 48 h, \
                15 min for 30 days): per metric the peak, average and latest value plus a sparkline.
                """,
            parameters: [
                .string("id", "Container id or machine name; empty for all containers."),
                .choice(
                    "kind", ["system", "container", "machine"], "What id names (default container when id is set)."),
                .string("range", "e.g. 15m, 1h, 24h, 7d (default 1h)."),
            ]),
        MCPTool(
            name: "machine_stats",
            description: """
                Resource usage for running machines (CPU % of one core, memory, net, block I/O, pids) from \
                each machine's backing container — never execs in the guest.
                """,
            parameters: [.string("id", "Machine name (default all running).")]),
        MCPTool(
            name: "machine_logs",
            description: "Tail a machine's stdio log.",
            parameters: [
                .string("id", "Machine name.", required: true),
                .integer("lines", "How many lines (default 100).", in: 1...100_000),
                .boolean("boot", "The vminitd/kernel boot log instead."),
            ]),
        MCPTool(
            name: "sandbox_run",
            description: """
                Run a command in a fresh, disposable micro-VM (rootfs discarded on exit) and return its output \
                and exit code. Offline unless allow_net.
                """,
            parameters: [.string("command", "Shell command, run by /bin/sh -c.", required: true)] + sandboxOptions),
        MCPTool(name: "sandbox_checkpoints", description: "List sandbox checkpoints (saved disks to boot from)."),
        MCPTool(
            name: "sandbox_checkpoint_create",
            description:
                "Run a setup command in a sandbox and keep its disk as a named checkpoint (only if it exits 0).",
            parameters: [
                .string("name", "Checkpoint name.", required: true),
                .string("command", "Setup command, run by /bin/sh -c.", required: true),
            ] + sandboxOptions),
        MCPTool(
            name: "sandbox_checkpoint_delete",
            description: "Delete a sandbox checkpoint.",
            parameters: [.string("name", "Checkpoint name.", required: true)]),
        MCPTool(
            name: "list_images",
            description:
                "List local images (name, size, id). Images on other enabled engines (docker, the hvf machine) "
                + "follow, tagged [runtime], when the Micropod API daemon runs."),
        MCPTool(
            name: "list_volumes",
            description:
                "List volumes (name, size, driver). Volumes on other enabled engines follow, tagged [runtime], "
                + "when the Micropod API daemon runs."),
        MCPTool(
            name: "volume_policy",
            description: "Show the shared volume-mount policy (clone mode, golden volumes, sync/cache modes)."),
        MCPTool(
            name: "volume_policy_set",
            description: "Update the volume-mount policy. Only provided fields change.",
            parameters: [
                .choice("mode", ["labels", "goldens", "all"], "Which volumes are cloned per container."),
                .list("goldens", "Golden volume names."),
                .boolean("jobsOnly", "Clone only for CI job containers."),
                .choice("sync", ["full", "fsync", "nosync", "default"], "Volume sync mode."),
                .choice("cache", ["on", "off", "auto"], "Volume cache mode."),
            ]),
        MCPTool(name: "list_networks", description: "List networks (name, mode, subnet)."),
        MCPTool(
            name: "pull",
            description: "Pull an image.",
            parameters: [
                .string("reference", "Image reference.", required: true),
                .string(
                    "runtime",
                    "apple | docker | ci | hvf; a non-apple runtime pulls through the Micropod API daemon."),
            ]),
        MCPTool(
            name: "push", description: "Push an image.",
            parameters: [.string("reference", "Image reference.", required: true)]),
        MCPTool(name: "df", description: "Disk usage: containers/images/volumes sizes + reclaimable bytes."),
        MCPTool(
            name: "compose_up",
            description: "Parse + run a docker-compose.yml.",
            parameters: [
                .string("path", "Path to the compose file.", required: true),
                .list("profiles", "Profiles to enable."),
            ]),
        MCPTool(
            name: "compose_down",
            description: "Tear down a compose stack by its compose name.",
            parameters: [.string("name", "Compose project name.", required: true)]),
        MCPTool(
            name: "compose_ps",
            description: "List containers belonging to a compose stack.",
            parameters: [.string("name", "Compose project name.", required: true)]),
        MCPTool(
            name: "share_mount",
            description: "Expose a host directory as a synchronized file share.",
            parameters: [
                .string("src", "Host directory.", required: true),
                .boolean("readonly", "Read-only share."),
                .boolean("ro", "Alias of readonly."),
                .boolean("shared", "A live shared view instead of a copy."),
            ]),
        MCPTool(
            name: "share_unmount", description: "Remove a shared view.",
            parameters: [.string("id", "Share id.", required: true)]),
        MCPTool(name: "share_list", description: "List active synchronized file shares."),
        MCPTool(
            name: "share_sync", description: "Flush a shared view's writes back to its source.",
            parameters: [.string("id", "Share id.", required: true)]),
        MCPTool(name: "share_gc", description: "Remove unreferenced chunks from the shared cache."),
        MCPTool(
            name: "build_cache_stats",
            description: "Content-addressed build contexts: entries, bytes, shared bytes, cap.",
            parameters: [.string("path", "Cache root (default the standard one).")]),
        MCPTool(
            name: "update_check", description: "Trigger a background app update check (Sparkle) via the Micropod app."),
        MCPTool(
            name: "update_status",
            description: "Last-known app update state (checking/upToDate/updateAvailable/installing)."
        ),
        MCPTool(
            name: "update_apply",
            description: "Install a downloaded app update: quits Micropod, Sparkle applies it, app relaunches."
        ),
        MCPTool(
            name: "k8s_status",
            description: "Kubernetes engine state: enabled, cluster VM state, node Ready, kubeconfig path."
        ),
        MCPTool(
            name: "k8s_enable", description: "Enable the lightweight Kubernetes engine (opt-in).",
            parameters: k8sOptions),
        MCPTool(name: "k8s_disable", description: "Disable the Kubernetes engine (a running cluster is left up)."),
        MCPTool(
            name: "k8s_up",
            description: """
                Create or resume the k3s cluster VM and wait for Ready. Streams progress; \
                writes ~/.micropod/k8s/kubeconfig.
                """,
            parameters: k8sOptions),
        MCPTool(name: "k8s_down", description: "Remove the cluster VM and its state."),
        MCPTool(name: "k8s_kubeconfig", description: "Return the host kubeconfig contents for the cluster."),
        MCPTool(
            name: "k8s_load_image",
            description: """
                Push an image into the cluster's containerd via the host puller — bypasses the \
                guest's slow NAT registry path. Give `ref` or `path`.
                """,
            parameters: [
                .string("ref", "Registry ref; uses the local image store first, pulls on miss."),
                .string("path", "Local image-save tarball (no registry at all)."),
            ]),
        MCPTool(
            name: "k8s_images", description: "List image refs present in the cluster's containerd (k8s.io namespace)."),
        MCPTool(
            name: "cache_status",
            description:
                "Live HVF guest dependency cache inventory: total/L0/L1 usage, per-unit sizes, lock state, budget & eviction counts."
        ),
        MCPTool(
            name: "cache_explain",
            description: "Explain which caches attached or skipped (and why) for a container.",
            parameters: [containerID]),
        MCPTool(
            name: "cache_dedupe",
            description: "Sample cross-scope Go build-cache duplication to quantify reclaimable bytes.",
            parameters: [.integer("buckets", "Buckets to sample (default 16).", in: 1...256)]),
        MCPTool(
            name: "cache_prune",
            description: """
                Lock-safe bounded LRU / partial Go-build cache eviction (never touches in-use stores). \
                A dry run that reports what would be freed unless apply is true; an apply that names no \
                scope, tool, max_bytes or older_than_secs evicts every idle unit and also needs all: true.
                """,
            parameters: [
                .boolean("apply", "Evict for real (default false: a dry run)."),
                .boolean("dry_run", "Report only (the default); contradicts apply: true."),
                .boolean("all", "Confirm an apply with no selector: evict every idle unit in every scope."),
                .string("scope", "Only this cache scope."),
                .string("tool", "Only this tool's caches (e.g. go, gobuild, npm)."),
                .size("max_bytes", "Evict least recently used units until the total is at most this size."),
                .duration("older_than_secs", "Evict units idle for longer than this (seconds, or e.g. 14d)."),
                .boolean("partial_go_build", "Evict old Go build-cache files instead of whole units."),
            ]),
        MCPTool(
            name: "cache_policy",
            description:
                "Show the active HVF machine dependency cache policy (sharedL0, goProxy, npmRegistry, tools, budget)."),
        MCPTool(
            name: "cache_policy_set",
            description:
                "Update HVF cache policy live. Only the settings given change; a call naming none writes nothing.",
            parameters: [
                .choice("mode", ["auto", "off"], "Attach caches to every container (auto) or none (off)."),
                .boolean("shared_l0", "Share verified downloads across scopes (fleet L0)."),
                .string(
                    "go_proxy", "GOPROXY for containers, e.g. http://10.42.0.1:7677/go|direct; off or \"\" clears it."),
                .string("npm_registry", "npm registry URL for containers; off or \"\" clears it."),
                .string(
                    "default_scope", "Scope for containers naming none; none attaches only to containers naming one."),
                .size("max_bytes", "Janitor byte ceiling, e.g. 50g; 0 clears it."),
                .integer("max_age_days", "Janitor idle-age cap in days; 0 clears it.", in: 0...36_500),
            ]),
        MCPTool(
            name: "runtime_mode",
            description:
                "Show or switch Micropod execution mode: 'container' (fast shared HVF microVM) vs 'sandbox' (isolated 1-microVM-per-workload).",
            parameters: [.choice("mode", ["container", "sandbox"], "Switch to this mode (omit to show).")]),
        MCPTool(
            name: "rig_health",
            description:
                "Combined rootless rig health: active mode, HVF machine status, cache disk & policy, staged payload updates, and local depproxy health."
        ),
        MCPTool(
            name: "update_hvf_status",
            description:
                "Show active vs staged versioned HVF VMM/kernel/initrd/tools payload status and rollback history."),
        MCPTool(
            name: "update_hvf_rollback",
            description:
                "Return the HVF machine to its last known-good payload (probed after the restart). Deferred, as a "
                + "tool error, while containers run or idleness cannot be confirmed, unless force is true.",
            parameters: [
                .boolean("force", "Restart onto known-good even while containers run (interrupts them).")
            ]),
        MCPTool(
            name: "sandbox_status",
            description: "Show standalone sandbox VM readiness (cached vminitd/kernel without Apple container CLI)."),
    ]
}
