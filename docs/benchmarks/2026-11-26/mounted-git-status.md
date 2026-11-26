# Git status on the raw mounted checkout

Four stock Git processes reduced the Micropod HVF median clean check from 167.05 ms to 101.46 ms on the 1,058-file Mac checkout. Each arm used the same read-only bind and a two-CPU, 1,536 MiB job. All six trials used a different order of the three modes. The parallel clock includes Python startup, index copies, discovery, all Git subprocesses and the final index and HEAD comparisons. [Paired samples](mounted-git-parallel.json) · [CI invocation](../../../ci/git-parallel-status.md)

| Engine | Stock Git | Two processes | Four processes | Four faster than stock |
|---|---:|---:|---:|---:|
| HVF | 167.05 ms | 131.44 ms | 101.46 ms | 6 of 6 |
| OrbStack | 50.37 ms | 56.28 ms | 47.35 ms | 6 of 6 |

Git Trace2 counted 529 and 529 content scans in the two-process run. The four-process run counted 265, 265, 265 and 263. Both modes matched the stock output for a same-inode binary edit and an inode replacement on each engine. The host restored the original nanosecond mtime and held file size fixed. Both modes returned a clean status after the original bytes were restored. Seven separate tests covered literal path names, staged removals, untracked and ignored files, caller-supplied index and command configuration, and index, HEAD and repository configuration changes during the check. All probe containers were removed. [Raw Git traces and edit digests](mounted-git-parallel.json) · [Repository state tests](../../../ci/test_git_parallel_clean.py)

## Git, Go build and uncached tests

Four interleaved paired rounds on the final `b7d78d2bac1f` guest and OrbStack used the same 1,058-file checkout, Git 2.39.5, Go 1.26.11 and Python 3.12.16. Each engine and mode had its own two-CPU, 1,536 MiB container and private Go caches. The experiment ran the archived `go build` and three uncached tests. Each revision produced matching source and executable hashes across all four arms. The stock arm used the archived newline porcelain. The helper's public output was NUL-delimited, and the experiment verified those bytes before translating the fixture's one known edited row for the archived assertion. [Full workload, tool hashes and invocation](mounted-git-gate-receipts.tar.gz) · [Measurement driver](../../../scripts/bench_workspace_git_gate.py)

| Engine and state | Guest Git, build and test | Host request through checked result | Helper faster by guest and host clock |
|---|---:|---:|---:|
| HVF warm | 915.13 → 850.42 ms | 1,073.44 → 937.75 ms | 4 of 4 / 4 of 4 |
| OrbStack warm | 664.08 → 650.77 ms | 872.59 → 781.61 ms | 1 of 4 / 4 of 4 |
| HVF edited | 2,109.14 → 2,146.06 ms | 2,265.81 → 2,233.15 ms | 1 of 4 / 2 of 4 |
| OrbStack edited | 1,994.06 → 2,017.20 ms | 2,178.79 → 2,125.69 ms | 1 of 4 / 3 of 4 |

The table shows stock and helper medians. The paired median HVF warm guest saving was 61.95 ms. Its Git phase fell from 181.22 to 103.62 ms. After an edit it rose from 175.33 to 258.97 ms and the paired median guest total rose by 56.74 ms. The host clock includes publish and visibility checks, detached Docker exec, and result retrieval. The single cold first job per arm, including checkout staging and container startup, took 13.385 and 13.688 s on HVF and 14.369 and 13.955 s on OrbStack. [Paired deltas and cold jobs](mounted-git-gate.json)

The pre-run idle intervals were 89.81% and 91.09%. The run is ambient under the two-consecutive-interval 90% gate. Whole-host idle measured 79.88% during the full workload and 78.94% during the isolated status checks. The post-run intervals were 87.12% and 89.99%. All four workload containers and both status-only containers were removed. [Host samples, job limits and cleanup](mounted-git-gate-receipts.tar.gz)

## Dirty fallback

Four alternating pairs per case and engine included all helper work and the full stock fallback. In-place binary edits at the beginning and end of the same tracked file preserved inode, size and exact mtime. The separate untracked binary exercised whole-worktree discovery. The helper selected the parallel path for the clean control and returned byte-for-byte stock NUL porcelain through the fallback for every dirty control. Both engines verified the file digests and the original index hash. [Exact edit and fallback receipts](mounted-git-gate-receipts.tar.gz)

| Status input | HVF stock → helper | OrbStack stock → helper |
|---|---:|---:|
| Clean | 165.45 → 100.47 ms | 50.65 → 48.06 ms |
| Changed bytes at start | 164.41 → 260.82 ms | 52.79 → 96.36 ms |
| Changed bytes at end | 161.63 → 253.44 ms | 52.15 → 96.55 ms |
| Untracked file | 159.25 → 259.22 ms | 54.67 → 96.41 ms |

The paired dirty Git cost was 91–99 ms on HVF and 42–44 ms on OrbStack. At those observed costs, an illustrative workload with the same clean and dirty checks would need roughly 58–60% clean checks on HVF or 93% on OrbStack to save Git time. The experiment covered one active two-CPU job at a time. [Clean and dirty pair deltas](mounted-git-gate.json)

## Stock preload setting

A separate same-worker test alternated the stock command and `-c core.preloadIndex=false` six times. HVF medians were 157.87 ms and 153.92 ms. OrbStack medians were 49.40 ms and 49.50 ms. On both engines Trace2 dropped 1,058 preload `lstat` calls and retained 1,058 refresh `lstat` calls and 1,058 content scans. Both settings reported the exact-time edits and restore correctly. A caller can apply this setting for one invocation with `git -c core.preloadIndex=false status`. [Raw trials](mounted-git-preload.json) · [Git 2.39.5 preload source](https://github.com/git/git/blob/v2.39.5/preload-index.c#L90-L102)

The two guests read the same Git 2.39.5 binary and byte-identical Mac index and config. Git read repository format 0, `filemode=true`, `bare=false`, `logallrefupdates=true`, `ignorecase=true` and `precomposeunicode=true` from `.git/config`. The fixture skipped system and global config. The candidate setting came from the command line. No filesystem monitor, untracked cache or stat-check override was configured. A private Linux-refreshed index in a separate clean control performed zero content scans on both engines. [Configuration origins and private-index control](mounted-git-preload.json) · [The private-index contract](pinned-checkout.md)

An initial calibration passed a second shell through the image's default shell entrypoint. The first exec returned `ttrpc: closed` before any status sample. Cleanup found no remaining object. The measured rerun selected `/bin/sh` explicitly. [Initial failure receipt](mounted-git-gate-receipts.tar.gz)

The default mounted-checkout benchmark retains stock Git. The opt-in helper still reads every mismatched file and leaves a warm-checkout gap to OrbStack on this fixture. [Raw mounted Git and Go pipeline](core-pid1-and-mutable-gamma.md#mutable-host-checkout)
