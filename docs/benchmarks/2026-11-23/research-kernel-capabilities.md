# Linux 7.3.5 worker kernel configuration evidence

The upstream Linux Kconfig resolver accepted both the Micropod `full` and `full-16k` profiles. The compiler, target, Apple seed and Micropod preemption and network options were identical across the pair. Both resolved configs passed the worker builder’s post-resolution checks. The candidate selected 16 KiB pages with `CONFIG_PAGE_SHIFT=14`. Its config differed from the 4 KiB control in 17 symbols. Two runs from fresh copies of the same seed produced byte-identical configs for each profile.

This checks configuration on a Darwin host targeting Linux arm64. The next acceptance step is to build both images with the same ARM64 Linux toolchain, verify the raw image page granules, boot them in distinct worker homes, check OCI and filesystem compatibility and measure the workloads. The experiment produced zero kernel images, VM boots and timed samples. [Kernel builder](../../../ci/build-worker-kernel.sh) · [Image and config comparison](../../../scripts/relaybench/kernel_candidate.py)

## Inputs and receipts

| Artifact | SHA-256 |
| --- | --- |
| Linux 7.3.5 source tar.xz, pinned by the worker builder | `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990` |
| Archived Apple seed config | `a5dfc1ee37dcd4bc6d727e4de617bc45a40cf32e7ebc52fb6f0472c8fbf60c21` |
| Worker builder configuration fragment, from seed copy through post-Kconfig checks | `124b9f52939319591323bbd715eb63ffea6782220ff584e819c0cf48e58ec9e2` |
| Host-built upstream `conf` executable used here | `391e5b435a212012e206a1dbd0e5b31caf28e0e91bdd33f6d3e1dfd423f6b470` |
| Resolved cross-target `full.config` | `d8ac7c0eb2b56fc46ce76cd0da4c289a9e6485d813687abf923bc9b8f1f7e272` |
| Resolved cross-target `full-16k.config` | `ce460bc5a65965701f35535aa4e0142bad12594e420a6d809de19a42c08a41dc` |
| Previously qualified Gamma stock Image, inspected from its local archive | `7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd` |
| Archived stock config accompanying that image | `a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c` |

## Resolved differences

Each config contained 2,871 assignments or explicit disabled symbols. “Absent” means the resolver omitted the symbol. The selected virtual address width remained 48 bits, the configured native mmap randomization setting remained 18 bits, and transparent huge pages remained disabled. The candidate’s reduced maximum randomization setting and different allocation and contiguous mapping geometry are relevant when interpreting memory results.

| Kconfig symbol (CONFIG_ prefix) | Full | Full 16 KiB |
| --- | ---: | ---: |
| ARCH_FORCE_MAX_ORDER | 10 | 11 |
| ARCH_MMAP_RND_BITS_MAX | 33 | 31 |
| ARCH_MMAP_RND_BITS_MIN | 18 | 16 |
| ARCH_MMAP_RND_COMPAT_BITS_MIN | 11 | 9 |
| ARCH_WANTS_THP_SWAP | y | Absent |
| ARM64_16K_PAGES | n | y |
| ARM64_4K_PAGES | y | n |
| ARM64_CONT_PMD_SHIFT | 4 | 5 |
| ARM64_CONT_PTE_SHIFT | 4 | 7 |
| ARM64_VA_BITS_36 | Absent | n |
| ARM64_VA_BITS_39 | n | Absent |
| ARM64_VA_BITS_47 | Absent | n |
| HAVE_PAGE_SIZE_16KB | Absent | y |
| HAVE_PAGE_SIZE_4KB | y | Absent |
| PAGE_SHIFT | 12 | 14 |
| PAGE_SIZE_16KB | Absent | y |
| PAGE_SIZE_4KB | y | Absent |

