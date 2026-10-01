# Storage location: putting runtime data on another volume

Micropod's bulk lives in two trees:

| Tree | Default | Holds |
|---|---|---|
| `container` | `~/Library/Application Support/com.apple.container` | images, container root filesystems, volumes (cache goldens, workspaces), the k3s VM |
| `micropod` | `~/.micropod/{sandbox,native,k8s,builds,backup,loads}` | sandbox rootfs cache and clones, checkpoints, the native k8s VM, build contexts |

On a rig whose internal disk is full, move both to another local APFS
volume, such as an external drive:

```sh
micropod storage volumes                                  # candidates, free space, format
micropod storage set /Volumes/External/micropod --migrate # stop runtime, copy, link, start
micropod storage show                                     # where each tree is now
micropod storage remove-old                               # once happy: delete the internal copies
```

The same is in the app under **Settings → Storage Location**.

## How it works

`set` stops the container runtime, copies each tree under the new directory
with `ditto` (or starts it empty without `--migrate`), moves the original
aside as `<path>.pre-relocate`, and replaces the default path with a
**symlink** to the new location. Then it starts the runtime again.

The symlink is the setting. Apple `container` 1.5.0's `system start`
defaults `--app-root` to `ApplicationRoot.defaultPath` and does not read
`CONTAINER_APP_ROOT`, so a flag or environment variable would be lost by the
next plain `container system start`, whether from this app, a script, or the
Cuttlefish agent's runtime repair. Every one of them follows the link. Each
micropod tree moves whole, so the sandbox engine's APFS clones stay on a
single volume.

## Requirements and safety

- The volume must be **APFS**: container disks are sparse, and the sandbox
  clones with `clonefile`. `validate` refuses other formats, unmounted
  `/Volumes/<name>` paths, and directories inside the data being moved.
- **Keep the drive connected.** If it is missing, the links dangle, the
  runtime fails to start rather than silently recreating data on the
  internal disk, and `micropod storage show` (exit 1) and Settings name the
  volume to mount.
- Nothing is deleted automatically: the internal copies stay until
  `micropod storage remove-old`. `micropod storage reset [--migrate]` moves
  everything back.
- Running containers stop while the runtime restarts.

## Cuttlefish rigs

The Cuttlefish agent keeps its own host caches and storage volume under
`~/.cuttlefish`. Move those with the rig's own settings, not this one:
`CUTTLEFISH_STORAGE_VOLUME` in `~/.cuttlefish/rig.conf`, and the cache
host-dir root `CUTTLE_CACHE_HOST_DIR`. Micropod-mode rigs keep their cache
goldens as container volumes, so they move with the `container` tree.
