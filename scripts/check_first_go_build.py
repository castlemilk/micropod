"""Compare an empty Go action cache, a main-only rebuild and an unchanged warm build, offline."""
import hashlib
import json
import platform
from pathlib import Path
import tempfile

from bench_package_caches import COMPILER, Fixture, command, stores


def main():
    with tempfile.TemporaryDirectory(prefix="mp-first-go-") as directory:
        root = Path(directory).resolve()
        fixture = Fixture(root)
        shared = stores(root / "shared")
        cold = fixture.prime(shared, "cold")
        env = fixture.environment(shared)
        rows = {}
        for name in ("changed_main", "unchanged_warm"):
            work = fixture.workspace(name)
            if name == "changed_main":
                source = work / "main.go"
                source.write_text(source.read_text().replace("fmt.Println(shared.Message)", 'fmt.Printf("%s\\n", shared.Message)'))
            result, elapsed = command(fixture.argv("go"), work, env)
            fixture.verify_output("go", work, env)
            rows[name] = {"build_seconds": elapsed, "compile_or_asm": len(COMPILER.findall(result.stderr)),
                          "product_sha256": hashlib.sha256((work / "app").read_bytes()).hexdigest()}
        if not rows["changed_main"]["compile_or_asm"] or rows["unchanged_warm"]["compile_or_asm"]:
            raise ValueError("expected a partial rebuild and then a build without compiler actions")

        # A new module store beside the old action cache must fail the production
        # seed gate before any tool can change the state that caused rejection.
        mixed = stores(root / "next")
        mixed["go-build-cache"] = shared["go-build-cache"]
        try:
            fixture.prime(mixed, "must-not-start")
        except ValueError as exc:
            if str(exc) != f'Expected an empty first-build cache: {mixed["go-build-cache"]}':
                raise
        else:
            raise ValueError("partially warm Go build store qualified as cold")
        if (root / "checkouts/must-not-start").exists():
            raise ValueError("contaminated seed started a checkout")
        version = command(["go", "version"], root, env)[0].stdout.strip()
        cold["product_sha256"] = hashlib.sha256((root / "checkouts/cold/app").read_bytes()).hexdigest()
        print(json.dumps({"scope": "one local Go CLI checkout; runtime startup and OS file-cache state unmeasured",
                          "host_os": platform.system(), "host_arch": platform.machine(), "go_version": version,
                          "flags": fixture.argv("go"), "gomaxprocs": env["GOMAXPROCS"], "goflags": env["GOFLAGS"],
                          "cold": cold, "subsequent_builds": rows, "mixed_cache_seed_rejected": True}, indent=2))


if __name__ == "__main__":
    main()
