"""Offline Go/npm edit workload executed inside a private job workspace."""

import base64
import fcntl
import gzip
import hashlib
import json
import os
import re
import resource
import shutil
import subprocess
import sys
import time
from pathlib import Path

from ci_profile_guest import go_tools


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def text(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def cgroup():
    root = Path("/sys/fs/cgroup")
    out = {}
    for name in (
        "cpu.stat",
        "cpu.max",
        "cpu.weight",
        "cpuset.cpus.effective",
        "memory.max",
        "memory.current",
        "memory.peak",
        "memory.events",
        "io.stat",
        "cpu.pressure",
        "io.pressure",
        "memory.pressure",
    ):
        out[name] = text(root / name)
    mem = text(root / "memory.stat")
    out["memory.stat"] = (
        None
        if mem is None
        else {
            k: int(v)
            for k, v in (line.split() for line in mem.splitlines())
            if k
            in (
                "file",
                "anon",
                "file_dirty",
                "file_writeback",
                "workingset_refault_file",
                "pgscan",
                "pgsteal",
                "pgmajfault",
            )
        }
    )
    return out


def mount_at(path):
    data = text("/proc/self/mountinfo")
    if data is None:
        return None
    matches = []
    for line in data.splitlines():
        left, right = line.split(" - ", 1)
        fields = left.split()
        dest = fields[4].replace(r"\040", " ")
        if dest == "/" or str(path) == dest or str(path).startswith(dest + "/"):
            matches.append(
                (
                    len(dest),
                    dict(
                        point=dest,
                        device=fields[2],
                        root=fields[3],
                        fs=right.split()[0],
                        source=right.split()[1],
                        options=fields[5],
                        storage_options=[
                            o
                            for o in right.split()[2].split(",")
                            if o.split("=")[0]
                            in (
                                "metacopy",
                                "redirect_dir",
                                "index",
                                "data",
                                "barrier",
                                "max_batch_time",
                                "discard",
                            )
                        ],
                    ),
                )
            )
    return max(matches, key=lambda x: x[0])[1]


def tool_identity():
    def read(*argv):
        return subprocess.check_output(argv, text=True).strip()

    go = json.loads(
        read(
            "go",
            "env",
            "-json",
            "GOVERSION",
            "GOOS",
            "GOARCH",
            "GOARM64",
            "GOEXPERIMENT",
            "CGO_ENABLED",
            "GOTOOLDIR",
        )
    )
    bindir = Path(go.pop("GOTOOLDIR"))
    return dict(
        go=go,
        go_driver=digest(shutil.which("go")),
        compiler=digest(bindir / "compile"),
        linker=digest(bindir / "link"),
        node=read("node", "--version"),
        node_abi=read("node", "-p", "process.versions.modules"),
        npm=read("npm", "--version"),
        node_binary=digest(shutil.which("node")),
        npm_cli=digest(shutil.which("npm")),
    )


def inventory(cache):
    out, objects = {}, {}
    for name, directory in (
        ("go_build", cache / "go-build"),
        ("go_mod", cache / "go-mod"),
        ("npm_content", cache / "npm/_cacache/content-v2"),
    ):
        alloc = logical = count = 0
        for path in directory.rglob("*"):
            if not path.is_file():
                continue
            st = path.stat()
            count += 1
            logical += st.st_size
            alloc += st.st_blocks * 512
            if name == "go_build" and re.fullmatch(r"[0-9a-f]{64}-d", path.name):
                objects[path.name] = st.st_size
        out[name] = dict(files=count, logical_bytes=logical, allocated_bytes=alloc)
    return dict(stores=out, objects=objects)


def run_job(inputs, work, cache, revision, guest=True, local_restore=None):
    group = cgroup() if guest else None
    start = time.monotonic()
    work.mkdir(exist_ok=True)
    require(not any(work.iterdir()), "workspace was not empty")
    for tree in ("go-app", "node-app"):
        shutil.copytree(inputs / tree, work / tree)
    source_copy_s = time.monotonic() - start
    go, node = work / "go-app", work / "node-app"
    observed_boot = text("/proc/sys/kernel/random/boot_id") if guest else None
    mount = mount_at(work) if guest else None
    if guest:
        require(observed_boot == os.environ["CONTROL_BOOT"], "worker boot changed")
        quota, period = group["cpu.max"].split()
        require(
            quota == period and int(period) > 0 and group["memory.max"] == str(2**30), "container limits differ"
        )
        require(os.listdir("/sys/class/net") == ["lo"], "unexpected network device")
        disk = os.environ["CONTROL_STORAGE"]
        require(
            (disk == "volume" and mount["point"] == str(work) and mount["fs"] == "ext4")
            or (disk == "overlay" and mount["point"] == "/" and mount["fs"] == "overlay"),
            f"unexpected workspace mount {mount}",
        )

    marker = "" if revision == "base" else revision
    require(not marker or re.fullmatch(r"edit-[0-9]+-[0-9]+", marker), "invalid revision")

    def edit(path, old, new):
        s = path.read_text()
        require(s.count(old) == 1, "fixture source changed")
        path.write_text(s.replace(old, new))

    if marker:
        line = 'fmt.Fprintln(w, greeting(r.URL.Query().Get("name")))'
        edit(go / "main.go", line, 'w.Header().Set("X-CI-Revision", "' + marker + '")\n\t' + line)
        edit(
            node / "src/index.js",
            "return pc.green(",
            'if (name === "build") return "hello, build ' + marker + '";\n  return pc.green(',
        )
    (go / "bench_revision_test.go").write_text("""package main
import ("net/http/httptest"; "os"; "testing")
func TestBenchRevision(t *testing.T) {
    r := httptest.NewRecorder()
    helloHandler(r, httptest.NewRequest("GET", "/?name=ada", nil))
    if r.Code != 200 || r.Body.String() != "hello, ada\\n" || r.Header().Get("X-CI-Revision") != os.Getenv("EXPECTED_REVISION") {t.Fatal(r)}
}
""")
    locks = ("package.json", "package-lock.json")
    env = {
        **os.environ,
        "GOCACHE": str(cache / "go-build"),
        "GOMODCACHE": str(cache / "go-mod"),
        "GOPROXY": "off",
        "GOTOOLCHAIN": "local",
        "GOENV": "off",
        "GOWORK": "off",
        "CGO_ENABLED": "0",
        "GOMAXPROCS": "1",
        "GOFLAGS": "-p=1 -trimpath -mod=readonly -buildvcs=false",
        "GOTELEMETRY": "off",
        "EXPECTED_REVISION": marker,
        "npm_config_cache": str(cache / "npm"),
        "npm_config_offline": "true",
        "npm_config_update_notifier": "false",
        "npm_config_audit": "false",
        "npm_config_fund": "false",
        "NO_COLOR": "1",
        "FORCE_COLOR": "0",
    }
    results, refs = {}, set()

    def cmd(stage, argv, directory):
        t = time.monotonic()
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        p = subprocess.run(argv, cwd=directory, env=env, capture_output=True, text=True, timeout=300)
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        results[stage] = dict(
            seconds=time.monotonic() - t,
            user_s=after.ru_utime - before.ru_utime,
            sys_s=after.ru_stime - before.ru_stime,
            exit=p.returncode,
        )
        require(p.returncode == 0, f"{stage} exit {p.returncode}: {p.stderr[-700:]} {p.stdout[-300:]}")
        if argv[0] == "go":
            results[stage]["tools"] = go_tools(p.stderr)
            refs.update(
                re.findall(
                    r"(?m)^packagefile [^=\n]+=" + re.escape(env["GOCACHE"]) + r"/[0-9a-f]{2}/([0-9a-f]{64}-d)$",
                    p.stderr,
                )
            )
        return p.stdout

    archive = inputs / "picocolors-1.1.1.tgz"
    sri = json.loads((node / locks[1]).read_text())["packages"]["node_modules/picocolors"]["integrity"]
    h = hashlib.sha512(archive.read_bytes())
    require(sri == "sha512-" + base64.b64encode(h.digest()).decode(), "npm origin failed lock integrity")
    key = h.hexdigest()
    payload = cache / "npm/_cacache/content-v2/sha512" / key[:2] / key[2:4] / key[4:]
    cache.mkdir(exist_ok=True)
    with (cache / "npm-seed.lock").open("a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        hit = payload.is_file()
        if not hit:
            cmd("npm_import", ["npm", "cache", "add", "--offline", str(archive)], node)
        require(
            payload.is_file() and hashlib.sha512(payload.read_bytes()).digest() == h.digest(),
            "cached npm payload differs",
        )
    cmd("npm_ci", ["npm", "ci", "--offline"], node)
    tests = cmd("npm_test", ["npm", "test"], node)
    require(
        all(s in tests for s in ("greets the world by default", "greets by name", "wraps in color codes")),
        "missing npm tests",
    )
    expected = "hello, build" + (" " + marker if marker else "")
    require(
        cmd("npm_build", ["npm", "run", "--silent", "build"], node).strip() == expected, "wrong npm build output"
    )
    require(cmd("node_output", ["node", "src/index.js", "ada"], node).strip() == "hello, ada", "wrong Node output")
    tests = cmd("go_test", ["go", "test", "-v", "-x", "-count=1", "."], go)
    require(
        all("--- PASS: " + s in tests for s in ("TestGreeting", "TestHelloHandler", "TestBenchRevision")),
        "missing Go tests",
    )
    if local_restore is not None:
        require(not guest, "Local publication experiment cannot change a live workspace arm")
        local_restore(go)
    cmd("go_build", ["go", "build", "-x", "-o", "service", "."], go)
    require(
        all((node / p).read_bytes() == (inputs / "node-app" / p).read_bytes() for p in locks), "npm lock changed"
    )
    return dict(
        revision=revision,
        boot=observed_boot,
        go_sha256=digest(go / "service"),
        node_output=expected,
        workspace_mount=mount,
        cache_mount=mount_at(cache) if guest else None,
        cgroup_before=group,
        cgroup_after=cgroup() if guest else None,
        guest_seconds=time.monotonic() - start,
        stages=results,
        source_copy_s=source_copy_s,
        npm_payload_bytes=archive.stat().st_size,
        npm_hit_at_seed=hit,
        go_import_refs=sorted(refs),
    )


def require(condition, message):
    if not condition:
        raise ValueError(message)


if __name__ == "__main__":
    op, *args = sys.argv[1:]
    if op == "identity":
        result = tool_identity()
    elif op == "audit":
        result = inventory(Path(args[0]))
    elif op == "kernel-id":
        try:
            with gzip.open("/proc/config.gz", "rb") as f:
                config_sha = hashlib.sha256(f.read()).hexdigest()
        except OSError:
            config_sha = None
        result = dict(
            release=os.uname().release,
            arch=os.uname().machine,
            config_sha256=config_sha,
            overlay_parameters={
                key: text("/sys/module/overlay/parameters/" + key) for key in ("metacopy", "redirect_dir", "index")
            },
        )
    elif op == "kernel":
        from ci_profile_guest import kernel

        result = kernel()
        result.update(
            boot=text("/proc/sys/kernel/random/boot_id"),
            cmdline=text("/proc/cmdline"),
            mglru=text("/sys/kernel/mm/lru_gen/enabled"),
            ext4=text("/proc/fs/ext4/vdb/options"),
        )
    elif op == "job":
        result = run_job(Path("/inputs"), Path("/job"), Path("/cache"), args[0])
    else:
        raise SystemExit("unknown operation")
    print(json.dumps(result))
