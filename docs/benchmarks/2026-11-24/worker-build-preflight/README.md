# Four-worker throughput trial on Gamma

The host relay pilot now builds the C relay from the same revision and with the same fixed-budget define as the signed VM candidate. The earlier host pilot passed two to the drain function even when four workers were running. That selected the intended callback budget on the earlier source. The updated pilot passes the actual group size and checks the value returned by the production selector before timing and in the scored output.

| Native build | Workers | Group size passed to drain | Events per callback | Read cap |
| --- | ---: | ---: | ---: | ---: |
| Ordinary | 2 | 2 | 128 | 256 KiB |
| Ordinary | 4 | 4 | 24 | 256 KiB |
| Fixed budget | 2 | 2 | 128 | 256 KiB |
| Fixed budget | 4 | 4 | 128 | 256 KiB |

The preflight rejected the ordinary four-worker build for this comparison. Both fixed-budget arms used one executable and verified active lease revocation, a surviving sibling and replacement connections on Darwin stream socketpairs. The C blob was `c877f1efe9b46a9e80385bf6f8b1a00add0b1671cf8d0d8d8ec02d2d0842990f` at revision `5b8ea1a6`. The host harness and signed VM supervisor are different executables. [Fixed-budget controls](verified/worker-controls.json) · [Build, flags and planned order](verified/plan.json) · [Ordinary build](ordinary-build.json)

At 19:03 AEDT on 24 November, the named CI worker, Linux keeper and watchdog showed no PID. The machine runner had PID 3379 and the local desktop state reported intake unpaused. The sampled host idle fraction was 66.3%, below the 90% timing threshold. Cuttlefish's two Gamma snapshots were stale. No timed worker arms or VMs ran in this preflight. [Local and fleet observations](admission.json)

The local VM input checks passed again for the stock baseline, launchd role comparison and fixed-budget worker comparison. The last attempted VM bootstrap exited 5 before boot. The next end-to-end measurement is the four-vCPU stock baseline in a host context that can boot the disposable fixture, followed by two versus four workers with the same four vCPUs, service image and traffic. [Baseline inputs](../disposable-local-fixture/20261124T080403Z-local-1zg60c8z/status.json) · [Role inputs](../disposable-local-fixture/20261124T080410Z-local-jmg431bz/status.json) · [Worker inputs](../disposable-local-fixture/20261124T080410Z-local-l1foslj8/status.json) · [Previous bootstrap](../disposable-local-fixture/20261124T071036Z-local-xnc1r_qc/status.json)

The last independent peer comparison delivered clean-arm medians of 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack. The gap is 300.6 MiB/s, or 11.1% of Micropod's median. The median ratio across the 15 jointly clean pairs was 0.854. A new peer verdict requires the externally selected worker count and VM size in addition to the binary digest. The local VM receiver now checks that CPU and runnable-time samples bracket the client invocation. [Historical comparison](../../2026-11-23/orbstack-scorecard.md) · [CPU cost needed to close the gap under two assumptions](../worker-gap-sensitivity/README.md)

From the performance checkout, the following command runs the worker preflight only. It creates a new output directory. During an admitted timing window the same driver accepts `--run` and a separate new output directory for the six-second host-component arms.

```sh
python3 -B scripts/relaybench/gamma_relay_pilot.py workers --ports 1 --pairs 6 --seed 34200 --check --out "$NEW_WORKER_PREFLIGHT"
```

## Regression checks

| Command from the performance checkout | Result |
| --- | --- |
| `python3 -B -m unittest discover -s scripts/relaybench -p 'test_*.py' -q` | 143 tests passed, including rejection of four workers with a 24-event budget or a two-worker drain argument. |
| `python3 -B -m unittest discover -s docs/benchmarks/2026-11-24/disposable-local-fixture -p 'test_*.py' -v` | Six receiver tests passed, including shifted host counter windows and fresh replies completing during drain. |
| `python3 -B scripts/relaybench/peer_verdict.py --archive` | Reproduced Micropod/OrbStack ratio 0.854, 95% interval 0.709–1.259. Exit 1 is the expected historical verdict. |
