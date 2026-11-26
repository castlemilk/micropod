"""Boot the private vmnet MTU build and measure its actual routed publication link on Gamma."""

import argparse
import hashlib
import http.client
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

from qualify import (
    HERE,
    Admission,
    check_baseline,
    cli,
    peer,
    relay,
    request,
    require,
    terminal,
)

MTU_DIR = HERE.parent / "batch11-private-vmnet-mtu"
sys.path.insert(0, str(MTU_DIR))
import service_preflight

BUILD_SHA = "ea735da27a7cbef8db1a9201192af431511454ff6f41bc271fdd3ce0d4661af9"
PROFILED_DIAL_SOURCE = "8682632b499f9a927feabae9e936b2968a5aa8ceb5e28f05514e4972e44fb3a7"


def select(files, product=None):
    if product:
        import build_delivery

        product = product.resolve()
        require(
            product.name == "product.json"
            and product.parent.parent == build_delivery.BASE
            and product.parent.name.startswith("ci-published-link-"),
            "unexpected production build path",
        )
        build = json.loads(product.read_bytes())
        source = product.parent / "src"
        require(
            build["publication_key"] == "MICROPOD_CI_PUBLISHED_MTU"
            and build["guest_mtu_at_boot"] is True
            and build["entitlements"] == {"com.apple.security.virtualization": True}
            and Path(build["worker_executable"]) == product.parent / "micropod"
            and terminal.digest(product.parent / "worker.patch") == build["patch_sha256"]
            and all(terminal.digest(source / f) == s for f, s in build["compiled_sources"].items()),
            "production snapshot differs",
        )
        if "guest_publication_script_sha256" in build:
            files["oci"] = product.parent / "micropod-oci-tools"
            require(terminal.digest(files["oci"] / "runner/published-ports.sh")
                    == build["guest_publication_script_sha256"]
                    == build["compiled_sources"]["ci/runner/published-ports.sh"], "guest publication script changed")
            if "guest_start_sha256" in build:
                require(terminal.digest(files["oci"] / "runner/start.sh") == build["guest_start_sha256"]
                        == build["compiled_sources"]["ci/runner/start.sh"], "guest bootstrap changed")
            if "guest_runner_sha256" in build:
                require(terminal.digest(files["oci"] / "runner/bin/job") == build["guest_runner_sha256"],
                        "packaged guest engine changed")
    else:
        build = json.loads((MTU_DIR / "private-build/build.json").read_bytes())
        source = MTU_DIR.parents[3] / ".build/local-published-tcp/private-pub-mtu-86ca2713/src"
        require(
            build["worker_executable_sha256"] == BUILD_SHA
            and build["base_revision"] == relay.STOCK_RELAY_REV,
            "unrecognized benchmark worker",
        )
    files["cli"] = Path(build["worker_executable"])
    require(
        terminal.digest(files["cli"]) == build["worker_executable_sha256"]
        and terminal.digest(files["fixed"]) == peer.CLIENT,
        "changed worker or client",
    )
    relay_src = "Sources/CPublishedTCP/PublishedTCP.c"
    archived = subprocess.check_output(
        ["git", "-C", source.parents[3], "show", build["base_revision"] + ":" + relay_src]
    )
    expected = PROFILED_DIAL_SOURCE if build.get("embedded_cli_info") else hashlib.sha256(archived).hexdigest()
    require(terminal.digest(source / relay_src) == build["compiled_sources"][relay_src] == expected,
            "changed relay source")
    terminal.invoke("codesign", "--verify", "--strict", files["cli"])
    return build


def inspect(scope, build, mtu, clients, relay_mode, workers=2, role="Standard", *, read_kib=None, kernel_sha=relay.STOCK_KERNEL):
    ident, docker = service_preflight.identity(scope, build, mtu)
    fx = relay.inspect(
        scope, 4, False, process_type=role, relay_mode=relay_mode, allowed_relay_workers=(workers,), kernel_sha=kernel_sha
    )
    mapped = relay.mapped_executable(Path(build["worker_executable"]), fx["pids"]["relay"])
    require(
        mapped["sha256"] == fx["cli_sha256"] == build["worker_executable_sha256"]
        and fx["relay_workers"] == workers
        and fx["route"] == relay.DIRECT_ROUTE,
        "wrong private VM or relay",
    )
    require(relay.digest(Path(fx["kernel"])) == kernel_sha, "wrong guest kernel")
    events = 128 if workers == 2 else 24
    cap = read_kib * 1024 if read_kib else build.get("experimental_read_bytes", 262144)
    require(cap in (262144, 524288), "unknown relay read size")
    observed = (fx["callback_events"], fx["read_bytes"])
    require(
        observed == (events, cap) or (mapped["sha256"] == BUILD_SHA and observed == (None, None)),
        "wrong relay controls",
    )
    fx.update(
        kernel_image_sha256=kernel_sha,
        callback_events=events,
        read_bytes=cap,
        relay_mode=relay_mode,
        relay_controls_origin="live worker session" if observed[0] else "compiled stock relay source",
        boot=fx["guest_boot"],
        mapped_relay_build={
            "mapped_inode": mapped["inode"],
            "worker_executable_sha256": mapped["sha256"],
            "source_revision": build["base_revision"],
        },
        publication=ident,
    )
    fx["births"] = relay.identities(relay.snapshot(clients, fx))
    return fx, docker


