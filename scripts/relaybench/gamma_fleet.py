"""Convert a hosted Cuttlefish runners-list result to the Gamma pilot fleet format."""
import argparse
import json
from pathlib import Path


GAMMA_MAC = "Gamma-128GB.local"
GAMMA_LINUX = "Gamma-128GB Linux CI (isolated VM)"


def hosted_export(snapshot):
    if snapshot.get("project") != "cuttlefish" or snapshot.get("truncated") is not False:
        raise ValueError("need a complete runners-list result from the cuttlefish project")
    if "runners" in snapshot or "generatedAt" in snapshot:
        raise ValueError("ambiguous hosted and native fleet fields")
    runners = []
    for name in (GAMMA_MAC, GAMMA_LINUX):
        matches = [rig for rig in snapshot["rigs"] if rig["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"missing or ambiguous Gamma runner: {name}")
        rig = matches[0]
        leases = rig.get("leasedSlots")
        capacity = rig.get("capacity")
        if type(leases) is not int or type(capacity) is not int or not 0 <= leases <= capacity or capacity < 1:
            raise ValueError(f"unknown or invalid lease count or capacity: {name}")
        # An online connection can still carry a lease or have stale status.
        ready = rig["state"] == "online" and rig["snapshotFreshness"] == "fresh" and rig["acceptingWork"] is True
        runners.append({"connection": rig["connectionState"], "runner": {
            "displayName": name, "active": ready, "activeLeases": leases,
            "capacity": capacity, "lastSeenAt": rig["lastSeenAt"],
        }})
    return {"generatedAt": snapshot["serverTime"], "runners": runners}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path, help="Cuttlefish runners-list structured JSON for the cuttlefish project")
    args = parser.parse_args()
    try:
        fleet = hosted_export(json.loads(args.snapshot.read_text()))
    except (KeyError, TypeError, ValueError, OSError) as error:
        parser.exit(2, f"Invalid hosted fleet response: {error}\n")
    print(json.dumps(fleet, indent=2))
