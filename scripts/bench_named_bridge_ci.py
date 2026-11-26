#!/usr/bin/env python3
"""Time eight stock Docker jobs sharing one named bridge on two explicit sockets."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import statistics
import threading
import time

from qualify_docker_network_membership import Membership, SERVICE, VERSION
from qualify_engine_api import Engine
from qualify_testcontainers_go import checked_image, require

JOBS = 8


def redirects(engine):
    status, _, data = engine.request("GET", "/micropod/metrics", versioned=False)
    if status != 200:
        return None
    return json.loads(data).get("network", {}).get("sandbox_dns_redirect")


class Wave(Membership):
    def __init__(self, engine):
        super().__init__(engine, "wave")
        self.nets = {"a": self.nets["a"]}
        self.names = {i: f"{self.scope}-job-{i}" for i in range(JOBS)}

    def launch(self, slot, start):
        name = self.names[slot]
        start.wait(timeout=5)
        _, identity = self.cli("run", "--detach", "--rm", "--pull=never", "--name", name,
                               "--label", self.label, "--network", self.nets["a"],
                               "--network-alias", name + "-alias", "--cpus", "0.5", "--memory", "256m",
                               "--env", "MARK=" + name, "--entrypoint", "/bin/sh", self.engine.image, "-ec", SERVICE)
        require(re.fullmatch("[0-9a-f]{64}", identity), "Expected a full Docker container ID")
        return identity

    def fetch(self, slot):
        # Reach each owner through the DNS name for its neighbour. Retry only
        # application readiness and count the retries in the end-to-end clock.
        peer = self.names[(slot + 1) % JOBS]
        for _ in range(10):
            rc, body = self.cli("exec", self.ids[slot], "wget", "-qO-", "-T", "1", "-t", "1",
                                "http://" + peer + "-alias:8080/owned", ok=False)
            if rc == 0 and body == peer:
                return body
            time.sleep(.04)
        raise RuntimeError("Failed alias HTTP from " + self.names[slot] + " to " + peer)

    def measure(self):
        sample = {"scope": self.scope, "history": self.history}
        try:
            require(not self.inventory("containers") and not self.inventory("networks"), "Scope collision")
            self.cli("network", "create", "--driver", "bridge", "--label", self.label, self.nets["a"])
            with ThreadPoolExecutor(max_workers=JOBS) as pool:
                ready = threading.Barrier(JOBS + 1)
                starts = [pool.submit(self.launch, slot, ready) for slot in self.names]
                start_ns = time.monotonic_ns()
                ready.wait(timeout=5)
                self.ids = {slot: future.result() for slot, future in zip(self.names, starts)}
                require(len(set(self.ids.values())) == JOBS, "Container ID collision")
                launched_ns = time.monotonic_ns()
                bodies = list(pool.map(self.fetch, self.names))
                http_ns = time.monotonic_ns()
                require(set(bodies) == set(self.names.values()), "Did not reach all eight services")
                require(set(self.inventory("containers")) == set(self.ids.values()), "Incomplete labelled job inventory")
                list(pool.map(lambda identity: self.cli("rm", "--force", identity), self.ids.values()))
            sample.update(ids=self.ids, bodies=bodies, launch_ms=(launched_ns - start_ns) / 1e6,
                          all_http_ms=(http_ns - start_ns) / 1e6)
        except Exception as exc:
            sample["error"] = f"{type(exc).__name__}: {exc}"
        finally:
            try:
                sample["remaining"] = self.cleanup()
                if "all_http_ms" in sample:
                    sample["through_cleanup_ms"] = (time.monotonic_ns() - start_ns) / 1e6
            except Exception as exc:
                sample["cleanup_error"] = f"{type(exc).__name__}: {exc}"
        return sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-socket", required=True, type=Path)
    parser.add_argument("--orb-socket", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=4)
    args = parser.parse_args()
    sockets = {"native": args.native_socket, "orb": args.orb_socket}
    require(not args.out.exists() and args.native_socket.resolve() != args.orb_socket.resolve() and
            all(s.is_socket() for s in sockets.values()) and 1 <= args.pairs <= 12,
            "Expected separate live sockets, a fresh output path and 1–12 pairs")
    engines = {k: Engine(s, args.image, None, None, api_version=VERSION) for k, s in sockets.items()}
    before = {k: checked_image(e, args.image) for k, e in engines.items()}
    layers = before["native"]["RootFS"]
    digests = {k: {name.rsplit("@", 1)[-1] for name in image["RepoDigests"] or []} for k, image in before.items()}
    require(layers == before["orb"]["RootFS"] and layers.get("Type") == "layers" and layers.get("Layers")
            and digests["native"] == digests["orb"] and digests["native"]
            and all(re.fullmatch("sha256:[0-9a-f]{64}", d) for d in digests["native"]),
            "Preloaded repository digests or uncompressed layers differ")
    report = {"api": VERSION, "jobs_per_wave": JOBS, "cpus_per_job": .5, "memory_mib_per_job": 256,
              "sockets": {k: str(s) for k, s in sockets.items()}, "images": before, "pairs": []}
    for index in range(args.pairs):
        order = list(engines) if index % 2 == 0 else list(reversed(engines))
        pair = {"order": order}
        report["pairs"].append(pair)
        for k in order:
            dns_start = redirects(engines[k]) if k == "native" else None
            sample = pair[k] = Wave(engines[k]).measure()
            if dns_start is not None:
                dns_end = redirects(engines[k])
                require(dns_end is not None, "Lost native DNS installation counters")
                sample["dns_install_delta"] = {key: dns_end[key] - initial for key, initial in dns_start.items()}
            args.out.write_text(json.dumps(report, indent=2) + "\n")
            require("error" not in sample and "cleanup_error" not in sample,
                    str(sample.get("error") or sample.get("cleanup_error")))
    after = {k: checked_image(e, args.image) for k, e in engines.items()}
    require(before == after, "Preloaded image changed")
    report["median_ms"] = {k: {metric: statistics.median(p[k][metric] for p in report["pairs"])
                               for metric in ("launch_ms", "all_http_ms", "through_cleanup_ms")} for k in engines}
    args.out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