def boot_routes(workspace, folder, identity, gateway, iface):
    table = workspace / "nft-before"
    if not table.exists():
        return
    match = re.search(r"map listeners \{.*?elements = \{\s*(\d+) :", table.read_text(), re.DOTALL)
    if not match:
        return
    target = (identity["worker_ipv4"], int(match[1]))
    result = []
    for label in ("default", "bound-address", "bound-interface"):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(1)
            if label == "bound-interface":
                sock.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex(iface))  # Darwin IP_BOUND_IF
            if label != "default":
                sock.bind((gateway, 0))
            try:
                sock.connect(target)
                sock.sendall(b"GET /id HTTP/1.0\r\nHost: localhost\r\n\r\n")
                reply = http.client.HTTPResponse(sock)
                reply.begin()
                result.append(
                    {
                        "path": label,
                        "correct": reply.status == 200 and reply.read().decode() == identity["name"],
                    }
                )
            except OSError as error:
                result.append({"path": label, "error": str(error)})
    evidence = terminal.invoke("lsof", "-nP", "-a", "-p", str(identity["relay_pid"]), "-iTCP", check=False)
    (folder / "boot-relay-sockets.txt").write_text(evidence.stdout)
    terminal.save(folder / "boot-routes.json", result)


def prove_running(scope, folder, workspace, build, mtu, secret):
    shutil.copy2(workspace / "private-link.txt", folder / "guest-link.txt")
    if (workspace / "worker-ext4.txt").is_file():
        shutil.copy2(workspace / "worker-ext4.txt", folder / "worker-ext4.txt")
    ident, docker = service_preflight.identity(scope, build, mtu)
    guest = (folder / "guest-link.txt").read_text()
    gateway = re.search(r"^gateway=([0-9.]+)$", guest, re.MULTILINE)[1]
    route = cli(["/sbin/route", "-n", "get", ident["worker_ipv4"]])
    iface = re.search(r"interface: (\w+)", route)[1]
    require(iface.startswith("bridge"), "unexpected private bridge")
    mac = cli(["/sbin/ifconfig", iface])
    (folder / "host-link.txt").write_text(route + "\n" + mac + "\n")
    require(
        "set_exit=0" in guest
        and re.search(rf"\bmtu {mtu}\b", guest)
        and re.search(rf"\bmtu {mtu}\b", mac.splitlines()[0]),
        "publication MTU differs",
    )
    require(udp_proof(workspace, gateway, ident["worker_ipv4"], mtu, secret, folder), "DF payload failed")
    for member in re.findall(r"member: (vmenet[0-9]+)", mac):
        (folder / f"{member}.txt").write_text(cli(["/sbin/ifconfig", member]))
    attempts = []
    observe_boot = build.get("guest_mtu_at_boot") is True
    if observe_boot:
        (workspace / "trace-now").touch()
        (folder / "host-neighbor.txt").write_text(
            terminal.invoke("/usr/sbin/arp", "-n", ident["worker_ipv4"], check=False).stdout
        )
        time.sleep(0.15)
    # The worker checks the guest route every 20 seconds. Record startup separately
    # long enough to observe two checks before admitting the first scored request.
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        conn = http.client.HTTPConnection(ident["endpoint"], timeout=min(2, deadline - time.monotonic()))
        started = time.monotonic()
        try:
            conn.request("GET", "/id")
            response = conn.getresponse()
            require(
                response.status == 200 and response.read().decode() == ident["name"], "wrong boot service"
            )
            attempts.append({"seconds": time.monotonic() - started, "ready": True})
            break
        except (OSError, http.client.HTTPException) as error:
            if not attempts and observe_boot:
                boot_routes(workspace, folder, ident, gateway, iface)
            neighbors = terminal.invoke(
                *docker,
                "exec",
                ident["container"],
                "/mpcheck/link-probe",
                "neighbors",
                check=False,
                timeout=4,
            )
            sockets = terminal.invoke(
                *docker, "exec", ident["container"], "/mpcheck/ss", "-ntai", check=False, timeout=4
            )
            attempts.append(
                {
                    "seconds": time.monotonic() - started,
                    "error": str(error),
                    "arp": neighbors.stdout,
                    "sockets": sockets.stdout,
                }
            )
        finally:
            conn.close()
            terminal.save(folder / "publication-readiness.json", attempts)
    if observe_boot:
        deadline = time.monotonic() + 10
        while not (workspace / "nft-after").exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        for name in ("nft-before", "nft-after", "eth1-trace", "root-neighbors"):
            if (workspace / name).exists():
                shutil.copy2(workspace / name, folder / name)
    require(attempts[-1].get("ready"), "published service did not become reachable")
    return ident, docker


def check_tenants(cohort, mtu, fixture):
    cohort.add(32)
    evidence = [json.loads(request(j, "/publication-link")) for j in cohort.jobs]
    terminal.save(cohort.folder / f"link-{cohort.arm}.json", evidence)
    for j, item in zip(cohort.jobs, evidence, strict=True):
        require((j["cookie"], j["name"]) == (item["cookie"], item["name"]), "wrong link owner")
        if cohort.arm == "A":
            require(
                item["links"]["mppub0"] == mtu and mtu - 80 <= item["mss"] <= mtu - 40,
                f"published socket did not use its full MTU: {item}",
            )
    if cohort.arm != "A":
        return
    helper = cohort.runner.root / "relay-socket"
    terminal.invoke("xcrun", "clang", "-std=c11", "-Wall", "-Werror", MTU_DIR / "relay_mss.c", "-o", helper)
    addr = fixture["publication"]["worker_ipv4"]
    expected = hashlib.sha256(b"micropod" * (1 << 20)).digest()

    def measure(job):
        conn = http.client.HTTPConnection("127.0.0.1", job["port"], timeout=10)
        try:
            conn.request("GET", "/publication-link")
            rsp = conn.getresponse()
            row = json.loads(rsp.read())
            require(rsp.status == 200 and row["cookie"] == job["cookie"], "wrong socket owner")
            sock = conn.sock
            gateway, port = row["peer"].rsplit(":", 1)
            args = [helper, str(fixture["pids"]["relay"]), gateway, port, addr]
            before = json.loads(cli(args))
            conn.request("GET", "/data")
            rsp = conn.getresponse()
            require(
                rsp.status == 200
                and hashlib.sha256(rsp.read((8 << 20) + 1)).digest() == expected
                and conn.sock is sock,
                "flow changed during the socket measurement",
            )
            after = json.loads(cli(args))
            require(
                before["peer_port"] == after["peer_port"]
                and before["send_mss"] == after["send_mss"]
                and mtu - 80 <= after["send_mss"] <= mtu - 40,
                "Mac relay MSS or backend changed",
            )
            return {
                "port": job["port"],
                "name": job["name"],
                "cookie": job["cookie"],
                "before": before,
                "after": after,
            }
        finally:
            conn.close()

    with ThreadPoolExecutor(max_workers=4) as pool:
        backends = list(pool.map(measure, cohort.jobs))
    terminal.save(cohort.folder / "relay-backends.json", backends)
    return backends


