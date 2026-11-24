"""Exercise the shipping publisher's ownership check against one archived endpoint."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
REVISION = "7d9b565173a901cb18942e00384838da96e0ba98"
ARCHIVE = "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
PUBLISHER = "guest/runner/docker_port_direct_linux.go"
DRIVER = "drivers/net/ipvlan/ipvlan_main.c"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def from_git(path):
    return subprocess.check_output(["git", "show", f"{REVISION}:{path}"], cwd=ROOT)


def recorded_link(state, rules):
    mac = r"([0-9a-f]{2}(?::[0-9a-f]{2}){5})"
    parent = re.search(r"eth1:.*?link/ether " + mac, rules, re.S)[1]
    port, expected = re.search(r"map listeners \{.*?elements = \{ (\d+) : " + mac, rules, re.S).groups()
    observed = state["interfaces"]["mppub0"]["mac"]
    return {"port": int(port), "expected": expected, "observed": observed, "parent": parent}


def run(kernel_tree):
    source = (kernel_tree / DRIVER).read_bytes()
    assert digest(source) == "eef07b562f696ce552a56cda013231d0a19d6eb100e5e9ddd95e785941f8c094"
    inherit = "eth_hw_addr_set(dev, phy_dev->dev_addr);"
    assert source.decode().count(inherit) == 1
    rules = from_git(PUBLISHER)
    predicate = re.search(r"if (!strings.EqualFold\(end\.link\.Attrs\(\)\.HardwareAddr\.String\(\), end\.mac\.String\(\)\)) \{", rules.decode())[1]
    assert 'return end, errors.New("published interface ownership mismatch")' in rules.decode()
    raw = from_git(ARCHIVE)
    assert digest(raw) == "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
    recording = json.loads(gzip.decompress(raw))
    worker = recording["records"]["workers"]["trial"]
    before = recorded_link(worker["state"], worker["root-before"])
    after = recorded_link(worker["after"], worker["root-after"])
    assert before == after and before["observed"] != before["parent"]
    with tempfile.TemporaryDirectory() as scratch:
        wd = Path(scratch)
        # Pass six octets through the pinned driver's address assignment.
        octets = ",".join("0x" + octet for octet in before["parent"].split(":"))
        (wd / "inherit.c").write_text("""
#include <stdio.h>
#include <string.h>
struct device { unsigned char dev_addr[6]; };
static void eth_hw_addr_set(struct device *d, const unsigned char *addr) { memcpy(d->dev_addr, addr, 6); }
int main(void) {
    struct device child = {0}, parent = {{PARENT}};
    struct device *dev = &child, *phy_dev = &parent;
    INHERIT
    for (int i = 0; i < 6; i++) printf("%s%02x", i ? ":" : "", child.dev_addr[i]);
}
""".replace("PARENT", octets).replace("INHERIT", inherit))
        subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "inherit.c", "-o", "inherit"], cwd=wd, check=True)
        shared = subprocess.check_output([wd / "inherit"], text=True)
        assert shared == before["parent"]
        (wd / "ownership.go").write_text("""
package main
import ("fmt"; "net"; "os"; "strings")
type linkAttrs struct { HardwareAddr net.HardwareAddr }
func (a linkAttrs) Attrs() linkAttrs { return a }
type endpoint struct { mac net.HardwareAddr; link linkAttrs }
func main() {
    expected, e := net.ParseMAC(os.Args[1]); if e != nil { panic(e) }
    for _, input := range os.Args[2:] {
        observed, e := net.ParseMAC(input); if e != nil { panic(e) }
        end := endpoint{expected, linkAttrs{observed}}
        if PREDICATE { fmt.Println("ownership mismatch") } else { fmt.Println("admit") }
    }
}
""".replace("PREDICATE", predicate))
        go_env = dict(os.environ, GOMAXPROCS="1", CGO_ENABLED="0", GOPROXY="off", GOTOOLCHAIN="local")
        go_env.pop("GOROOT", None)
        outcomes = subprocess.check_output(["go", "run", "ownership.go", before["expected"], before["observed"], shared], cwd=wd, text=True, env=go_env).splitlines()
    assert outcomes == ["admit", "ownership mismatch"]
    return {"stable_id": "233.02", "date_local": "2026-11-24", "evidence_tier": "source/fixture",
            "source_revision": REVISION, "archived_recording_base": recording["baseline_commit"],
            "archive_sha256": digest(raw), "archive": ARCHIVE, "record": "records.workers.trial",
            "boot": worker["boot.json"]["boot"], "pinned_linux_version": "7.3.5",
            "kernel_tar_xz_sha256": recording["kernels"]["source_sha256"],
            "kernel_member": DRIVER, "kernel_member_sha256": digest(source), "publisher_sha256": digest(rules),
            "driver_assignment_compiled": inherit, "publisher_rejection_compiled": predicate,
            "endpoint": before, "endpoint_same_at_both_boundaries": True,
            "paired_endpoints": 1, "first_outcomes": [
                {"arm": "recorded private macvlan", "observed": before["observed"], "result": outcomes[0]},
                {"arm": "modeled ipvlan child address from pinned driver", "observed": shared, "result": outcomes[1]}],
            "limitations": "One archived lease. No ipvlan device, network traffic, timing or statistical estimate."}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("kernel_tree", type=Path)
    print(json.dumps(run(p.parse_args().kernel_tree), indent=2))
