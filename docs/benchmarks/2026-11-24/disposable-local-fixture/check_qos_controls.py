"""Exercise the local host-role pairing and the real signed plist renderer without starting a VM."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

import local_qos as q
import local_terminal as terminal


def check():
    build = q.signed_worker(terminal.PREVIOUS / "revised-runtime-build.json")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        jobs, fixtures = {}, {}
        for i, (arm, expected) in enumerate(q.ROLES.items()):
            home = root / arm.lower()
            home.mkdir()
            env = {k: v for k, v in os.environ.items() if not k.startswith(("MICROPOD_", "DOCKER_"))}
            env.update(MICROPOD_CI_HOME=str(home), MICROPOD_CI_ENGINE="containerd", MICROPOD_CI_PORT_RELAY="kqueue-interactive",
                       MICROPOD_CI_CPUS="4", MICROPOD_CI_MEMORY_MIB="4096", MICROPOD_CI_PORT_RELAY_WORKERS="2")
            job = plistlib.loads(subprocess.check_output([build["worker_executable"], "ci", "launch-agent"], env=env))
            job["ProcessType"] = expected
            job["Label"] = arm
            jobs[arm] = job
            # A synthetic live readback exercises normalization; only launchctl can confirm a running role.
            live = "\n".join([f"pid = {100 + i}", f"spawn type = {q.role.SPAWN_TYPES[expected]}",
                              *(f"{k} => {v}" for k, v in job["EnvironmentVariables"].items())])
            fixture = q.role.verify_job(job, live, 100 + i, home, expected)
            fixture.update(cpus=4, cpuset="0-3", relay_workers=2, callback_events=128, read_bytes=262144,
                           image_config="same-image", kernel_image_sha256=q.relay.STOCK_KERNEL,
                           guest_config_sha256="same-config", cli_sha256=build["worker_executable_sha256"],
                           engine_version="same-engine", route=q.relay.DIRECT_ROUTE, service_env_sha256="same-env",
                           service_limits={"cpu.max": "400000 100000"}, release="7.3.5-micropod",
                           vmm_executable="/same-vmm", guest_probe_sha256=q.role.GUEST_PROBE_SHA256,
                           guest_probe_mount={"source":"HostConfig.Mounts", "target":"/mpcheck",
                                              "bind_source":str(root/"probe"), "readonly":True},
                           mapped_relay_build={"source_revision": build["source_revision"]}, boot=arm, guest_boot=arm,
                           pids={"relay": 100+i, "vmm": 200+i}, births={100+i: 1700, 200+i: 1800})
            fixture.update({k: k+arm for k in ("instance", "worker", "engine", "id", "name", "address")})
            fixtures[arm] = fixture
        q.compare_fixtures(fixtures)
        negative = []
        for key, value in (("relay_workers", 4), ("callback_events", 24), ("read_bytes", 65536),
                           ("spawn_type", q.role.SPAWN_TYPES["Standard"]), ("job_controls_sha256", "extra-control"),
                           ("guest_probe_mount", {"source": "Mounts", "target": "/mpcheck", "readonly": True}),
                           ("guest_boot", "A"), ("pids", fixtures["A"]["pids"]), ("mapped_relay_build", {})):
            changed = deepcopy(fixtures)
            changed["B"][key] = value
            try:
                q.compare_fixtures(changed)
            except ValueError:
                negative.append(key)
            else:
                raise ValueError("accepted a contaminated fixture: " + key)
    print(json.dumps({"evidence_tier": "source/fixture only", "signed_stock": build["worker_executable_sha256"],
                      "stock_revision": build["source_revision"], "render": "actual signed ci launch-agent",
                      "live_readback": "synthetic for validation", "accepted": list(q.ROLES.values()),
                      "rejected_controls": negative, "VMs_started": 0, "clients_started": 0,
                      "adapter_sha256": hashlib.sha256(Path(q.__file__).read_bytes()).hexdigest()}, indent=2))


if __name__ == "__main__":
    check()