def route_study(cohort, folder, clients, fx, backends):
    import churn
    import kernel_ci

    kernel_ci.set_mode(cohort.jobs, "memory")
    direct = folder / "direct-targets.tsv"
    lines = []
    for job, row in zip(cohort.jobs, backends, strict=True):
        host, port = row["after"]["peer_address"], row["after"]["peer_port"]
        require(
            host == fx["publication"]["worker_ipv4"] and 1024 <= port <= 65535,
            "direct route target outside worker",
        )
        conn = http.client.HTTPConnection(host, port, timeout=5)
        try:
            conn.request("GET", "/publication-link")
            reply = conn.getresponse()
            data = json.loads(reply.read())
            require(
                reply.status == 200 and data["cookie"] == job["cookie"] and data["name"] == job["name"],
                "backend tenant mismatch",
            )
        finally:
            conn.close()
        lines.append(f"http://{host}:{port}\t{job['name']}\n")
    direct.write_text("".join(lines))
    require(len({r["after"]["peer_port"] for r in backends}) == 32, "duplicate direct peer target")
    order = [["loopback", "direct"], ["direct", "loopback"], ["direct", "loopback"], ["loopback", "direct"]]
    terminal.save(
        folder / "routes-plan.json",
        {
            "order": order,
            "source": "memory",
            "direct_sha256": terminal.digest(direct),
            "client": terminal.digest(clients / "fixed"),
        },
    )

    def snapshot(phase):
        return relay.snapshot(clients, fx)

    for i, block in enumerate(order):
        for j, route in enumerate(block):
            print(f"Path comparison {i + 1}: {route}", flush=True)
            churn.batch(
                cohort,
                2 * i + j,
                clients / "fixed",
                cpu_list="0-3",
                observe=snapshot,
                backend_targets=direct if route == "direct" else None,
            )
    cohort.audit_memory()
    churn.replace(cohort)


def stage(oci, workspace, mtu, *, trace=False, configure_guest=True, test_repair=False, trace_handshakes=False,
          parent_gso_bytes=None):
    secret = secrets.token_hex(16)
    env = {**os.environ, "CGO_ENABLED": "0", "GOARCH": "arm64", "GOOS": "linux"}
    terminal.invoke(
        "go", "build", "-trimpath", "-o", workspace / "link-udp", HERE / "link_udp_linux.go", env=env
    )
    shutil.copy2(workspace / "link-udp", workspace / "probe/link-probe")
    hook = oci / "runner/fixture-facts.sh"
    original = hook.read_text()
    insertion = """(
        ip link set dev eth1 mtu TARGET
        echo set_exit=$?
        echo gateway=$MICROPOD_CI_PUBLISH_GATEWAY
        ip -o -4 addr show dev eth1
        ip -d link show dev eth1
        ip -4 route show dev eth1
        ip neigh show dev eth1
        echo "requested_rps=${MICROPOD_CI_PUBLISHED_RPS:-}"
        echo "rx0_rps=$(cat /sys/class/net/eth1/queues/rx-0/rps_cpus 2>/dev/null)"
        echo "inotify_instances=$(cat /proc/sys/fs/inotify/max_user_instances)"
        awk '/Max open files/ {print "bootstrap_nofile=" $4 "," $5}' /proc/self/limits
    ) > "$MICROPOD_ENGINE_WORKSPACE/private-link.txt" 2>&1
    awk '$3 == "ext4" {print $2, $4}' /proc/self/mounts > "$MICROPOD_ENGINE_WORKSPACE/worker-ext4.txt"
"""
    first, rest = original.split("\n", 1)
    if test_repair:
        insertion += """(
            d=$MICROPOD_ENGINE_WORKSPACE
            while [ ! -f "$d/repair-trigger" ]; do sleep .2; done
            ip netns list >"$d/repair-namespaces"
            for ns in $(awk '{print $1}' "$d/repair-namespaces"); do
                ip -n "$ns" -d -o link show mppub0 >>"$d/repair-owned-links" 2>/dev/null || true
            done
            cat /sys/class/net/eth1/mtu >"$d/repair-original"
            if [ "${MICROPOD_CI_PUBLISHED_RPS:-}" = off-irq ]; then
                cat /sys/class/net/eth1/ifindex /sys/class/net/eth1/queues/rx-0/rps_cpus >"$d/repair-queue-before"
            fi
            ip link set dev eth1 mtu 1500 || exit 1
            cat /sys/class/net/eth1/mtu >"$d/repair-disturbed"
            for ns in $(awk '{print $1}' "$d/repair-namespaces"); do
                ip -n "$ns" -o link show mppub0 >>"$d/repair-lowered-links" 2>/dev/null || true
            done
            for delay in $(seq 1 180); do
                current=$(cat /sys/class/net/eth1/mtu)
                [ "$current" = TARGET ] && break
                sleep .25
            done
            if [ -f "$d/repair-queue-before" ]; then
                cat /sys/class/net/eth1/ifindex /sys/class/net/eth1/queues/rx-0/rps_cpus >"$d/repair-queue-after"
            fi
            echo "$current" >"$d/repair-end.tmp"
            mv "$d/repair-end.tmp" "$d/repair-end"
        ) </dev/null >"$MICROPOD_ENGINE_WORKSPACE/repair-log" 2>&1 &\n"""
    insertion += (
        '"$MICROPOD_ENGINE_WORKSPACE/link-udp" "$MICROPOD_CI_PUBLISH_IPV4" "$MICROPOD_CI_PUBLISH_GATEWAY" '
        '"$MICROPOD_ENGINE_WORKSPACE/link-port" '
        + secret
        + ' </dev/null >"$MICROPOD_ENGINE_WORKSPACE/udp.log" 2>&1 &\n'
    )
    if trace:
        insertion += """ip -ts monitor neigh dev eth1 </dev/null >"$MICROPOD_ENGINE_WORKSPACE/publication-neighbors.log" 2>&1 &
        ip -ts monitor neigh all-nsid </dev/null >"$MICROPOD_ENGINE_WORKSPACE/guest-neighbors.log" 2>&1 &
        (while [ ! -e "$MICROPOD_ENGINE_WORKSPACE/trace-now" ]; do sleep .1; done
        nft list table netdev mp_publication > "$MICROPOD_ENGINE_WORKSPACE/nft-before"
        ip neigh show dev eth1 > "$MICROPOD_ENGINE_WORKSPACE/root-neighbors"
        "$MICROPOD_ENGINE_WORKSPACE/link-udp" trace eth1
        nft list table netdev mp_publication > "$MICROPOD_ENGINE_WORKSPACE/nft-after"
    ) </dev/null >"$MICROPOD_ENGINE_WORKSPACE/eth1-trace" 2>&1 &\n"""
    if trace_handshakes:
        insertion += ('"$MICROPOD_ENGINE_WORKSPACE/link-udp" handshakes eth1 </dev/null '
                      '>"$MICROPOD_ENGINE_WORKSPACE/publication-setup-trace" 2>&1 &\n')
    if not configure_guest:
        insertion = insertion.replace("ip link set dev eth1 mtu TARGET", "ip link show dev eth1")
    if parent_gso_bytes:
        require(parent_gso_bytes in (32768, 40960, 45056), "unexpected startup segmentation limit")
        insertion = f"ip link set dev eth1 gso_ipv4_max_size {parent_gso_bytes} || exit 1\n" + insertion
    hook.write_text(first + "\n" + insertion.replace("TARGET", str(mtu)) + rest)
    return secret


