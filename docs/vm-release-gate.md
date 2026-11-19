# Runtime-authority VM release gate

The nine tests in docs/runtime-component-update.md ("VM release gate") run
in a throwaway macOS 26 VM. This page is the procedure for one Apple Silicon
host (written for HN91XC4WQ9: 32 GB RAM, about 72 GB free).

Ground rules:

- Only the VM is changed. Don't run `cuttle`, `micropod`, `launchctl` or
  Docker commands on the host. The host's Cuttlefish agent stays paused and
  idle for the whole run.
- Everything lives in `~/micropod-gate-vm` (tart, its image, VMs, results)
  and `~/micropod-rc` (inputs). Deleting both removes it all.
- macOS runs at most two macOS VMs at once. The gate runs one at a time.
- Commands are one per line. Run them in Terminal on the host unless a step
  says "in the VM".

## Disk

The image is about 24 GB to download and about 30 GB on disk. Clones are
copy-on-write: each grows by what its tests install (a few GB). With two
bases kept, peak use is about 45 GB, leaving about 25 GB of headroom on 72 GB.
Check at any time:

```sh
bash ~/micropod-rc/gate-host.sh space
```

## 1. The gate scripts

`REF` is the commit named in the PR comment, which also lists both files'
SHA-256.

```sh
mkdir -p ~/micropod-rc
cd ~/micropod-rc
REF=<commit>
R=repos/castlemilk/micropod/contents/scripts/vm
A='Accept: application/vnd.github.raw'
gh api -H "$A" "$R/gate-host.sh?ref=$REF" > gate-host.sh
gh api -H "$A" "$R/runtime-authority-gate.sh?ref=$REF" > runtime-authority-gate.sh
shasum -a 256 gate-host.sh runtime-authority-gate.sh
```

Compare the two digests with the PR comment before going on.

## 2. tart and the image

tart 2.41.1 is pinned by SHA-256 and checked for Cirrus Labs' Developer ID
(team `9M2P8L4D89`) and notarization before it is used. The image is pinned
by digest (`macos-tahoe-vanilla` 26.6.2: SIP on, user `admin`, password
`admin`).

```sh
bash ~/micropod-rc/gate-host.sh tart
bash ~/micropod-rc/gate-host.sh base
```

`base` refuses to start with less than 60 GB free.

## 3. The release candidates

Candidates are draft qualification builds (docs/release-qualification.md);
nothing is published. After #178 is on master, dispatch Release twice:

- **A**: `qualification_version` = the version under test.
- **B**: a newer `qualification_version`, with
  `qualification_security_floor` set to B's own version (G6, G7, G8).

Download them, 0.13.3 and the optional inputs:

```sh
cd ~/micropod-rc
P='Micropod.*.tgz'
gh release download <A-tag> -R castlemilk/micropod -p "$P" -D A
gh release download <B-tag> -R castlemilk/micropod -p "$P" -D B
gh release download v0.13.3 -R castlemilk/micropod -p "$P" -D legacy
mkdir -p other-team
cp ~/micropod-gate-vm/tart.app/Contents/MacOS/tart other-team/
```

`other-team` needs any Developer ID binary from another team; tart is one.
Optionally, an Apple Development-signed helper for G2 (skip it if the host
has no Apple Development identity):

```sh
mkdir -p ~/micropod-rc/apple-development
cd ~/micropod-rc/apple-development
tar -xzf ../A/Micropod.*.tgz Micropod.app/Contents/Helpers
h="Micropod.app/Contents/Helpers/Micropod Runtime Setup.app"
cp "$h/Contents/MacOS/MicropodRuntimeHost" helper
rm -rf Micropod.app
I=com.skunkworq.micropod.runtime-authority
codesign -f -s "Apple Development" -i "$I" helper
```

The VM sees `~/micropod-rc` read-only at `/Volumes/My Shared Files/rc`, and
writes results to `~/micropod-gate-vm/out`.

## 4. In every VM

The VM logs in as `admin` by itself. Open Terminal in the VM and set:

```sh
G="/Volumes/My Shared Files/rc/runtime-authority-gate.sh"
sudo -n true && echo ok
```

If `sudo -n true` asks for a password, the password is `admin`; the matrix
in step 6 needs sudo without one, so in the legacy base VM run:

```sh
L='admin ALL=(ALL) NOPASSWD: ALL'
echo "$L" | sudo tee /etc/sudoers.d/gate
sudo visudo -cf /etc/sudoers.d/gate
```

To shut a VM down from inside: `sudo shutdown -h now`. To reboot when the
runner asks: `sudo shutdown -r now`, then run the step it names.

## 5. Fresh track: G1, G2, G5, G6, G7, G8

```sh
H=~/micropod-rc/gate-host.sh
bash $H clone gate-base gate-fresh
bash $H run gate-fresh
```

In the VM: `bash "$G" g1`. It pauses once (note any "Background Items
Added" notice), then shut the VM down. `gate-fresh` is now the base with A
installed. Each further test runs on its own clone:

```sh
bash $H clone gate-fresh gate-t
bash $H run gate-t
```

In the VM, one of: `bash "$G" g2`, `g5`, `g6`, `g7-crash`, `g7-hang`,
`g7-floor`, `g8`. Then shut it down and, on the host:

```sh
bash $H rm gate-t
```

Repeat for the next test. `g6` asks you whether any prompt appeared.
`g7-hang` takes up to 25 minutes (three 120-second watchdog cycles and the
rollback).

## 6. Legacy track: G9, G4, G3

The 0.13.3 base, with its SMAppService helper approved:

```sh
bash $H clone gate-base gate-legacy-base
bash $H run gate-legacy-base
```

In the VM: `bash "$G" prepare-legacy`. It pauses for the human steps:
open Micropod Runtime Setup, click Install Dedicated Runtime, approve
"Micropod Runtime Setup" in System Settings → General → Login Items &
Extensions, and wait for the runtime. Before shutting it down, on the host:

```sh
bash $H key gate-legacy-base
```

(password `admin`). Then, in the VM, set up sudo without a password (step 4)
and shut down.

**G9 then G4 (after)**, on one clone:

```sh
bash $H clone gate-legacy-base gate-t
bash $H run gate-t
```

In the VM, in order, rebooting each time it asks:

```sh
bash "$G" g9
bash "$G" g9-reboot
bash "$G" g4-after
bash "$G" g4-after-reboot
```

`g9` pauses for the Retire the Old Background Item… click. Shut down, then
`bash $H rm gate-t`.

**G4 (before)**, the baseline, on its own clone:

```sh
bash $H clone gate-legacy-base gate-t
bash $H run gate-t
```

In the VM: `bash "$G" g4-before`, reboot, `bash "$G" g4-before-after`. Shut
down and `bash $H rm gate-t`. It reports BASELINE (whether the residual
reproduced), not PASS.

**G3, the kill matrix**: twelve headless clones, about an hour, no human
steps:

```sh
bash $H matrix
```

## 7. Results

```sh
bash $H results
```

`~/micropod-gate-vm/out/results.tsv` has one line per step (PASS, FAIL,
INCOMPLETE, BASELINE), `out/logs/` the detail of every check and
`out/matrix.log` the matrix. INCOMPLETE means an input was missing; it is not
a pass.

## 8. Delete it

```sh
bash ~/micropod-rc/gate-host.sh cleanup
rm -rf ~/micropod-rc
```

`cleanup` stops every gate VM and removes `~/micropod-gate-vm`: tart, the
image cache, every VM and the results. Copy `out/` first if you want to keep
them.
