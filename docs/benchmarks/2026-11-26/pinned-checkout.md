# Git metadata on the Gamma checkout

Linux Git 2.39.5 rescanned the contents of all 1,058 tracked files when it opened the Mac-authored index. A Linux-refreshed private index left those rescans at zero. Git still issued 1,058 tracked-file stat calls. On the current Gamma baseline, warm Git status took 132.52 ms on HVF and 57.77 ms on OrbStack with the Mac index. With the private index, it took 29.24 ms and 10.50 ms. The private-index diagnostic kept the same worktree bind on both engines. [Gamma receipts](mounted-ci-gamma-receipts.tar.gz)

For `main_linux.go`, the current Mac index recorded inode 12,540, UID 501 and GID 20. HVF reported inode 4,766 and OrbStack reported 282,515. Both guests reported UID and GID 0. File size and both timestamps matched at full nanosecond precision. Device numbers also differed. On the same Linux Git binary, changing only the stored inode, UID or GID in a disposable one-entry index caused a content rescan. The device field and the isolated nanosecond portions of ctime and mtime had no effect. Changing the whole-second part of either timestamp caused a rescan. VirtioFS already passes the timestamp precision through. Its inode identity and mapped ownership serve the guest's page cache and permissions. [Field controls](mounted-ci-gamma-receipts.tar.gz) · [Earlier raw samples](../2026-11-25/managed-ci-git-and-exec.md#git-metadata-and-host-edits) · [Git stat comparison](https://github.com/git/git/blob/v2.39.5/read-cache.c#L153-L202)

## Mutable worktree control

A 12-byte binary changed in place with the same inode, size and exact mtime. Host ctime advanced from 1795620712.029574211 to 1795620712.115949665. The guest observed the new bytes and the updated nanoseconds. Git with the Mac-authored index reported the tracked change. The refreshed private index reported a clean worktree because this Git build compares whole seconds. An earlier APFS run also observed distinct bytes with identical stat data under a writable memory mapping. Lowering Git's checks or retaining mutable VirtioFS data pages based on a stat match would leave those edits undetected. Use the ordinary workspace bind for a live Mac worktree. [Same-second receipt](mounted-ci-gamma-receipts.tar.gz) · [APFS mapping control](../2026-11-25/managed-ci-git-and-exec.md#git-metadata-and-host-edits)

## Pinned checkout

The opt-in entrypoint uses the ordinary read-only worktree bind and mounts a new Linux filesystem at `.git` for each job. It loads a complete Git bundle, pins detached HEAD, and lets stock Git verify the tracked files and build its index. A CI publisher keeps the host checkout fixed through job exit. The entrypoint checks the guest mount, ownership, empty Git directory and initial tracked contents before executing the job. [Entrypoint and invocation](../../../ci/pinned-checkout-job.md)

Two jobs per engine discovered the pinned checkout and a separate nested repository. Each job kept its own index and refs. One job staged a binary blob and committed it while its sibling held an index lock. The sibling and both host repositories retained their original HEAD and index. Both engines rejected a writable worktree bind, a missing, populated or other-owned private Git mount, and a tracked file with different content at startup. [Final contract receipt](mounted-ci-gamma-receipts.tar.gz)

The earlier mount prototype also observed exact bytes and reported dirty status after same-size atomic replacement and an in-place write that advanced ctime to a different second. The same-second control below that threshold establishes why the production contract requires host immutability. [Prototype edit receipts](mounted-ci-gamma-receipts.tar.gz)

## Cold and warm measurements

The unchanged pinned-worktree comparison keeps the same fixture, image, CPU and memory limits in all four engine and layout combinations. Its cold clock includes container start, preparation and the first verified stock Git status, Go build and uncached test run. The private layout also charges host bundle packing. Its preparation clock includes reading and importing the bundle through the mount and refreshing the index.

The first two launches ended before a candidate observation. Both raw HVF build commands exited 137 while their container continued running. The retry recorded zero memory cgroup events and a 346 MiB peak with a 1,536 MiB limit. Native exec events placed the exits at 753 ms and 2,254 ms after start, near multiples of the 250 ms peer check. Two follow-up cold builds under guest signal tracing completed, one through the normal socket and one through an observing proxy. The trace recorded teardown signals and did not capture the original failure. [Cold attempts and exec traces](mounted-ci-gamma-receipts.tar.gz)

The guest runner now rechecks the peer after an interrupted poll. Five focused Linux ARM64 tests passed, including the interrupted-poll regression, stream handling, a full disconnect, and exec and events half-closes. The frozen benchmark runner predates this change. The cause of the two aborted builds remains undetermined. [Poll implementation](../../../guest/runner/docker_http_linux.go) · [Test output](mounted-ci-gamma-receipts.tar.gz)

A fresh B5 worker completed all four combinations using the archived stock workload driver. Each warm block ran Git status with untracked files enabled, a real Go build and three uncached Go tests. Every job ran the resulting executable and checked the pinned revision. Four alternating blocks preserved the same source bytes, image and resource limits. [Complete paired receipt](mounted-ci-gamma-receipts.tar.gz)

| Engine and Git layout | Warm Git, median ms | Warm Git + Go, median guest ms | Warm host wall, median ms | First CI host wall, s |
|---|---:|---:|---:|---:|
| HVF, Mac index | 149.24 | 850.74 | 907.40 | 14.144 |
| HVF, private Git directory | 27.35 | 716.13 | 769.34 | 15.084 |
| OrbStack, Mac index | 54.10 | 701.06 | 771.53 | 13.878 |
| OrbStack, private Git directory | 8.34 | 656.26 | 741.50 | 19.382 |

The first CI host wall times start after staging the common checkout, which took 778 ms. Each private result includes 454 ms for packing the 3,760,128-byte bundle on the Mac. Reading and importing the bundle and refreshing the guest index took 175 ms on HVF and 138 ms on OrbStack. The first CI column has one observation per combination, including the first build and test. [Preparation timings](mounted-ci-gamma-receipts.tar.gz)

The private layout removed all 1,058 content rescans on both engines. It improved the warm Git, Go build and test sum in all four comparisons against each engine's Mac index. OrbStack remained faster in all four comparisons between private layouts. [Git Trace2 and paired durations](mounted-ci-gamma-receipts.tar.gz)
