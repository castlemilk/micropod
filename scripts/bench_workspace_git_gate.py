#!/usr/bin/env python3
"""Run equal-work stock and opt-in Git status before the archived Go workload."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import statistics
import sys
from tempfile import TemporaryDirectory
import time
from uuid import uuid4


ROOT = Path("/checkout-ci")
OUTPUT = Path("/git-gate-receipts")
ENGINES = ("orbstack", "hvf")
PHASES = ("warm", "incremental")
MEMORY_MIB = 1536
CPUS = 2


def guest(args):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner

    action, mode, variant = args
    if action == "prepare":
        print(json.dumps(runner.guest_prepare(CPUS, MEMORY_MIB)))
        return
    original = bench.call
    base = bench.GUEST_SOURCE
    wanted = b" M main_linux.go\0" if variant else b""
    plain_git_call = ["git", "-c", f"safe.directory={base}", "status", "--porcelain=v1", "--untracked-files=all"]
    observed = []

    def run_with_helper(argv, **kwargs):
        if argv != plain_git_call:
            return original(argv, **kwargs)
        env = kwargs["env"] | {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(base)}
        result = original([sys.executable, str(ROOT / "git_parallel_clean.py"), "--workers", "4", str(base)],
                          **(kwargs | {"env": env}))
        bench.require(result.stdout == wanted and not result.stderr, f"unexpected helper porcelain {result.stdout!r}")
        observed.append(result.stdout.hex())
        # Translate the verified known fixture row for the archived workload's
        # existing stdout assertion. The receipt retains the original bytes.
        result.stdout = result.stdout.replace(b"\0", b"\n")
        return result

    def run_on_cpu0(argv, **kwargs):
        if argv != plain_git_call:
            return original(argv, **kwargs)
        initial = os.sched_getaffinity(0)
        bench.require(initial == {0, 1, 2, 3}, "unexpected initial CPU set")
        os.sched_setaffinity(0, {0})
        try:
            observed.append(sorted(os.sched_getaffinity(0)))
            return original(argv, **kwargs)
        finally:
            os.sched_setaffinity(0, initial)

    if action == "eligibility":
        from git_parallel_clean import status

        env = bench.guest_env(CPUS) | {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(base)}
        result, fast = status(base, 4, env)
        bench.require(result.returncode == 0 and result.stdout == wanted and not result.stderr and fast == (not variant),
                      f"unexpected helper path for fixture {variant!r}")
        print(json.dumps({"used_parallel": fast, "porcelain_hex": result.stdout.hex()}))
        return
    if mode == "helper":
        bench.call = run_with_helper
    elif mode == "cpu0":
        bench.call = run_on_cpu0
    result = runner.guest_run(CPUS, variant)
    if mode == "helper":
        bench.require(len(observed) == 1, "archived driver didn't call the raw Git phase exactly once")
        result["porcelain_nul_hex"] = observed[0]
    elif mode == "cpu0":
        bench.require(observed == [[0]] and os.sched_getaffinity(0) == {0, 1, 2, 3},
                      "Git CPU placement or restored build placement differed")
        result["git_allowed_cpus"] = observed[0]
    result["mode"] = mode
    print(json.dumps(result))


def detached(arm, directory, action, mode, variant="", timeout=240):
    import bench_workspace_checkout as bench

    token = uuid4().hex
    local = directory / token
    complete = local.with_suffix(".exit")
    out, err = local.with_suffix(".out"), local.with_suffix(".err")
    started = time.monotonic_ns()
    script = ('base=$1; shift; '
              'if python3 -B /checkout-ci/bench_workspace_git_gate.py guest "$@" >"$base.out" 2>"$base.err"; '
              'then rc=0; else rc=$?; fi; printf "%s\\n" "$rc" >"$base.pending"; '
              'mv "$base.pending" "$base.exit"; exit "$rc"')
    bench.call([*arm.docker, "exec", "--detach", arm.id, "/bin/sh", "-ec", script, "mp-git-gate",
                str(OUTPUT / token), action, mode, variant], timeout=10)
    limit = time.monotonic() + timeout
    while not complete.is_file():
        if time.monotonic() >= limit:
            raise TimeoutError(f"{arm.name}/{mode} {action} did not finish")
        time.sleep(0.01)
    bench.require(complete.read_text().strip() == "0", f"{arm.name}/{mode} {action}: {err.read_text()[-2500:]}")
    result = json.loads(out.read_bytes())
    result["host_request_through_result_ns"] = time.monotonic_ns() - started
    for path in (complete, out, err):
        path.unlink()
    return result


def admit(arm, checkout, original, variant, mode):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner

    main = checkout / "main_linux.go"
    rendered = original.replace(runner.MESSAGE.encode(), f"{runner.MESSAGE} {variant}".encode()) if variant else original
    wanted = bench.sha(rendered)
    published = None
    if main.read_bytes() != rendered:
        pending = checkout.parent / "edited-main.go"
        pending.write_bytes(rendered)
        pending.chmod(main.stat().st_mode & 0o777)
        pending.replace(main)
        published = time.monotonic_ns()
    deadline = time.monotonic() + 5
    observations = []
    while time.monotonic() < deadline:
        digest = bench.call([*arm.docker, "exec", arm.id, "/usr/bin/sha256sum", str(bench.GUEST_SOURCE / main.name)],
                            timeout=5).stdout.split()[0].decode()
        observations.append({"host_ns": time.monotonic_ns(), "digest": digest})
        if digest == wanted:
            break
        time.sleep(0.03)
    else:
        raise RuntimeError(f"{arm.name}/{mode} failed admitted write visibility for {wanted}: {observations}")
    return wanted, published, observations


def sample(arm, output, checkout, original, variant, mode):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner

    begin = time.monotonic_ns()
    wanted, published, observations = admit(arm, checkout, original, variant, mode)
    result = detached(arm, output, "build", mode, variant)
    bench.require(result["main_sha256"] == wanted and result["tests"] == sorted(runner.TESTS)
                  and result["mode"] == mode, "different source or tests in completed guest workload")
    finished = time.monotonic_ns()
    return result | {"host_total_ns": finished - begin, "host_start_ns": begin, "host_complete_ns": finished,
                     "host_publication_ns": published, "visibility": observations}


def measure(args, stage, report):
    import bench_workspace_checkout as bench
    import bench_workspace_runner as runner
    from bench_workspace_edits import LABEL

    args.cpus, args.memory_mib = CPUS, MEMORY_MIB
    sockets = {"hvf": args.hvf_socket, "orbstack": args.orbstack_socket}
    modes = ("stock", args.comparison)
    keys = [(engine, mode) for mode in modes for engine in ENGINES]
    arms = {key: bench.Arm(key[0], sockets[key[0]], args.image) for key in keys}
    image = bench.image_identity(args.image_manifest, [arm.image_id for arm in arms.values()])
    directories, checkouts, outputs, heads = {}, {}, {}, {}
    staging = {}
    for key in keys:
        label = "/".join(key)
        here = stage / "-".join(key)
        start = time.monotonic_ns()
        here.mkdir()
        directories[key] = here
        checkouts[key], heads[key] = runner.prepare_checkout(here, args.source)
        outputs[key] = here / ".git-gate-output"
        outputs[key].mkdir()
        for source, target in ((Path(__file__), "bench_workspace_git_gate.py"),
                               (here / "driver.py", "bench_workspace_runner.py"),
                               (args.helper, "git_parallel_clean.py")):
            shutil.copyfile(source, here / target)
        staging[label] = time.monotonic_ns() - start
    inventory = runner.inventory(checkouts[keys[0]])
    original = (checkouts[keys[0]] / "main_linux.go").read_bytes()
    bench.require(inventory["files"] == 1058 and original.count(runner.MESSAGE.encode()) == 1
                  and len(set(heads.values())) == 1 and all(runner.inventory(root) == inventory for root in checkouts.values()),
                  "archived checkouts differ")
    index_initial = {key: bench.file_sha(checkouts[key] / ".git" / "index") for key in keys}
    report.update(image=image, source=inventory, git_commit=heads[keys[0]], cpus=CPUS, memory_mib=MEMORY_MIB, comparison=args.comparison,
                  guest_caches="one private Go cache per retained container and mode", preparation={}, primes={}, pairs=[],
                  helper_sha256=bench.file_sha(args.helper), archived_guest_driver_sha256=bench.file_sha(Path(runner.__file__)),
                  experiment_driver_sha256=bench.file_sha(Path(__file__)), clean_eligibility={}, dirty_eligibility={}, cleanup={})
    scope = "mp-git-go-gate-" + uuid4().hex[:12]
    names = {}
    try:
        with ExitStack() as cleanup:
            known_product = set()
            for key in keys:
                engine, mode = key
                label = "/".join(key)
                arm = arms[key]
                names[key] = scope + "-" + "-".join(key)
                start = time.monotonic_ns()
                arm.start(cleanup, names[key], directories[key], args, set(image.values()),
                          extra_mounts=(bench.bind_mount(outputs[key], OUTPUT, read_only=False),))
                started = time.monotonic_ns()
                prep = detached(arm, outputs[key], "prepare", mode)
                bench.require(prep["tree"] == inventory and prep["head"] == heads[key]
                              and not any(prep["cache_initial_entries"].values())
                              and prep["runner_driver_sha256"] == report["archived_guest_driver_sha256"], "prepared work differed")
                report["preparation"][label] = prep | {"docker_start_ns": started - start, "host_stage_ns": staging[label]}
                prime = sample(arm, outputs[key], checkouts[key], original, "", mode)
                prime["first_total_with_staging_ns"] = time.monotonic_ns() - start + staging[label]
                report["primes"][label] = prime
                known_product.add(prime["binary_sha256"])
            settings = ("limits", "versions", "tools_sha256", "go_env")
            first = next(iter(report["preparation"].values()))
            bench.require(len(known_product) == 1 and all(all(prep[k] == first[k] for k in settings)
                          for prep in report["preparation"].values()), "cold primes differed in output or environment")
            if args.comparison == "helper":
                for engine in ENGINES:
                    key = (engine, "helper")
                    report["clean_eligibility"][engine] = detached(arms[key], outputs[key], "eligibility", "helper")
            edited_products = set()
            for i in range(args.pairs):
                block = {"pair": i + 1, "order": [], "results": {}}
                report["pairs"].append(block)
                for p, phase in enumerate(PHASES if i % 2 == 0 else PHASES[::-1]):
                    variant = f"{i + 1:04d}" if phase == "incremental" else ""
                    block["results"][phase] = {}
                    for m, mode in enumerate(modes if (i // 2 + p) % 2 == 0 else modes[::-1]):
                        for engine in (ENGINES if (i + m + p) % 2 == 0 else ENGINES[::-1]):
                            key = engine, mode
                            label = "/".join(key)
                            block["order"].append([phase, engine, mode])
                            result = sample(arms[key], outputs[key], checkouts[key], original, variant, mode)
                            block["results"][phase][label] = result
                    products = {row["binary_sha256"] for row in block["results"][phase].values()}
                    bench.require(len(products) == 1, "same fixture yielded different binaries")
                    if variant:
                        bench.require(not products & (known_product | edited_products), "edited workload returned an earlier binary")
                        edited_products.update(products)
                    else:
                        bench.require(products == known_product, "warm workload differed from its prime")
            variant = f"{args.pairs:04d}"
            if args.comparison == "helper":
                for engine in ENGINES:
                    key = (engine, "helper")
                    admit(arms[key], checkouts[key], original, variant, "helper")
                    report["dirty_eligibility"][engine] = detached(arms[key], outputs[key], "eligibility", "helper", variant)
            for key, arm in arms.items():
                arm.check_generation()
                bench.require(bench.file_sha(checkouts[key] / ".git" / "index") == index_initial[key], "workload edited the Mac index")
    finally:
        for key, name in names.items():
            remaining = bench.call([*arms[key].docker, "ps", "-aq", "--filter", f"label={LABEL}={name}"], timeout=10).stdout.decode().splitlines()
            report["cleanup"]["/".join(key)] = remaining
            bench.require(not remaining, f"scoped benchmark left objects for {name}")
    for phase in PHASES:
        report.setdefault("medians_ms", {})[phase] = {}
        for label in ("/".join(key) for key in keys):
            rows = [pair["results"][phase][label] for pair in report["pairs"]]
            spans = {"guest_total": [row["sum_ns"] for row in rows], "host_total": [row["host_total_ns"] for row in rows]}
            for stage_name in rows[0]["phase_ns"]:
                spans[stage_name] = [row["phase_ns"][stage_name] for row in rows]
            report["medians_ms"][phase][label] = {metric: statistics.median(values) / 1e6 for metric, values in spans.items()}


if __name__ == "__main__":
    if sys.argv[1:2] == ["guest"]:
        guest(sys.argv[2:])
        sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("hvf-socket", "orbstack-socket", "workspace", "source", "helpers", "helper", "image-manifest", "out"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--pairs", type=int, choices=(4,), default=4)
    parser.add_argument("--comparison", choices=("helper", "cpu0"), default="helper")
    options = parser.parse_args()
    if options.out.exists() or not options.hvf_socket.is_socket() or not options.orbstack_socket.is_socket():
        parser.error("use two explicit live sockets and a fresh receipt")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    sys.path.insert(0, str(options.helpers))
    receipt = {"passed": False}
    try:
        with TemporaryDirectory(prefix="mp-git-go-gate-", dir=options.workspace) as scratch:
            measure(options, Path(scratch), receipt)
        receipt["passed"] = True
    except Exception as error:
        receipt["failure"] = repr(error)
        raise
    finally:
        with options.out.open("x") as out:
            json.dump(receipt, out, indent=2)
            out.write("\n")
