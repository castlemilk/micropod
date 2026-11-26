"""Package the private file-fault-around bootstrap around the sealed signed worker."""

import argparse
import difflib
import hashlib
import json
import os
import plistlib
import stat
import subprocess
import tarfile
import tempfile
from pathlib import Path

from build_delivery import BASE, HERE, ROOT, digest
from build_pages import SOURCE_SHA
import build_ipvlan
import file_fault_around_common as fixture
import kernel_candidate


PARENT = HERE / "sibling-job-parent-product.json"
MANIFEST = HERE / "sibling-file-fault-around-product.json"
STOCK_KERNEL = ROOT / ".build/local-kernel-pages/20261124T192542Z-cny_trn8"
IPVLAN_KERNEL = ROOT / ".build/local-kernel-pages/20261124T233020Z-ipvlan-my8pf7su"
EXPECTED_IMAGE = "488a83549377f9abcabfc44a9021f1451c9ed903f85f66f910e296c7ab2327ab"
EXPECTED_CONFIG = "790fe9a014f3501117af37df8163a39da1617e37a84996f0e605325c3b07a24c"
SOURCE = "ci/runner/start.sh"
GUEST_START = "runner/start.sh"
TOOLS = "micropod-oci-tools"
ENTITLEMENTS = {"com.apple.security.virtualization": True}
KCONFIG = {"CONFIG_DEBUG_FS": "y", "CONFIG_DEBUG_FS_ALLOW_ALL": "y", "CONFIG_IKCONFIG": "y",
           "CONFIG_ARM64_16K_PAGES": "y", "CONFIG_PAGE_SHIFT": "14", "CONFIG_IPVLAN": "y",
           "CONFIG_PROC_PAGE_MONITOR": "y", "CONFIG_TRANSPARENT_HUGEPAGE": "n"}
SOURCE_CLAIMS = {
    "arch/arm64/include/asm/pgtable-hwdef.h": ("#define PTDESC_ORDER 3", "(PAGE_SHIFT - PTDESC_ORDER)",
                                             "(1 << PTDESC_TABLE_SHIFT)"),
    "mm/memory.c": ("fault_around_pages __read_mostly =\n\t65536 >> PAGE_SHIFT;",
                    "debugfs_create_file_unsafe(\"fault_around_bytes\", 0644, NULL, NULL,",
                    "*val = fault_around_pages << PAGE_SHIFT;", "val / PAGE_SIZE > PTRS_PER_PTE",
                    "val = max(val, PAGE_SIZE);", "rounddown_pow_of_two(val) >> PAGE_SHIFT",
                    "ALIGN_DOWN(pte_off, nr_pages)", "vmf->vma->vm_ops->map_pages(vmf,",
                    "return fault_around_pages > 1;", "ret = do_fault_around(vmf);"),
    "mm/filemap.c": ("vm_fault_t filemap_map_pages(", "end_pgoff = min(end_pgoff, file_end);",
                     "next_uptodate_folio(&xas, mapping, end_pgoff);", "filemap_map_pages,"),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_bytes())


def encode(data):
    return (json.dumps(data, indent=2, sort_keys=True) + "\n").encode()


def kernel_proof(control=STOCK_KERNEL, ipvlan=IPVLAN_KERNEL):
    build = build_ipvlan.verify_build(ipvlan, control)
    image = build["candidate"]
    require(image["image_sha256"] == EXPECTED_IMAGE and image["config_sha256"] == EXPECTED_CONFIG
            and image["embedded_config_verified"] and image["page_kib"] == 16,
            "wrong matched IPvlan kernel for file fault-around")
    config = kernel_candidate.config_options((ipvlan / build_ipvlan.PROFILE / "config").read_bytes())
    require({key: config.get(key) for key in KCONFIG} == KCONFIG, "required 16 KiB kernel settings differ")
    hashes = {}
    with tarfile.open(control / "linux-7.3.5.tar.xz", "r|xz") as archive:
        for entry in archive:
            name = entry.name.removeprefix("linux-7.3.5/")
            if name not in SOURCE_CLAIMS:
                continue
            data = archive.extractfile(entry).read()
            require(all(token.encode() in data for token in SOURCE_CLAIMS[name]), f"unexpected kernel code: {name}")
            hashes[name] = hashlib.sha256(data).hexdigest()
            if hashes.keys() == SOURCE_CLAIMS.keys():
                break
    require(hashes.keys() == SOURCE_CLAIMS.keys(), "missing exact fault-around kernel source")
    return {"source_tar_sha256": SOURCE_SHA, "source_files_sha256": hashes, "release": build_ipvlan.RELEASE,
            "image_sha256": EXPECTED_IMAGE, "config_sha256": EXPECTED_CONFIG, "kconfig": KCONFIG,
            "embedded_config_verified": True, "debugfs_file": "fault_around_bytes",
            "page_size_bytes": fixture.PAGE_BYTES, "default_window_bytes": fixture.DEFAULT_BYTES,
            "allowed_windows_bytes": list(fixture.WINDOWS), "maximum_effective_window_bytes": 32 * 1024**2,
            "ptes_per_page_table": 2048}


def tree_hash(root, except_file):
    rows = []
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if name == except_file:
            continue
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            value = os.readlink(path)
        elif stat.S_ISREG(mode):
            value = digest(path)
        elif stat.S_ISDIR(mode):
            value = None
        else:
            raise ValueError(f"unexpected packaged input type {name}")
        rows.append([name, mode, value])
    return hashlib.sha256(encode(rows)).hexdigest()


