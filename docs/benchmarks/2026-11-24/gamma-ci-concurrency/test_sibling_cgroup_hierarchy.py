import json
import unittest

import sibling_cgroup_hierarchy as hierarchy


def fixture(private_parents=False):
    boot = "boot-under-test"
    jobs, requests, memberships, groups = [], [], {}, {}
    parent_files = {"cgroup.subtree_control": "cpu cpuset"}
    groups["/"] = {"inode": 1, "children": 1, "files": parent_files}
    groups["/k8s.io"] = {"inode": 2, "children": 32 if private_parents else 64, "files": parent_files}
    for idx in range(64):
        cid, name = f"{idx:064x}", f"test-{idx}"
        mask = str(idx % 4)
        slot, group = idx % 32, f"job-{idx % 32:02}"
        parent = f"/k8s.io/{group}" if private_parents else "/k8s.io"
        if private_parents:
            groups[parent] = {"inode": 1000 + slot, "children": 2, "files": parent_files}
        path = parent + "/" + cid
        inode = idx + 10
        files = {"cpu.max": "100000 100000", "cpuset.cpus.effective": mask, "memory.max": "134217728", "pids.max": "64"}
        resident = {"pid": 1, "pid_namespace": f"pid:[{idx + 10}]", "birth_ticks": idx + 1,
                    "argv": ["/netbench", "-listen", ":8080", "-marker", name], "cgroup": "0::/"}
        jobs.append({"id": cid, "name": name, "mask": mask, "affinity": resident, "cgroup": files,
                     "cpu_group": group, "placement_source": "native-group"})
        requests.append({"id": cid, "leaf": {"inode": inode, "resident": resident, "boot": boot}})
        memberships[cid] = {"id": cid, "path": path, "resident": {**resident, "pid": 200 + idx, "cgroup": "0::" + path}}
        groups[path] = {"inode": inode, "children": 0, "files": {**files, "cpu.weight": "100",
                                 "cgroup.type": "domain", "cgroup.controllers": "cpu cpuset", "cgroup.events": "populated 1"}}
    observer = {"self_cgroup_namespace": "cgroup:[231]", "init_cgroup_namespace": "cgroup:[231]",
                "mountinfo": "61 53 0:28 / /sys/fs/cgroup rw - cgroup2 none rw"}
    return {"jobs": jobs}, requests, {"boot": boot, "observer": observer, "memberships": memberships, "groups": groups}, boot


def stock_receipt(job, leaf):
    def sample(proc, runtime, uid=0, ppid=0):
        return {"boot": leaf["boot"], "inode": leaf["inode"], "cpu.max": job["cgroup"]["cpu.max"],
                "policy": 0, "nice": 0, "priority": 0, "slice_ns": runtime, "process": proc,
                "status": {"Uid": " ".join([str(uid)] * 4), "CapEff": "0", "CapPrm": "0", "CapAmb": "0",
                           "NoNewPrivs": "1", "Cpus_allowed_list": job["mask"], "PPid": str(ppid)}}

    resident = leaf["resident"]
    shell = {**resident, "pid": 24}
    return {
        "shell_before": sample(shell, hierarchy.BASE_NS),
        "shell_after": sample(shell, hierarchy.BASE_NS),
        "resident_before": sample(resident, hierarchy.BASE_NS),
        "resident_after": sample(resident, hierarchy.BASE_NS),
        "launcher_sha256": "a" * 64,
        "setpriv_path": "/usr/bin/setpriv",
        "setpriv_version": "setpriv from util-linux 2.38.1",
        "chrt_path": "/usr/bin/chrt",
        "chrt_version": "chrt from util-linux 2.38.1",
        "control_exit": "0",
        "control": sample({**shell, "pid": 50}, hierarchy.BASE_NS, uid=65534),
        "chrt_exit": "1",
        "launcher_exit": "0",
        "launcher": sample({**shell, "pid": 51}, hierarchy.LONG_NS, uid=65534, ppid=24),
        "launcher_child": sample({**shell, "pid": 52}, hierarchy.LONG_NS, uid=65534, ppid=51),
    }


def text(receipt):
    return "\n".join(f"{key}\t{json.dumps(value) if isinstance(value, dict) else value}" for key, value in receipt.items())


class HierarchyTest(unittest.TestCase):
    def test_shared_and_private_hierarchies(self):
        shared = hierarchy.check_topology(*fixture())
        self.assertEqual(shared["common_cpu_parents"], ["/k8s.io"])
        self.assertEqual(shared["measured_leaves"], 64)
        self.assertEqual(shared["separate_pair_parents"], 0)
        self.assertEqual({row["parent_measured_leaves"] for row in shared["pairs"]}, {64})

        separate = hierarchy.check_topology(*fixture(private_parents=True))
        self.assertEqual(separate["separate_pair_parents"], 32)
        self.assertEqual({row["parent_measured_leaves"] for row in separate["pairs"]}, {2})

    def test_wrong_namespace_and_inode_are_rejected(self):
        inventory, requests, tree, boot = fixture()
        tree["observer"]["self_cgroup_namespace"] = "cgroup:[232]"
        with self.assertRaisesRegex(ValueError, "initial cgroup namespace"):
            hierarchy.check_topology(inventory, requests, tree, boot)
        tree["observer"]["self_cgroup_namespace"] = tree["observer"]["init_cgroup_namespace"]
        requests[0]["leaf"]["inode"] += 1
        with self.assertRaisesRegex(ValueError, "evidence disagree"):
            hierarchy.check_topology(inventory, requests, tree, boot)

    def test_stock_and_unprivileged_launcher_results_are_independent(self):
        inventory, requests, _, _ = fixture()
        job, leaf = inventory["jobs"][0], requests[0]["leaf"]
        receipt = stock_receipt(job, leaf)
        proof = hierarchy.check_stock(text(receipt), job, leaf, receipt["launcher_sha256"])
        self.assertEqual(proof["stock"], {"status": "rejected", "exit": 1})
        self.assertEqual(proof["launcher"]["status"], "verified")
        self.assertEqual(proof["launcher"]["child_slice_ns"], hierarchy.LONG_NS)

        receipt["launcher_child"]["status"]["PPid"] = "1"
        with self.assertRaisesRegex(ValueError, "child did not inherit"):
            hierarchy.check_stock(text(receipt), job, leaf, receipt["launcher_sha256"])
        receipt["launcher_child"]["status"]["PPid"] = "51"
        receipt["launcher_child"]["status"]["CapAmb"] = "10"
        with self.assertRaisesRegex(ValueError, "retained privileges"):
            hierarchy.check_stock(text(receipt), job, leaf, receipt["launcher_sha256"])


if __name__ == "__main__":
    unittest.main()
