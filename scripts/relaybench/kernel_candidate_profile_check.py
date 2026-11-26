"""Replay the worker builder's page-size config edits on macOS or Linux, without a kernel build.

Usage: python3 -B scripts/relaybench/kernel_candidate_profile_check.py LINUX_TAR_XZ APPLE_CONFIG
The pinned Linux scripts/config runs on the actual supplied seed. A make fixture captures
requested options, models resolved page-size values for gate testing, and stops before Image.
"""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

from kernel_candidate import config_options

BUILDER = Path(__file__).resolve().parents[2] / "ci/build-worker-kernel.sh"
ARCHIVE_SHA256 = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"


def executable(path, contents):
    path.write_text("#!/bin/sh\nset -eu\n" + contents + "\n")
    path.chmod(0o755)


def check(archive, seed):
    with archive.open("rb") as file:
        checksum = hashlib.sha256()
        for block in iter(lambda: file.read(1024 * 1024), b""):
            checksum.update(block)
    if checksum.hexdigest() != ARCHIVE_SHA256:
        raise ValueError("unexpected Linux source tarball")

    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        upstream = work / "linux-scripts-config"
        with upstream.open("wb") as out:
            subprocess.run(["tar", "-xJOf", archive, "linux-7.3.5/scripts/config"], check=True, stdout=out)
        upstream.chmod(0o755)
        executable(work / "uname", 'echo aarch64')
        executable(work / "tar", 'mkdir -p "$4/linux-7.3.5/scripts"\ncp "$PROFILE_CONFIG" "$4/linux-7.3.5/scripts/config"')
        executable(work / "sha256sum", '''if [ "$RESOLUTION" = publish-hash ] && [ "$1" = Image ]; then
    echo "simulated checksum write failure" >&2
    exit 74
fi
exec "$SYSTEM_SHA256SUM" "$@"''')
        executable(work / "make", '''if [ "$1" = olddefconfig ]; then
    cp .config "$CAPTURE"
    case "$RESOLUTION" in
        resolved|publish-copy|publish-hash) scripts/config -e PAGE_SIZE_16KB -d PAGE_SIZE_4KB --set-val PAGE_SHIFT 14 ;;
        conflict) scripts/config -e PAGE_SIZE_16KB --set-val PAGE_SHIFT 14 -e ARM64_4K_PAGES ;;
    esac
    exit 0
fi
if [ "$2" = Image ]; then
    case "$RESOLUTION" in
        publish-copy) exit 0 ;; # Missing Image causes the first publication copy to fail.
        publish-hash) mkdir -p arch/arm64/boot; echo fixture > arch/arm64/boot/Image; exit 0 ;;
        *) exit 75 ;;
    esac
fi
[ "$2" = kernelrelease ] && { echo 7.3.5-micropod; exit 0; }
exit 1''')

        def run(profile, resolution, expected, destination):
            capture = work / (profile + "." + resolution)
            env = dict(os.environ, PATH=str(work) + os.pathsep + os.environ["PATH"], TMPDIR=str(work),
                       PROFILE_CONFIG=str(upstream), CAPTURE=str(capture), RESOLUTION=resolution,
                       SYSTEM_SHA256SUM=shutil.which("sha256sum"))
            result = subprocess.run(["sh", BUILDER, archive, seed, destination, profile], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if result.returncode != expected:
                raise ValueError(f"{profile}/{resolution} exited {result.returncode}: {result.stderr}")
            return result.stderr, config_options(capture.read_bytes()) if capture.is_file() else None

        control_out = work / "full-output"
        proposed_out = work / "candidate-output"
        _, control = run("full", "unchanged", 75, control_out)
        _, proposed = run("full-16k", "resolved", 75, proposed_out)
        delta = {key: [control.get(key), proposed.get(key)] for key in control.keys() | proposed.keys()
                 if control.get(key) != proposed.get(key)}
        if delta != {"CONFIG_ARM64_4K_PAGES": ["y", "n"], "CONFIG_ARM64_16K_PAGES": ["n", "y"]}:
            raise ValueError(f"unexpected config differences before olddefconfig: {delta}")
        if proposed_out.exists():
            raise ValueError("an interrupted candidate build published a directory")
        errors, _ = run("full-16k", "unchanged", 1, proposed_out)
        if "Missing 16 KiB kernel setting" not in errors:
            raise ValueError("stale resolved granule was not detected")
        errors, _ = run("full-16k", "conflict", 1, proposed_out)
        if "Conflicting arm64 page sizes" not in errors:
            raise ValueError("conflicting resolved granules were not detected")
        for resolution, expected in (("publish-copy", 1), ("publish-hash", 74)):
            run("full-16k", resolution, expected, proposed_out)
            if proposed_out.exists():
                raise ValueError(f"{resolution} left a partial directory and blocked retry")
        run("full-16k", "resolved", 75, proposed_out)
        errors, _ = run("full-16k", "existing", 1, control_out)
        if "requires a new output directory" not in errors:
            raise ValueError("builder accepted control output as candidate destination")
        return {"linux_source_sha256": ARCHIVE_SHA256, "apple_seed_sha256": hashlib.sha256(seed.read_bytes()).hexdigest(),
                "requested_config_differences": delta, "resolved_page_guard_fixture_checks": ["stale", "conflicting"],
                "existing_control_directory_refused": True, "retry_after_fixture_failures": ["copy", "checksum"],
                "kernel_builds": 0, "boots": 0}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("archive", type=Path)
    parser.add_argument("seed", type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.archive.resolve(), args.seed.resolve()), indent=2, sort_keys=True))