Both configs retained `CPU_MITIGATIONS`, `SECURITY_SELINUX`, `SECCOMP`, `STRICT_KERNEL_RWX`, `STACKPROTECTOR_STRONG` and `RANDOMIZE_BASE` built in. `PREEMPT`, `VIRTIO_NET`, `MACVLAN`, `NF_TABLES_INET`, `CGROUPS`, `CFS_BANDWIDTH`, `MEMCG`, `USER_NS` and `NET_NS` also remained built in. Linux 7.3.5 defines the granule-dependent randomization bounds and contiguous shifts in `arch/arm64/Kconfig`. It explicitly selects `ARCH_WANTS_THP_SWAP` only for 4 KiB pages.

## Comparison with the archived stock kernel

The archived stock Image header reports arm64 little-endian flags `0xa`, encoding 4 KiB pages. Its config specifies GCC 15.2.0 from Alpine and pahole 1.30. The cross-target 4 KiB resolution differs from that archived config in 52 symbols, counting changes between absent and explicitly disabled. It is suitable as the control for this paired configuration exercise. Deployment qualification still needs the matched native compiler and tools.

Two other backlog experiments have separate prerequisites in the archived stock config:

- **Cgroup scheduling.** Stock has BTF enabled and `SCHED_CLASS_EXT` disabled. In the pinned kernel, `kernel/Kconfig.preempt` requires BPF syscall, JIT and debug BTF for sched_ext. `init/Kconfig` separately gates `EXT_GROUP_SCHED` and `EXT_SUB_SCHED`. The inspected scheduler implementation exposes cgroup weight callbacks and sub-scheduler attach operations. The string `cgroup_mode` was absent from `kernel/sched/ext/*.c`, `include/linux/sched/ext.h` and the sched-ext overview. A benchmark needs a verified policy attachment, cgroup scope and effective CPU quota on a qualified sched_ext kernel.
- **FUSE passthrough.** Stock and both cross-target configs have `VIRTIO_FS=y`, `FUSE_FS=y` and `FUSE_PASSTHROUGH=n`. The pinned `fs/fuse/Kconfig` has a separate passthrough option. The protocol requires capability negotiation and per-file backing registration and open flags, documented in `Documentation/filesystems/fuse/fuse-passthrough.rst`. Actual Apple shared-filesystem backend support still needs verification before measuring a passthrough candidate.

## Method

The run used macOS 26.5.1 arm64, Apple Clang 21.0.0 (`clang-2100.1.1.101`), GNU Bison 2.3 and Apple Flex 2.6.4. It read local pinned inputs and extracted Kconfig files and their build helpers into 29 MiB of temporary space. The upstream parser, scanner and C sources were unmodified. The following commands built the Darwin-hosted resolver from the extracted Linux tree.

```sh
bison -t -l -d -o scripts/kconfig/parser.tab.c scripts/kconfig/parser.y
flex -o scripts/kconfig/lexer.lex.c scripts/kconfig/lexer.l
clang -std=gnu11 -O2 -Iscripts/include -Iscripts/kconfig \
  scripts/kconfig/{conf,confdata,expr,lexer.lex,menu,parser.tab,preprocess,symbol,util}.c \
  -o ../conf
```

For each arm, the run used the actual builder fragment starting at `cp "$config" .config` and ending immediately before the `Image` build. Its `make olddefconfig` invocation called the freshly built `../conf --olddefconfig Kconfig` directly. The conf process evaluated the source tree’s Kconfig expressions and compiler feature probes. Each run exited 0 with empty stderr, followed by the unmodified profile checks. No resolved values were injected.

The target environment used `ARCH=arm64`, `SRCARCH=arm64`, `KERNELVERSION=7.3.5`, `srctree=.`, `KCONFIG_CONFIG=.config` and `LC_ALL=C`. Both C compilers were `/usr/bin/clang`. Target flags came from `scripts/Makefile.clang`: `--target=aarch64-linux-gnu -fintegrated-as -Werror=unknown-warning-option -Werror=ignored-optimization-argument -Werror=option-ignored -Werror=unused-command-line-argument`. The ELF linker was Rust 1.99.1’s bundled GNU-flavor LLD 23.1.1. LLVM nm came from Xcode. Linux-target objcopy and pahole were unavailable, and the environment used `PAHOLE_VERSION=0`. The run bypassed the top-level Makefile and stopped before kernel image compilation. A native build can resolve toolchain-dependent symbols differently.