def check_disk_batch(folder, workspace, value):
    path = folder / "worker-ext4.txt"
    shutil.copy2(workspace / path.name, path)
    options = [
        line.split(maxsplit=1)[1].split(",")
        for line in path.read_text().splitlines()
        if line.startswith("/ ")
    ]
    require(
        len(options) == 1 and "rw" in options[0] and f"max_batch_time={value}" in options[0],
        "live ext4 root differs from the requested journal timing",
    )


def verify_repair(folder, workspace, scope, build, mtu, *, check_http=True):
    # The fixture only lowers its own publication NIC. The running product must restore it.
    identity, docker = service_preflight.identity(scope, build, mtu)
    tenant_mtu = [*docker, "exec", identity["container"], "/mpcheck/link-probe", "mtu", "mppub0"]
    before = int(cli(tenant_mtu))
    require(before == mtu, "existing service did not initially use the configured MTU")
    start = time.monotonic()
    (workspace / "repair-trigger").touch()
    while not (workspace / "repair-end").exists() and time.monotonic() - start < 50:
        time.sleep(0.1)
    rows = {
        key: int((workspace / ("repair-" + key)).read_text())
        for key in ("original", "disturbed", "end")
        if (workspace / ("repair-" + key)).is_file()
    }
    home = scope.resolve().parents[1] / "a"
    receipt = home / "published-network.json"
    receipt_deadline = time.monotonic() + 3
    while not receipt.exists() and time.monotonic() < receipt_deadline:
        time.sleep(0.05)
    if receipt.exists():
        rows["worker_receipt"] = json.loads(receipt.read_bytes())
    rows["existing_mtu_before"] = before
    rows["existing_mtu_after"] = int(cli(tenant_mtu))
    if (workspace / "repair-queue-before").exists():
        for phase in ("before", "after"):
            rows["publication_queue_" + phase] = (workspace / ("repair-queue-" + phase)).read_text().splitlines()
        require(rows["publication_queue_before"] == rows["publication_queue_after"]
                and int(rows["publication_queue_after"][1], 16) == 7, "publication queue changed on repair")
    for name in ("repair-namespaces", "repair-owned-links", "repair-lowered-links"):
        if (workspace / name).is_file():
            shutil.copy2(workspace / name, folder / name)
    rows["seconds"] = time.monotonic() - start
    terminal.save(folder / "link-repair.json", rows)
    require(
        [rows.get(k) for k in ("original", "disturbed", "end")] == [mtu, 1500, mtu],
        "worker failed to restore its private NIC MTU",
    )
    observed = rows.get("worker_receipt", {})
    require(
        observed.get("instance", "").lower() == identity["instance"].lower()
        and observed.get("cause") == "guest-link-restored"
        and not observed.get("error"),
        "missing private-link repair receipt from this worker",
    )
    require(rows["existing_mtu_after"] == mtu, "existing service MTU did not recover with its parent")
    if not check_http:
        return
    conn = http.client.HTTPConnection(identity["endpoint"], timeout=4)
    try:
        conn.request("GET", "/id")
        reply = conn.getresponse()
        require(
            reply.status == 200 and reply.read().decode() == identity["name"],
            "existing publication failed after MTU repair",
        )
        rows["existing_service"] = identity["name"]
        terminal.save(folder / "link-repair.json", rows)
    finally:
        conn.close()


