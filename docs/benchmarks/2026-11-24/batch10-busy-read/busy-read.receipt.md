# 231.04 · Does a 50 µs busy-read setting reach the published HTTP service?

24 November 2026 · Source/fixture · Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. [Existing issue direction](https://github.com/castlemilk/micropod/issues/231#issuecomment-7091851125).

Compare `net.core.busy_read=0` against `50` µs. Both arms keep `net.core.busy_poll=0`, the same Linux 7.3.5 receive path, established IPv4 TCP, no pending signals, the default NAPI budget of eight, and no per-socket overrides. The archived stock arm64 kernel config enables busy polling and defines 255 possible CPUs. The stock fixture image's entrypoint is the Go 1.27.2 Linux/arm64 HTTP service `/netbench`. Its binary contains the Go TCP accept, HTTP serve, file-descriptor read and network poller symbols. The matching Go source accepts TCP sockets as nonblocking and waits for readiness after a read returns EAGAIN.

| Modeled receive case | NAPI loop calls at 0 µs | NAPI loop calls at 50 µs | Timeout callback at 50 µs |
| --- | ---: | ---: | --- |
| Child accepted from an older zero-setting listener, empty queue and valid NAPI ID | 0 | 0 | None |
| New listener, nonblocking read, empty queue and valid NAPI ID | 0 | 1 | None |
| New listener, nonblocking read, data already queued | 0 | 0 | None |
| New listener, nonblocking read, empty queue and unknown NAPI ID | 0 | 0 | None |
| Blocking positive control, new listener, empty queue and valid NAPI ID | 0 | 1 | Present |

The kernel assigns the global default at socket initialization. The TCP child copies the listener's socket value. The older listener therefore yielded an effective child value of **0 µs** even after the requested default became 50 µs. On the new listener, the qualifying nonblocking read entered the NAPI loop with a null timeout callback. The kernel breaks its loop after the first pass in that case. Driver work inside a pass and during cleanup is implementation-dependent. The fixture counts NAPI loop entries, not spins, elapsed microseconds or driver polls. The TCP send entry points examined contain no direct call to this busy-read loop.

**Verdict.** Applying the sysctl to an already-serving listener can leave the entire trial unchanged. On a new nonblocking listener the candidate can change request-side work, gated by the receive queue and NAPI ID. No evidence here supports promoting it for bulk response throughput. For a future admitted diagnostic, confirm the accepted socket's `SO_BUSY_POLL`, `SO_INCOMING_NAPI_ID` and actual loop entries, then measure delivered bulk bytes, fresh latency and idle CPU before assigning it a VM window.

**Inputs and reproduction.** The replay compiles verbatim Linux read flag translation, receive conditions, socket default assignment, NAPI ID validation and loop selection. It uses a mock NAPI call counter and a copied socket for the source-checked listener clone path. Each arm evaluated five fixed states once, with all ten first results retained. A second compilation reproduced the raw bytes, and an independent check verified the entry and timeout vectors. These deterministic cases have no statistical interval. No packets were offered. Delivered MiB/s, drops, fresh p95/p99, CPU/GiB and runnable time are unmeasured.

Run `python3 -B reproduce.py LINUX_7_3_5_TREE NETBENCH_V2_OCI_TAR GO_1_27_2_ROOT STOCK_KERNEL_CONFIG` in this directory. The archive contains the existing image config `80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889` and executable SHA-256 `11616563078329f6d13d5c3b50628c57b431537c2fbd05dda7d8136d5f4572ba`. All eight original kernel file hashes, both Go file hashes and the config hash are recorded in the observations.

| Local file | SHA-256 |
| --- | --- |
| observations.json | `db807fadb7172fb711ae12d9eaf542363edb13676d1c805d63c08acab9cb70ba` |
| reproduce.py | `dc191ab8accbcec411d124867135cf257938b0121e635a9c85218517c55bd41d` |
| fixture.c.in | `c38cc9d06bc7a54946094b9e11a910f20c62e668013747a3818e3f5597334153` |