def verify_signed(scope, record):
    exe = scope / "micropod"
    require(record["worker_executable"] == str(exe) and digest(exe) == record["worker_executable_sha256"],
            "unexpected signed worker bytes or location")
    subprocess.run(["codesign", "--verify", "--strict", exe], check=True)
    actual = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", exe],
                                     stderr=subprocess.DEVNULL)
    require(plistlib.loads(actual) == record["entitlements"] == ENTITLEMENTS, "signed worker entitlements differ")


def verify_inputs(scope, record):
    verify_signed(scope, record)
    files = {"worker.patch": "patch_sha256", "build.log": "build_log_sha256",
             f"{TOOLS}/runner/published-ports.sh": "guest_publication_script_sha256",
             f"{TOOLS}/runner/bin/job": "guest_runner_sha256", f"{TOOLS}/{GUEST_START}": "guest_start_sha256"}
    require(all(digest(scope / path) == record[key] for path, key in files.items())
            and record["compiled_sources"][SOURCE] == record["guest_start_sha256"]
            and all(digest(scope / "src" / path) == expected for path, expected in record["compiled_sources"].items()),
            "sealed worker and guest inputs differ")


def clone(src, dst):
    subprocess.run(["/bin/cp", "-cR", src, dst], check=True)


def package():
    parent = read(PARENT)
    previous = Path(parent["current_product"]).resolve()
    old_scope, old = previous.parent, read(previous)
    require(previous.name == "product.json" and old_scope.parent == BASE
            and old["base_revision"] == parent["base_revision"]
            and old["worker_executable_sha256"] == parent["host_sha256"]
            and old["guest_runner_sha256"] == parent["new_guest_sha256"]
            and old["guest_start_sha256"] == parent["bootstrap_sha256"]
            and old["patch_sha256"] == parent["patch_sha256"], "wrong sealed parent for the fault-around fixture")
    verify_inputs(old_scope, old)
    proof = kernel_proof()
    original = (old_scope / "src" / SOURCE).read_bytes()
    changed = fixture.patch_start(original)
    subprocess.run(["/bin/sh", "-n"], input=changed, check=True)
    fragment = fixture.BOOTSTRAP.encode()
    delta = "".join(difflib.unified_diff(original.decode().splitlines(keepends=True),
                                         changed.decode().splitlines(keepends=True),
                                         "a/" + SOURCE, "b/" + SOURCE)).encode()
    patch = (old_scope / "worker.patch").read_bytes() + delta
    scope_key = hashlib.sha256(previous.read_bytes() + b"\0" + changed + b"\0" + encode(proof)).hexdigest()[:16]
    scope = BASE / f"ci-published-link-{scope_key}"
    product = scope / "product.json"
    boot_sha = hashlib.sha256(changed).hexdigest()
    trees = {"tool_tree_without_start_sha256": tree_hash(old_scope / TOOLS, GUEST_START),
             "source_tree_without_start_sha256": tree_hash(old_scope / "src", SOURCE)}
    record = {**old, "arena": str(scope), "worker_executable": str(scope / "micropod"),
              "compiled_sources": {**old["compiled_sources"], SOURCE: boot_sha}, "guest_start_sha256": boot_sha,
              "patch_sha256": hashlib.sha256(patch).hexdigest(), "host_product": str(previous),
              "fault_around_source_product_sha256": digest(previous), "fault_around_kernel": proof,
              "fault_around_fragment_sha256": hashlib.sha256(fragment).hexdigest(), **trees}
    if not scope.exists():
        with tempfile.TemporaryDirectory(prefix="file-fault-around-", dir=BASE) as tmp:
            stage = Path(tmp) / "product"
            stage.mkdir()
            for name in ("micropod", "build.log", "micropod-oci", TOOLS, "src"):
                clone(old_scope / name, stage / name)
            (stage / TOOLS / GUEST_START).write_bytes(changed)
            (stage / "src" / SOURCE).write_bytes(changed)
            (stage / "worker.patch").write_bytes(patch)
            (stage / "file-fault-around-bootstrap.sh").write_bytes(fragment)
            (stage / "product.json").write_bytes(encode(record))
            stage.rename(scope)
    require(read(product) == record and (scope / "file-fault-around-bootstrap.sh").read_bytes() == fragment
            and digest(scope / "micropod-oci") == digest(old_scope / "micropod-oci")
            and tree_hash(scope / TOOLS, GUEST_START) == trees["tool_tree_without_start_sha256"]
            and tree_hash(scope / "src", SOURCE) == trees["source_tree_without_start_sha256"],
            "packaged worker contains an unrelated change")
    verify_inputs(scope, record)
    receipt = {"current_product": str(product), "previous_product": str(previous),
               "previous_product_sha256": digest(previous), "base_revision": record["base_revision"],
               "entitlements": record["entitlements"], "host_sha256": record["worker_executable_sha256"],
               "old_host_sha256": old["worker_executable_sha256"], "new_guest_sha256": record["guest_runner_sha256"],
               "old_bootstrap_sha256": old["guest_start_sha256"], "new_bootstrap_sha256": boot_sha,
               "changed_packaged_inputs": [SOURCE], "sha256_by_changed_input": {SOURCE: boot_sha},
               "patch_sha256": record["patch_sha256"], "fragment_sha256": record["fault_around_fragment_sha256"],
               "kernel": proof, **trees}
    if MANIFEST.exists():
        require(read(MANIFEST) == receipt, "recorded fault-around manifest has different inputs")
    else:
        try:
            with MANIFEST.open("xb") as stream:
                stream.write(encode(receipt))
        except FileExistsError:
            require(read(MANIFEST) == receipt, "concurrent recorded fault-around manifest differs")
    return MANIFEST, product


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("kernel", "package"))
    args = parser.parse_args()
    if args.action == "kernel":
        print(encode(kernel_proof()).decode(), end="")
    else:
        for file in package():
            print(file)


if __name__ == "__main__":
    main()
