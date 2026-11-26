# Run a job on a pinned immutable checkout

Use [pinned-checkout-job.sh](pinned-checkout-job.sh) when a CI publisher can keep a Mac checkout fixed for a job's lifetime. The guest reads the host worktree through its regular read-only bind mount. A private Linux filesystem at `.git` holds the pinned commit, Git objects and a native index. The job and any nested commands use ordinary Git discovery.

The publisher must keep both file contents and path bindings fixed until the job exits. A guest read-only bind protects the Mac files from the job. The publisher supplies the immutable host checkout. The entrypoint checks the read-only mount and verifies the tracked files against the pinned commit at startup.

Use a standalone repository with a `.git` directory and a complete Git bundle that contains the commit. The job starts at detached HEAD with its own index, config and refs. It can stage and commit into that private Git directory. Independent nested repositories keep their own Git discovery. A linked worktree or a checkout with submodules needs its original Git layout.

The Linux image needs a shell, Git, `stat` and util-linux `findmnt`. Set `checkout` to the pinned checkout and `control` to a staging directory outside it. Both must be under the worker's configured share. Set `endpoint` to that worker's Docker endpoint and `image` to the job image.

```sh
stage=$(mktemp -d "$control/pinned-git.XXXXXXXX")
commit=$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}')
git -C "$checkout" bundle create "$stage/revision.bundle" HEAD
cp ci/pinned-checkout-job.sh "$stage/entrypoint.sh"

docker --host "$endpoint" run --rm \
    --mount "type=bind,source=$checkout,target=/workspace,readonly" \
    --mount "type=bind,source=$stage/entrypoint.sh,target=/run/pinned-checkout-job.sh,readonly" \
    --mount "type=bind,source=$stage/revision.bundle,target=/run/revision.bundle,readonly" \
    --tmpfs /workspace/.git:rw,nosuid,nodev,noexec,size=128m,mode=0700 \
    --entrypoint /bin/sh "$image" /run/pinned-checkout-job.sh \
    --immutable /workspace /run/revision.bundle "$commit" -- \
    sh -ec 'git status --porcelain=v1 && make test'
```

Prepare the complete bundle once per revision and reuse it across jobs. Each container needs its own empty, writable `.git` filesystem owned by the job user. For non-root jobs, set the tmpfs `uid` and `gid` to that user. Size it for the repository and any objects the job creates.

Use the ordinary workspace bind for checkouts that the Mac edits while a job is running. Git builds that compare whole-second timestamps can miss a same-second, same-size edit to an already indexed file when the writer restores its modification time. A host memory mapping can also change bytes while the observable stat fields stay fixed.