def verify_service_repair(cohort, workspace, scope, build, mtu):
    folder = cohort.folder
    before = json.loads((folder / "link-A.json").read_bytes())
    verify_repair(folder, workspace, scope, build, mtu)
    disturbed = (folder / "repair-lowered-links").read_text().splitlines()
    require(
        len(disturbed) == len(before) + 1 and all(" mtu 1500 " in line for line in disturbed),
        "the fixture did not lower every resident service interface",
    )
    with ThreadPoolExecutor(max_workers=8) as clients:
        replies = list(clients.map(lambda j: json.loads(request(j, "/publication-link")), cohort.jobs))
    terminal.save(folder / "service-links-after-repair.json", replies)
    require(
        len(before) == len(replies) == 32
        and all(
            all(now[k] == initial[k] for k in ("name", "cookie", "mss", "links"))
            and now["links"]["mppub0"] == mtu
            for initial, now in zip(before, replies, strict=True)
        ),
        "a live service failed to recover its publication MTU or TCP segment size",
    )


def verify_oom_watch(folder, workspace, docker, services, extra, prefix):
    idle = []
    for i in range(31):
        name = f"{prefix}-idle-{i}"
        cid = cli(docker, "run", "-d", "--pull=never", "--name", name, "--network", "none", "--memory", "64m",
                  terminal.SERVICE, "-listen", ":8080", "-marker", name)
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "invalid idle container")
        extra.append(cid)
        idle.append(cid)
    target = cli(docker, "run", "-d", "--pull=never", "--name", prefix + "-oom", "--network", "none",
                 "--memory", "32m", "--mount", f"type=bind,src={workspace / 'probe'},dst=/mpcheck,readonly",
                 "--entrypoint", "/mpcheck/link-probe", terminal.SERVICE, "oom-check")
    require(re.fullmatch(r"[0-9a-f]{64}", target), "invalid memory fault container")
    extra.append(target)
    siblings = set(services) | set(idle)
    running = set(cli(docker, "ps", "-q", "--no-trunc").splitlines())
    require(len(running) == 64 and running == siblings | {target}, "memory fault needs 64 live owned containers")
    (workspace / "probe/oom-now").touch(exist_ok=False)
    exit_code = int(cli(docker, "wait", target, timeout=45))
    info, = json.loads(cli(docker, "inspect", target))
    remaining = set(cli(docker, "ps", "-q", "--no-trunc").splitlines())
    terminal.save(folder / "oom-fault.json", {
        "target": target, "running_at_release": sorted(running), "running_after": sorted(remaining),
        "state": info["State"], "target_limit": info["HostConfig"]["Memory"], "wait": exit_code,
    })
    require(info["Id"] == target and info["HostConfig"]["Memory"] == 32 << 20
            and info["State"]["OOMKilled"] and exit_code == info["State"]["ExitCode"] == 137
            and remaining == siblings, "containerd did not attribute the bounded OOM to its owning container")


