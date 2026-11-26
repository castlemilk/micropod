# Reproducing the two Darwin fixed-work fixtures

Use the indicated Micropod source checkout on an authorized Darwin/arm64 workspace with private loopback access. These commands create a temporary executable and use fresh ephemeral loopback ports. Run each comparison once to preserve the cache sequence. Workload output path must be new. No elapsed times are scored. User permissions suffice.

```sh
fixture=docs/benchmarks/2026-11-24/batch05-tcp-control
out=$(mktemp -d)
clang -std=c11 -Wall -Wextra -Werror -I Sources/CPublishedTCP -I Sources/CPublishedTCP/include "$fixture/socket_trials.c" -o "$out/socket_trials"
"$out/socket_trials" window BABABAAABABBAABB > "$out/window.jsonl"
"$out/socket_trials" fastopen BAABBABBABAAABAB > "$out/fastopen.jsonl"
```

For each case, A means stock first and B means candidate first. The order is a shuffle of eight As plus eight Bs using Python random.Random, seed 23011 for window and 23105 for fastopen. The fixture uses repeated fresh sockets on one listening endpoint per case. Exact numerical kernel defaults and cookie history may differ across boots or systems.

The initial window fixture SHA-256 was `897c94209c1031f5be321b78e4ea35ee5b7f68c90f737ce37039fd0920d2296a`. The surviving shared fixture SHA-256 is `5b71dffe3c5d07c0505d079191e7fc7259fb78cb944aaf808f0d736ff45c2126`. The only change moved the conditional Fast Open option setup past listen; both versions have identical window code. Reconstruct and verify the initial bytes with the following command from the benchmark checkout.

```sh
python3 - <<'PYCODE'
import hashlib, pathlib
d = pathlib.Path("docs/benchmarks/2026-11-24/batch05-tcp-control")
source = (d / "socket_trials.c").read_bytes()
setting = b"    if (tfo) set_int(listener, IPPROTO_TCP, TCP_FASTOPEN, 1);\n"
setup = b"    check(bind(listener,"
assert source.count(setting) == source.count(setup) == 1
original = source.replace(setting, b"").replace(setup, setting + setup)
assert hashlib.sha256(original).hexdigest() == "897c94209c1031f5be321b78e4ea35ee5b7f68c90f737ce37039fd0920d2296a"
PYCODE
```
