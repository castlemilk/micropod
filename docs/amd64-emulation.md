# linux/amd64 containers on the HVF machine

The HVF machine is an arm64 Linux VM. It also runs linux/amd64 containers, by
translating their x86-64 programs with QEMU's user-mode emulator. Pull, create,
run and build take `--platform linux/amd64`, and both platforms of a
multi-platform image are stored side by side. An image or a request that names
no platform still gets linux/arm64.

```bash
docker pull --platform linux/amd64 ubuntu:22.04
docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m      # x86_64
docker run --rm ubuntu:22.04 uname -m                             # aarch64
docker build --platform linux/amd64 -t app:amd64 .
docker buildx build --platform linux/amd64,linux/arm64 --push -t registry/app .
```

Emulation is much slower than native execution for CPU-bound work. Starting a
container costs about the same as a native one. Compiling or installing packages
takes several times as long (see [Measurements](#measurements)). Use the
linux/arm64 variant of an image whenever one exists.

## How it works

### The emulator and its registration

The guest tool bundle ships `runner/emulators/qemu-x86_64`, a static build of
QEMU 10.0.13's user-mode emulator. It is Debian's `qemu-user` package for arm64,
pinned by digest in `ci/fetch-qemu-user.sh`. The engine starts before it opens
its socket and before buildkitd can start (`guest/runner/emulation_linux.go`).
At that point it:

1. reads `micropod.amd64=` from the kernel command line. The value `off` stops
   here and leaves linux/amd64 unavailable.
2. selects an interpreter. Rosetta is tried first, but only when a share mounts
   it at `/run/micropod/rosetta/rosetta`. No share does today; see
   [Rosetta](#rosetta). QEMU is used next.
3. mounts `binfmt_misc` and registers the interpreter as `micropod-x86_64`,
   using QEMU's x86-64 ELF magic and mask and the flags `POCF`, as Docker
   Desktop does:
   - `F` (fix binary): the kernel opens the interpreter at registration, so an
     exec in any container's mount namespace finds it. No image needs QEMU
     inside it.
   - `O` and `C`: credentials come from the program, not the interpreter, so a
     setuid-root x86-64 program works as it does natively. One example is
     `sudo` in a GitHub runner image. The interpreter then runs with those
     credentials and reads its own `QEMU_*` environment. A process that could
     already run that program as root inside its container could do the same.
     Nothing reaches past the container.
   - `P`: the program's own argv[0].
4. runs a 132-byte static x86-64 program that exits 42. Only x86-64 code that
   actually ran can produce that status. If the probe fails, the registration
   is removed and linux/amd64 is unavailable.

Setup takes about 5 ms. An identical entry left by an earlier engine in the same
boot is kept. `docker info` shows the result in its labels
(`io.micropod.platforms=linux/arm64,linux/amd64`, `io.micropod.amd64=qemu`, or
`unavailable`) and in `MicropodEmulation`, which lists the candidates and why
each was or was not used. The engine's `/version` capabilities then include
`platform-linux-amd64`.

BuildKit lists the platforms it can build by executing a test binary of each,
once, so it reports `linux/amd64` (plus the v2 and v3 levels) next to
`linux/arm64` (`docker buildx ls`).

### Turning it off

```bash
micropod machine stop
micropod machine install --amd64 off      # machine.json "amd64": "off"
micropod machine start
```

The machine then boots with `micropod.amd64=off`. A pull, create or build for
linux/amd64 is refused with a 400 that names the setting, and `docker info`
says `io.micropod.amd64=unavailable`. `--amd64 auto` turns emulation back on.
`auto` is the default and is saved as an absent key.

### Images: both platforms side by side

containerd 2.4's CRI pulls and resolves images for the native platform only: its
image store selects with `platforms.Default()`. Every CRI lookup and every image
event fails for an index record whose arm64 image is not present. One record
shape does work for any platform: a record that targets a single manifest. CRI
resolves such a record without a platform check, and containerd's transfer
service unpacks an image of any Linux architecture. So
(`guest/runner/docker_image_emulated_linux.go`):

- `docker pull --platform linux/amd64 REF` resolves REF at the registry, picks
  the amd64 manifest of the index, or checks the config of a single-platform
  manifest, and has the transfer service pull `<repository>@<manifest digest>`,
  unpacked for linux/amd64, into a record of that name. The record carries
  labels for the index it came from (`io.micropod.platform.index`), its platform
  (`io.micropod.platform`) and the tag it was pulled by
  (`io.micropod.platform.tag.<hash>`). CRI then indexes it and adds its
  config-ID record, as it does for any image it did not pull itself. Credentials
  sent with the pull (`X-Registry-Auth`) are given only to the reference's
  registry. Registry host configuration is read from the same directory CRI uses
  (`/etc/containerd/certs.d`).
- **The tag.** A tag that already names a native image keeps it, so `docker run
  TAG` and `docker pull TAG` still mean linux/arm64. A tag that names nothing yet
  is pointed at the amd64 image, as Docker does when amd64 is the only platform
  present. A tag that names an earlier amd64 image moves to the new one.
- `docker create`/`run --platform linux/amd64 REF` looks up the amd64 image for
  REF: the image last pulled by that tag for linux/amd64, the amd64 entry of the
  index the tag names, or the image pulled from that index digest. A reference
  that names only another platform's image returns Docker's 404 ("image with
  reference … was found but does not match the specified platform"), so the CLI
  pulls the right one and tries again. A no-platform create of an image whose
  platform cannot run here (linux/amd64 with emulation off, linux/arm/v7) is a
  400 at create, not an exec format error at start.
- A pull with no platform still goes through CRI. A single-platform amd64 image
  (`amd64/alpine`) pulls and runs, as on Docker Desktop. An index without an
  arm64 entry is Docker's "no matching manifest for linux/arm64", with a hint
  to ask for `--platform linux/amd64`.
- `docker image inspect` and `docker images` report the config's `Os`,
  `Architecture` and `Variant`. `rmi`, `tag`, `save` and `load` work by ID and
  by name for amd64 images as for native ones. `docker images` hides an amd64
  image whose tag is the native one; `docker images -a` lists it untagged, with
  its digest.

A pull for linux/amd64 makes two manifest GETs at the registry instead of one:
one for the index and one for the manifest. That matters only for Docker Hub's
anonymous pull limit.

### Builds

`docker build --platform linux/amd64` runs the build's x86-64 steps through the
same interpreter. BuildKit unpacks only the native result of a build it loads
into the engine. CRI cannot resolve a loaded amd64 build either, because it is
an index with its attestation manifest. So for a build for another platform the
engine does two things (`guest/runner/image_unpack_linux.go`):

- It unpacks the layers itself, the way containerd's unpacker does: containerd's
  diff service, snapshots committed under their chain IDs, all under a lease
  until the config's GC label names the top snapshot.
- It names the result so that it runs. A single-platform amd64 build's tag
  names its manifest. A build for both platforms keeps the index under the tag,
  where CRI resolves arm64, and adds `<repository>@<digest>` for the amd64
  entry, so `--platform linux/amd64` finds it.

`docker buildx build --platform linux/amd64,linux/arm64 --push` (or
`--output type=oci|registry`) builds both platforms.

### Caches, trust, limits and families

An emulated container is an ordinary container. It gets the same cache scope,
trust tier and copy-on-write read-only views for untrusted work, the same
limits, the same family-scoped Docker socket and the same masked machine
directory. Its cache stores are shared with native containers wherever sharing
is safe across architectures:

- Go's build cache keys every entry by the toolchain binary and the target.
- The module, npm and pnpm stores are content-addressed sources. pnpm keys its
  side-effects cache by platform.
- pip, uv, cargo, maven, gradle and bun keep sources, or name each binary
  artifact by its platform.

One store is left out: Playwright's browsers (`chromium-<revision>/`). They are
programs for the architecture that downloaded them, under names that do not
say which. An emulated container gets no Playwright store
(`MicropodCache.tools.playwright.reason = emulated-platform`).

### Durability

A pull for linux/amd64 answers only after `imageSync.Sync`, the same syncfs
and recorded sync time a native pull waits for. A build for linux/amd64 is
unpacked before the build's own sync. After an unclean stop, the image store
recovery now checks the snapshots of every Linux image, not only arm64 ones,
and removes an amd64 image whose layers were committed after the last sync.
This closes an existing gap: containerd's transfer service had always unpacked
single-platform amd64 pulls, and recovery skipped them.

## Rosetta

Apple's Rosetta for Linux is far faster than QEMU, and this Mac has it
(`/Library/Apple/usr/libexec/oah/RosettaLinux/rosetta`, version 367.4, a static
aarch64 ELF). It cannot run under micropod-vmm without impersonating
Virtualization.framework, which Micropod does not do:

- **The host check.** At start, Rosetta issues undocumented ioctls on its own
  executable through the virtiofs share it runs from. In this build these are
  `0x80456125` (69 bytes, compared with `memcmp` against a fixed text embedded
  in the binary that ends "please don't steal / © Apple Inc"), `0x80806123`
  (128 bytes) and `0x00006124`. Only Virtualization.framework's
  `VZLinuxRosettaDirectoryShare` answers them. Without the answers Rosetta
  exits with "Rosetta is only intended to run on Apple Silicon with a macOS
  host using Virtualization.framework with Rosetta mode enabled". Answering
  them from our virtiofs server would mean copying Apple's text into Micropod
  and defeating an access check. That is circumvention, not interoperability.
  libkrun shipped such a workaround and later removed it ("macos: drop Rosetta
  support").
- **TSO is not the obstacle.** Translated x86-64 code assumes total store
  ordering. Hypervisor.framework exposes it per vCPU on macOS 15 and later:
  `hv_vcpu_set_sys_reg(HV_SYS_REG_ACTLR_EL1)` sets bit 1, EnTSO, the only bit
  the API allows. micropod-vmm's `hvf-sys` already declares that register
  (0xc081), so a VMM could enable TSO. It would slow native code on those vCPUs
  and buys nothing for QEMU, which orders x86-64 memory accesses itself, so the
  VMM leaves it off.
- **What would make it work.** A Virtualization.framework VM, which the
  one-runtime decision rules out, or an Apple-supported Rosetta interface for
  Hypervisor.framework. The engine already tries Rosetta first: a VMM that
  could mount a legitimate Rosetta share at `/run/micropod/rosetta` would be
  used with no other change.

Other emulators were considered. FEX-Emu would be faster than QEMU, and with
EnTSO set it would need no barriers. But FEXInterpreter is a dynamically linked
arm64 program, so it cannot be the fixed interpreter inside an x86-64 container
without a static build. Box64 has a static build option but is less complete
for server software (.NET, Go and Node toolchains). QEMU is the complete one.

## Licence

QEMU is GPL-2.0, with LGPL-2.1 and BSD-licensed parts. The bundle carries
Debian's copyright file (`runner/emulators/qemu-x86_64.copyright`) and a
`runner/emulators/SOURCE` naming the exact Debian source package
(`qemu 1:10.0.13+ds-0+deb13u1`, on snapshot.debian.org). Shipping it adds no new
kind of obligation: the payload already ships GPL-2.0 binaries, crun and the
Linux kernel. A release that distributes the bundle should offer that source
alongside it, as it should for crun and the kernel. The 14 MB binary adds about
7% to the 191 MB tool bundle. No Apple software is copied or redistributed.

## Measurements

These were measured on Gamma, a 128 GB Mac, on 2026-11-28. The machine was a
throwaway 8 vCPU / 12 GiB HVF machine running this engine, the master-65856a76
payload's VMM and kernel, and an OS disk cloned from `worker.ext4`. The rig's
machine and other agents' machines ran on the same Mac at the same time. Each
row is `docker run --rm --platform P … --label io.micropod.cache=off`, timed
from the host CLI. Native and emulated runs were interleaved. With no CPU
quota, as the rig's `defaultLimits: none` runs containers:

| case | linux/arm64 | linux/amd64 (QEMU) | ratio |
|---|---|---|---|
| start and exit, `alpine:3.20 true` (median of 20) | 0.135 s | 0.138 s | 1.02x |
| start and exit, `ubuntu:22.04 true` (median of 20) | 0.141 s | 0.149 s | 1.06x |
| start and exit, `gha-job:0.1.15 true` (median of 20) | 0.145 s | 0.150 s | 1.03x |
| `node --version` in gha-job:0.1.15 (median of 3) | 0.151 s | 0.325 s | 2.2x |
| `go build` of `cmd/gofmt` and its std deps, cold `GOCACHE` (golang:1.25, median of 3) | 2.40 s | 31.6 s | 13x |
| node:22, 3×10⁸-iteration JS loop (median of 3) | 0.52 s | 5.54 s | 11x |
| node:22, `npm install` of 6 packages (express, lodash, typescript, axios, dayjs, zod), cold cache, from the registry (median of 3) | 2.78 s | 13.7 s | 4.9x |

The same cases under the shipped default limit of 1 CPU (`defaultLimits: job`):
the Go build took 5.9 s native and 110 s emulated (19x), the JS loop 0.65 s and
3.9 s, and the npm install 4.3 s and 20.0 s. A cold pull of
`gha-job:0.1.15@sha256:acc64bec…` for linux/amd64 took 19.5 s, and the image
ran (`uname -m` printed x86_64, Ubuntu 24.04.5, `sudo -n true` worked as root).
Engine start-up spends 5 ms selecting, registering and probing the emulator.

QEMU makes emulated containers start as fast as native ones. Any CPU-bound
step is an order of magnitude slower. A GitHub-compatibility job pinned to
linux/amd64 runs correctly on this machine, but its compile and test steps take
roughly 5 to 15 times as long as on an x86-64 host or as the job's linux/arm64
form.