def guest_repair_only(folder, workspace, scope, build, mtu, *, oom=False, monitor=None, gso_bytes=None, docker_tsq=False,
                      docker_cpuset=False):
    identity, docker = service_preflight.identity(scope, build, mtu)
    terminal.save(folder / "identity.json", identity)
    services = [identity["container"]]
    extra = []
    limits = (None, 163840, 196608)
    key = "net.ipv4.tcp_limit_output_bytes"
    cpu_masks = (None, "0", "1-2", "0,3")
    try:
        for i in range(1, 32):
            name = identity["name"] + "-mtu-" + str(i)
            cid = cli(
                docker,
                "run",
                "-d",
                "--pull=never",
                "--name",
                name,
                *(["--sysctl", f"{key}={limits[i % 3]}"] if docker_tsq and limits[i % 3] else []),
                *(["--cpuset-cpus", cpu_masks[i % 4]] if docker_cpuset and cpu_masks[i % 4] else []),
                "--cpus",
                "1",
                "--memory",
                "128m",
                "--pids-limit",
                "64",
                "--mount",
                f"type=bind,src={workspace / 'probe'},dst=/mpcheck,readonly",
                "-p",
                "127.0.0.1::8080",
                terminal.SERVICE,
                "-listen",
                ":8080",
                "-marker",
                name,
            )
            require(re.fullmatch(r"[0-9a-f]{64}", cid), "unexpected container ID")
            extra.append(cid)
            services.append(cid)
        require(len(set(services)) == 32, "duplicate service ID")

        def inspect(cid):
            return int(cli(docker, "exec", cid, "/mpcheck/link-probe", "mtu", "mppub0"))

        with ThreadPoolExecutor(max_workers=8) as clients:
            if monitor:
                require(monitor.collect("runner-sha").strip() == build["guest_runner_sha256"],
                        "guest did not start the packaged engine")
            if docker_tsq:
                original = dict(line.split() for line in monitor.collect("tsq-read").splitlines())
                default = int(original["tsq-root"])
                expected = [limits[i % 3] or default for i in range(len(services))]

                def queue(cid):
                    return int(cli(docker, "exec", cid, "/mpcheck/link-probe", "tcp-queue"))

                sizes = list(clients.map(queue, services))
                rows = json.loads(cli(docker, "inspect", *services))
                requested = [(row["HostConfig"].get("Sysctls") or {}).get(key) for row in rows]
                require(sizes == expected and requested == [str(limits[i % 3]) if limits[i % 3] else None
                        for i in range(len(services))], "container and Docker config disagree about TCP queues")
                cid = services[1]
                cli(docker, "stop", "-t", "1", cid)
                cli(docker, "start", cid)
                (restarted,) = json.loads(cli(docker, "inspect", cid))
                after_start = list(clients.map(queue, services))
                current = dict(line.split() for line in monitor.collect("tsq-read").splitlines())
                require(restarted["Id"] == cid and restarted["State"]["StartedAt"] != rows[1]["State"]["StartedAt"]
                        and after_start == sizes and int(current["tsq-root"]) == default,
                        "TCP queue changed across restart or affected a sibling")
                terminal.save(folder / "docker-tcp-queues.json", {
                    "services": services, "requested": requested, "worker_default": default,
                    "before": sizes, "after_start": after_start, "restarted": cid,
                })
            if docker_cpuset:
                def cpus(cid):
                    return cli(docker, "exec", cid, "/mpcheck/link-probe", "cpu-set")

                rows = json.loads(cli(docker, "inspect", *services))
                requested = [row["HostConfig"].get("CpusetCpus") or None for row in rows]
                expected = [cpu_masks[i % 4] for i in range(32)]
                cpu_before = list(clients.map(cpus, services))
                require(requested == expected and cpu_before == [mask or "0-3" for mask in expected],
                        "packaged service CPU masks differ from Docker requests")
                cid = services[3]
                cli(docker, "stop", "-t", "1", cid)
                cli(docker, "start", cid)
                (restarted,) = json.loads(cli(docker, "inspect", cid))
                require(restarted["Id"] == cid and restarted["State"]["StartedAt"] != rows[3]["State"]["StartedAt"]
                        and restarted["HostConfig"]["CpusetCpus"] == "0,3", "service restart lost its CPU mask")
            ports = list(clients.map(lambda cid: cli(docker, "port", cid, "8080/tcp"), services))
            require(
                len(set(ports)) == 32 and all(re.fullmatch(r"127\.0\.0\.1:[0-9]+", p) for p in ports),
                "guest control returned different publications",
            )
            before = list(clients.map(inspect, services))
            require(before == [mtu] * 32, "wrong initial tenant MTUs")
            if gso_bytes:
                def read_gso(action, expected):
                    rows = dict(line.split() for line in monitor.collect(action).splitlines())
                    require(rows.pop("ipv4-tso") == "on" and rows.pop("parent") == str(expected)
                            and len(rows) == 32 and set(rows.values()) == {str(expected)},
                            "parent or leased service has the wrong GSO limit")
                    return set(rows)

                macs = read_gso("gso-read", gso_bytes)
                require(read_gso("gso-65536", 65536) == macs, "lease changed during the GSO fault")
            verify_repair(folder, workspace, scope, build, mtu, check_http=False)
            after = list(clients.map(inspect, services))
            if docker_cpuset:
                cpu_after = list(clients.map(cpus, services))
                require(cpu_after == cpu_before, "restart or MTU repair changed a service CPU mask")
                terminal.save(folder / "docker-cpu-sets.json", {"services": services, "requested": requested,
                              "before": cpu_before, "after": cpu_after, "restarted": services[3]})
            if gso_bytes:
                require(read_gso("gso-read", gso_bytes) == macs, "GSO repair lost a leased interface")
            if monitor:
                monitor.collect("done")
        result = {
            "control": "native Docker Unix socket",
            "published_endpoints": ports,
            "services": services,
            "before": before,
            "after": after,
        }
        terminal.save(folder / "guest-service-repair.json", result)
        lowered = (folder / "repair-lowered-links").read_text().splitlines()
        require(
            len(lowered) == 32 and all(" mtu 1500 " in n for n in lowered) and after == before,
            "not every live child recovered the configured MTU",
        )
        if oom:
            verify_oom_watch(folder, workspace, docker, services, extra, identity["name"])
    finally:
        if extra:
            cli(docker, "rm", "-f", *extra, timeout=120)
            remaining = cli(docker, "ps", "-aq", "--no-trunc").splitlines()
            require(set(extra).isdisjoint(remaining), "guest repair fixture still owns containers")


def udp_proof(workspace, gw, addr, mtu, secret, folder):
    port = int((workspace / "link-port").read_text())
    sizes = sorted({256, 1472, 2000 if mtu > 1500 else 1472, mtu - 28})
    samples = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.IPPROTO_IP, 28, 1)  # Darwin IP_DONTFRAG
        require(s.getsockopt(socket.IPPROTO_IP, 28) == 1, "Darwin DF readback failed")
        s.bind((gw, 0))
        s.connect((addr, port))
        s.settimeout(0.6)
        for size in sizes:
            for attempt in range(3):
                body = secret.encode() + secrets.token_bytes(size - len(secret))
                try:
                    s.send(body)
                    data = s.recv(9000)
                    result = "verified" if data == body else "wrong datagram"
                except OSError as e:
                    result = str(e)
                samples.append({"bytes": size, "attempt": attempt, "result": result})
        s.send(secret.encode() + b"done")
    terminal.save(folder / "df.json", samples)
    shutil.copy2(workspace / "udp.log", folder / "udp.log")
    return all(row["result"] == "verified" for row in samples)


def stage_guest_runner(oci, folder):
    source = HERE.parents[3] / "guest/runner"
    target = oci / "runner/bin/job"
    require(target.parent.resolve().is_relative_to(oci.resolve()) and not target.is_symlink(),
            "guest runner is outside the disposable bundle")
    env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"}
    env.pop("GOROOT", None)
    inputs = sorted([*source.glob("*.go"), source / "go.mod", source / "go.sum"])
    hashes = {path.name: terminal.digest(path) for path in inputs}
    candidate = target.with_name("job.candidate")
    command = ["go", "build", "-trimpath", "-o", str(candidate), "."]
    subprocess.run(command, cwd=source, env=env, check=True)
    require(hashes == {path.name: terminal.digest(path) for path in inputs}, "guest source changed during build")
    candidate.replace(target)
    proof = {"sources": hashes, "binary_sha256": terminal.digest(target), "command": command,
             "go_version": subprocess.check_output(["go", "env", "GOVERSION"], cwd=source, env=env, text=True).strip()}
    terminal.save(folder / "guest-runner-build.json", proof)
    return proof["binary_sha256"]


