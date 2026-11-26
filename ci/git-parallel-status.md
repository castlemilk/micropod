# Check a Mac checkout from a CI container

Use `git_parallel_clean.py` for a clean-worktree check on a read-only Mac checkout bind. The helper keeps ordinary Git discovery and returns the output and exit status of `git --no-optional-locks status --porcelain=v1 -z --untracked-files=all`. Changes appear as NUL-delimited records. Check whether stdout is empty to require a clean checkout.

The helper copies the index into temporary storage and preserves its exact modification timestamp. It gives stock Git disjoint sets of tracked paths and checks staged and untracked state across the full checkout. Each Git subprocess reads the actual worktree. A dirty result, an unsupported index layout, or a detected change to the original index, HEAD or repository config sends the caller through the full stock command.

Supply a checkout and a support directory inside the worker's configured share. Keep the support directory outside the checkout. The image needs Python 3 and Git. The measured image used Python 3.12 and Git 2.39.5. Use the worker's explicit Docker endpoint.

```sh
cp ci/git_parallel_clean.py "$support/git_parallel_clean.py"
docker --host "$endpoint" run --rm \
    --mount "type=bind,source=$checkout,target=/workspace,readonly" \
    --mount "type=bind,source=$support/git_parallel_clean.py,target=/run/git_parallel_clean.py,readonly" \
    --entrypoint python3 "$image" /run/git_parallel_clean.py --workers 4 /workspace
```

A checkout with a regular `.git` directory and a fully populated, unsplit index is eligible for the parallel check. Linked worktrees, split indexes, sparse directory entries, conflicts and submodule entries go through stock status. Git applies the caller's configuration, including any command-scoped `safe.directory` passed through `GIT_CONFIG_COUNT`. The helper leaves Git configuration untouched. The output reflects reads during the scan interval. A CI publisher that needs a fixed revision can use a pinned checkout. [Pinned immutable checkout](pinned-checkout-job.md)

Two and four are the supported worker limits. On the measured two-CPU HVF job, four concurrent Git processes reduced the median clean status check from 167.05 ms to 101.46 ms. A follow-up reduced warm clean Git, build and test time from 915.13 ms to 850.42 ms. A dirty check added 91–99 ms of Git time before returning stock status. Use the helper for jobs that usually check a clean checkout. [Measured commands, complete workloads and exact-time edits](../bench/phase0-host-scheduling/docs/benchmarks/2026-11-26/mounted-git-status.md)
