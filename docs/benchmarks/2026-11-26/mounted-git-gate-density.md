# Eight concurrent Git status jobs on a mounted checkout

The opt-in four-process check reduced Micropod HVF's median time to finish eight clean Git status jobs from 350.00 ms to 318.53 ms. It finished sooner in all four paired rounds. OrbStack stock Git finished the corresponding wave in 138.62 ms and the helper took 214.72 ms. [Pair timings and job distributions](mounted-git-gate-density.json)

| Engine and mode | Guest first start to last finish | Host release to last result | Host with exec startup | Job p50 / p90 | CPU per job p50 |
|---|---:|---:|---:|---:|---:|
| HVF stock | 350.00 ms | 355.64 ms | 462.03 ms | 335.53 / 351.58 ms | 53.49 ms |
| HVF helper | 318.53 ms | 324.23 ms | 435.84 ms | 292.02 / 315.79 ms | 84.57 ms |
| OrbStack stock | 138.62 ms | 150.97 ms | 278.82 ms | 125.81 / 137.35 ms | 62.79 ms |
| OrbStack helper | 214.72 ms | 221.79 ms | 351.07 ms | 203.76 / 217.92 ms | 102.28 ms |

Each engine ran eight containers on four guest CPUs. The job cgroups enforced 0.5 CPU and 256 MiB. Both engines used the same 1,058-file read-only bind and the same Linux ARM64 image and Git binary. Each slot mounted a separate copy of the Mac index with matching bytes and mtime, and piped its result over its own Docker exec session. The driver released all slots after they reported ready. Four counterbalanced rounds produced 128 successful status commands with empty stdout and stderr. All eight commands overlapped for at least 80.15 ms in every timed wave. All 16 containers and the temporary checkout were removed. [Raw waves, integrity checks and cleanup](mounted-git-gate-density-receipts.tar.gz) · [Driver](../../../scripts/bench_git_gate_density.py)

The helper saved about 9% elapsed time on the HVF wave and used about 58% more median CPU per job. This experiment measured clean status only. The separate one-job study found additional Git cost when a dirty checkout required stock fallback. [Clean, edited and whole-job comparison](mounted-git-status.md)

The pre-run intervals measured 88.30% and 86.64% idle, which makes this an ambient run under the 90% gate. Whole-host idle was 62.83% across the complete one-second intervals within the scored window. The post-run intervals measured 90.37% and 89.88%. The last scored result arrived at 18:44:53.342 UTC. The first recovery-build log was created 4.50 s later, after the driver completed scoped cleanup. [Host samples and recovery-build timestamps](mounted-git-gate-density.json) · [Raw host samples](mounted-git-gate-density-receipts.tar.gz)