def run(folder, mtu, product=None, repair=False, profile_relay=False, guest_only=False, published_rps=False, oom=False,
        probe_gso_inheritance=False, current_runner=False, worker_gso=None, docker_tsq=False, docker_cpuset=False,
        page_kernel_pair=None, page_kib=None, node_sqlite=False, mthp_dir=None, mthp_policy=None):
    opts = terminal.parse_options(["--mode", "host-role", "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    build = select(files, product)
    require(bool(page_kernel_pair) == bool(page_kib), "specify both the kernel pair and page size")
    require(bool(mthp_dir) == bool(mthp_policy) and not (mthp_dir and page_kernel_pair),
            "choose one kernel policy for conformance")
    live_pages = 4 if mthp_dir else page_kib
    require(not live_pages or guest_only, "packaged page-size conformance uses the local guest control socket")
    require(not node_sqlite or live_pages, "cross-kernel SQLite needs a verified guest page size")
    page_meta = {}
    if live_pages:
        import build_pages
        if mthp_dir:
            import build_thp
            page_meta = build_thp.select(mthp_dir, mthp_policy, files, folder)
        else:
            page_meta = build_pages.select(page_kernel_pair, page_kib, files, folder)
    require(not published_rps or build.get("guest_publication_script_sha256"),
            "boot-time receive steering needs the matching native worker and guest script")
    terminal.check_archives(files)
    terminal.verify_cache()
    admission = Admission(folder)
    admission.check(force=True)
    runner = terminal.Run(opts, folder, admission)
    admission.owner = runner.root.name
    try:
        guest_start = HERE.parents[3] / "ci/runner/start.sh"
        packaged_start = build.get("guest_start_sha256") == terminal.digest(guest_start)
        if oom and packaged_start:
            terminal.save(folder / "worker-build.json", build)
        workspace, oci, _clients = terminal.stage(
            runner.root, files, runner_start=guest_start if oom and not packaged_start else None
        )
        if mthp_dir:
            build_thp.stage_observer(oci)
        if live_pages:
            env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"}
            page_meta.update(build_pages.stage(workspace / "probe", [], env, pages=True, accounting=False))
        guest_runner_sha = stage_guest_runner(oci, folder) if current_runner else None
        control = None
        if worker_gso or docker_tsq or docker_cpuset:
            import kernel_ci

            require(build.get("guest_runner_sha256") and not current_runner and not probe_gso_inheritance,
                    "worker GSO qualification requires the packaged guest engine and unmodified boot")
            kernel_ci.stage(workspace, oci)
            control = kernel_ci.Observer(SimpleNamespace(workspace=workspace, folder=folder, runner=runner))
            terminal.save(folder / "worker-build.json", build)
        secret = stage(oci, workspace, mtu, trace=True, configure_guest=product is None, test_repair=repair,
                       parent_gso_bytes=40960 if probe_gso_inheritance else None)
        shutil.copy2(files["role_probe"], workspace / "probe/netbench")
        terminal.save(
            folder / "plan.json",
            {
                "mtu": mtu,
                **page_meta,
                **({"node_sqlite": True} if node_sqlite else {}),
                "build": build["worker_executable_sha256"],
                **({"boot_steering": "worker", "guest_publication_sha256": build["guest_publication_script_sha256"]}
                   if published_rps else {}),
                "host": cli(["hostname"]),
                "scope": str(runner.root),
                "baseline": check_baseline(),
                **({"parent_only_gso": 40960} if probe_gso_inheritance else {}),
                **({"docker_tcp_queues": True, "guest_runner_sha256": build["guest_runner_sha256"]} if docker_tsq else {}),
                **({"docker_cpu_sets": True, "guest_runner_sha256": build["guest_runner_sha256"]} if docker_cpuset else {}),
                **({"worker_gso_bytes": worker_gso, "guest_runner_sha256": build["guest_runner_sha256"]}
                   if worker_gso else {}),
                **({"guest_runner_sha256": guest_runner_sha} if current_runner else {}),
                **({"guest_start_sha256": terminal.digest(guest_start), "verified_oom_watch": True,
                    "guest_start_origin": "packaged" if packaged_start else "current source"} if oom else {}),
            },
        )
        print(f"Starting private worker with requested MTU {mtu}", flush=True)
        try:
            scope, _facts = runner.arm(
                "a",
                4 if product else 2,
                files,
                workspace,
                oci,
                process_type="Standard",
                publication_mtu=mtu,
                product_mtu=product is not None,
                relay_mode="kqueue-throughput" if product else "kqueue-interactive",
                profile_relay=profile_relay,
                published_rps=published_rps,
                published_gso_bytes=worker_gso, anon_thp_16k=mthp_policy,
            )
        finally:
            if (workspace / "private-link.txt").is_file():
                shutil.copy2(workspace / "private-link.txt", folder / "guest-link.txt")
        if mthp_dir:
            build_thp.check_boot(workspace, folder, mthp_policy, _facts)
        if live_pages:
            identity, docker = service_preflight.identity(scope, build, mtu)
            actual = json.loads(cli(docker, "exec", identity["container"], "/mpcheck/pagecompat", "-dir", "/",
                                    "-expect-page", str(live_pages * 1024)))
            build_pages.validate_mappings(actual, live_pages)
            boot_facts = _facts.read_text().splitlines()
            kernel_path = Path(json.loads((runner.root / "a/worker.json").read_bytes())["kernel"])
            require(kernel_path == files["kernel"] and terminal.digest(kernel_path) == page_meta["kernel_image_sha256"]
                    and "config_sha256=" + page_meta["kernel_config_sha256"] in boot_facts,
                    "packaged worker ran a different kernel")
            terminal.save(folder / "kernel-page-runtime.json",
                          {"container": identity["container"], "mapping": actual, **page_meta})
            if node_sqlite:
                import node_pages
                node_pages.check(folder, workspace, runner, admission, docker, live_pages)
        if guest_only:
            guest_repair_only(folder, workspace, scope, build, mtu, oom=oom,
                              monitor=control, gso_bytes=worker_gso, docker_tsq=docker_tsq, docker_cpuset=docker_cpuset)
            if probe_gso_inheritance:
                parent = re.search(r"\bgso_ipv4_max_size (\d+)", (folder / "guest-link.txt").read_text())
                children = re.findall(r"\bgso_ipv4_max_size (\d+)", (folder / "repair-owned-links").read_text())
                require(parent and int(parent[1]) == 40960 and len(children) == 32, "incomplete child GSO readback")
                terminal.save(folder / "gso-inheritance.json", {"parent": int(parent[1]),
                    "child_limits": list(map(int, children))})
                if current_runner:
                    require(set(children) == {"40960"}, "new private services lost the parent's IPv4 GSO limit")
            if published_rps:
                initial = (folder / "guest-link.txt").read_text().splitlines()
                repair_record = json.loads((folder / "link-repair.json").read_bytes())
                require("requested_rps=off-irq" in initial and "rx0_rps=7" in initial
                        and repair_record["publication_queue_after"][1] == "7", "missing native steering after repair")
            return
        identity, docker = prove_running(scope, folder, workspace, build, mtu, secret)
        if repair:
            verify_repair(folder, workspace, scope, build, mtu)
        terminal.save(folder / "identity.json", identity)
        (workspace / "trace-now").touch()
        time.sleep(0.3)
        conn = http.client.HTTPConnection(identity["endpoint"], timeout=6)
        try:
            conn.request("GET", "/id")
            require(conn.getresponse().read().decode() == identity["name"], "wrong published marker")
            ss = cli(
                docker,
                "exec",
                identity["container"],
                "/mpcheck/ss",
                "-Htin",
                "state",
                "established",
                "( sport = :8080 )",
            )
            (folder / "guest-socket.txt").write_text(ss)
            conn.request("GET", "/data")
            reply = conn.getresponse()
            body = reply.read((8 << 20) + 1)
            require(
                reply.status == 200
                and hashlib.sha256(body).digest() == hashlib.sha256(b"micropod" * (1 << 20)).digest(),
                "wrong published body",
            )
        finally:
            conn.close()
            deadline = time.monotonic() + 10
            while not (workspace / "nft-after").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            for name in ("nft-before", "nft-after", "eth1-trace"):
                if (workspace / name).exists():
                    shutil.copy2(workspace / name, folder / name)
    finally:
        runner.tearing_down = True
        runner.cleanup()
        terminal.save(
            folder / "verification.json",
            {"baseline_files": check_baseline(), "extra_cleanup_errors": runner.errors},
        )
        require(not runner.errors and not runner.root.exists(), "private cleanup failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mtu", type=int, choices=(1500, 9000), required=True)
    parser.add_argument("--product-build", type=Path)
    parser.add_argument("--mthp-kernel", type=Path)
    parser.add_argument("--mthp-16k", choices=("never", "always"))
    parser.add_argument("--node-sqlite", action="store_true", help="verify a WAL database across both guest kernels")
    parser.add_argument("--page-kernel-pair", type=Path)
    parser.add_argument("--page-kib", type=int, choices=(4, 16))
    parser.add_argument("--verify-link-repair", action="store_true")
    parser.add_argument("--boot-steering", action="store_true")
    parser.add_argument("--verify-oom-watch", action="store_true")
    parser.add_argument("--probe-gso-inheritance", action="store_true")
    parser.add_argument("--current-guest-runner", action="store_true")
    parser.add_argument("--worker-gso-bytes", type=int, choices=(32768, 40960))
    parser.add_argument("--verify-docker-tsq", action="store_true")
    parser.add_argument("--verify-docker-cpuset", action="store_true")
    parser.add_argument(
        "--guest-repair-only",
        action="store_true",
        help="check 32 resident service interfaces over the guest control socket",
    )
    parser.add_argument(
        "--profile-relay", action="store_true", help="collect per-listener setup and TCP error counters"
    )
    args = parser.parse_args()
    path = Path(
        tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-") + "private-link-", dir=HERE)
    )
    print(path, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    state = {"complete": False, "mtu": args.mtu, "guest_repair_only": args.guest_repair_only}
    try:
        with terminal.terminal_lock():
            require(not args.verify_oom_watch or args.guest_repair_only, "OOM attribution needs the native guest cohort")
            require(not args.probe_gso_inheritance or args.guest_repair_only, "GSO inheritance needs 32 native services")
            require(not args.current_guest_runner or args.probe_gso_inheritance, "guest runner control needs GSO readback")
            require(not args.worker_gso_bytes or args.guest_repair_only, "native GSO fault needs the guest cohort")
            require(not args.verify_docker_tsq or args.guest_repair_only, "Docker queue validation needs the guest cohort")
            require(not args.verify_docker_cpuset or args.guest_repair_only, "Docker CPU placement needs the guest cohort")
            require(
                not (args.verify_link_repair or args.guest_repair_only)
                or args.product_build
                and args.mtu == 9000,
                "repair needs a jumbo production build",
            )
            run(
                path,
                args.mtu,
                args.product_build,
                args.verify_link_repair or args.guest_repair_only,
                args.profile_relay,
                args.guest_repair_only,
                args.boot_steering,
                args.verify_oom_watch,
                args.probe_gso_inheritance,
                args.current_guest_runner,
                args.worker_gso_bytes,
                args.verify_docker_tsq,
                args.verify_docker_cpuset,
                args.page_kernel_pair, args.page_kib, args.node_sqlite, args.mthp_kernel, args.mthp_16k,
            )
        state["complete"] = True
    except BaseException as exc:
        state["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(path / "status.json", dict(state, end=terminal.now()))
