# Runtime-authority VM release gate

The nine tests in docs/runtime-component-update.md ("VM release gate") run
in a throwaway macOS 26 VM. This page is the procedure for one Apple Silicon
host (written for HN91XC4WQ9: 32 GB RAM, about 72 GB free).

Ground rules:

- Only the VM is changed. Don't run `cuttle`, `micropod`, `launchctl` or
  Docker commands on the host. The host's Cuttlefish agent stays paused and
  idle for the whole run.
- **No other virtual machine may run on the host**, and "the agent is
  paused" does not prove that: Micropod's dedicated runtime, Apple container
  and Docker Desktop each run VMs on their own. Check before you start (and
  `gate-host.sh` checks again before every boot):

  ```sh
  pgrep -fl 'com.apple.Virtualization.VirtualMachine|container-runtime-linux'
  ```

  It must print nothing. If it prints anything, stop and ask the coordinator;
  don't stop those VMs yourself.
- Everything lives in `~/micropod-gate-vm` (tart, its image, VMs, results)
  and `~/micropod-rc` (inputs). Deleting both removes it all.
- The VMs write only `~/micropod-gate-vm/out`. Treat it as untrusted: the
  host script never writes there, refuses it if it holds a symbolic link, and
  shows guest text with `cat -v`. Read the logs there with `cat -v` too. The
  host's own logs are in `~/micropod-gate-vm/logs`.
- The gate runner refuses to run anywhere but a hardened gate VM: it needs
  `kern.hv_vmm_present = 1`, the root-owned marker `/var/db/micropod-gate-vm`
  that `harden` writes, no Cuttlefish process, `.cuttlefish` folder or
  install, and no Micropod runtime the gate did not create itself.
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
bash ~/micropod-rc/gate-host.sh preflight
bash ~/micropod-rc/gate-host.sh tart
bash ~/micropod-rc/gate-host.sh base
bash ~/micropod-rc/gate-host.sh key
```

`key` makes the ssh key the VMs accept and puts its public half in
`~/micropod-rc/gate_key.pub`, where `harden` picks it up.

`base` refuses to start with less than 60 GB free.

## 3. The release candidates

Candidates are draft qualification builds (docs/release-qualification.md);
nothing is published. After #178 is on master, dispatch Release twice:

- **A**: `qualification_version` = the version under test.
- **B**: a newer `qualification_version`, with
  `qualification_security_floor` set to B's own version (G6, G7, G8).

Both are throwaway drafts. B's floor is recorded in its
`qualification-source.txt`, so publication refuses it whatever happens. Delete
both drafts and their tags when the gate is done (section 8).

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

## 4. Harden each base VM first

Every base VM (`gate-fresh` and `gate-legacy-base` below) runs `harden`
before anything else. The VM logs in as `admin` by itself. Open Terminal in
the VM and run:

```sh
G="/Volumes/My Shared Files/rc/runtime-authority-gate.sh"
bash "$G" harden
```

It refuses unless it runs in a fresh VM (see the ground rules). It asks for
the current password (`admin` on the vanilla image), then:

- writes the root-owned marker the other steps require;
- sets a random password and keeps automatic login working (the shared
  folder mounts at login). **It prints the password once**: write it down;
  sudo in this VM and its clones asks for it;
- installs `gate_key.pub` and turns ssh into key-only;
- removes every passwordless sudo rule (if `/etc/sudoers` itself has one,
  the check fails: remove it with `sudo visudo`, then run `harden` in a fresh
  clone).

In the legacy base only, run `bash "$G" harden matrix` instead. That also
installs a root-owned copy of the runner and a sudo rule letting the host run
exactly `g3-kill`, `g3-check` and a reboot without a password, nothing else.

Shut a VM down from inside with `sudo shutdown -h now`. To reboot when the
runner asks: `sudo shutdown -r now`, then run the step it names.

## 5. Fresh track: G1, G2, G5, G6, G7, G8

```sh
H=~/micropod-rc/gate-host.sh
bash $H clone gate-base gate-fresh
bash $H run gate-fresh
```

In the VM: `bash "$G" harden`, then `bash "$G" g1`. It pauses once (note any "Background Items
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

In the VM: `bash "$G" harden matrix`, then `bash "$G" prepare-legacy`. It
pauses for the human steps: open Micropod Runtime Setup, click Install
Dedicated Runtime, approve "Micropod Runtime Setup" in System Settings →
General → Login Items & Extensions, and wait for the runtime. Then shut it
down.

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
steps. The kill is armed by a root-owned `RuntimeHost/gate-kill.json` naming
the checkpoint and the CLI's CDHash, used once and expiring after 30 minutes:

```sh
bash $H matrix
```

## 7. Results

```sh
bash $H results
```

`~/micropod-gate-vm/out/results.tsv` has one line per step (PASS, FAIL,
INCOMPLETE, BASELINE) and `out/logs/` the detail of every check, both written
by the VMs; `logs/matrix.log` is the matrix, written by the host. INCOMPLETE
means an input was missing; it is not a pass.

## 8. Delete it

```sh
bash ~/micropod-rc/gate-host.sh cleanup
rm -rf ~/micropod-rc
```

Then delete the two gate drafts and their tags (B's floor makes it
unpublishable anyway; A was built only for the gate):

```sh
gh release delete <A-tag> -R castlemilk/micropod --cleanup-tag --yes
gh release delete <B-tag> -R castlemilk/micropod --cleanup-tag --yes
```

`cleanup` stops every gate VM and removes `~/micropod-gate-vm`: tart, the
image cache, every VM and the results. Copy `out/` first if you want to keep
them.
