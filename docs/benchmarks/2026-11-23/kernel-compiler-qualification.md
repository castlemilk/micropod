# ARM64 compiler qualification on pinned Linux 7.3.5

**Issue #235.** AutoFDO and Propeller each resolved as a single independent Kconfig change on the same 4 KiB Clang control. Requests for ThinLTO, distributed ThinLTO and full LTO each resolved back to the byte-identical no-LTO control. This host’s Xcode archiver fails the upstream LLVM-archiver check. A clean Kconfig exit alone would have enrolled three duplicate control kernels in a benchmark. The compiler audit now accepts a required LTO mode and rejects that fallback. [Issue #235](https://github.com/castlemilk/micropod/issues/235) · [Compiler audit](../../../scripts/relaybench/kernel_compiler.py)

**Issue #236.** All configurations target native AArch64 with 4 KiB pages, full preemption and the same protection settings. This experiment has zero kernel image builds, VM boots, translation runs and timed workloads. The separate 16 KiB candidate still needs image and guest compatibility qualification. [Issue #236](https://github.com/castlemilk/micropod/issues/236) · [Page-size qualification](research-kernel-capabilities.md)

## Resolved kernel configurations

The unmodified upstream Linux 7.3.5 `conf --olddefconfig Kconfig` evaluated each request against a fresh copy of the same resolved control. Each invocation exited 0. The control came from the actual Micropod `full` builder configuration stage on the archived Apple seed. All six arms resolved `CONFIG_PAGE_SHIFT=12` and `CONFIG_CPU_MITIGATIONS=y`. The results below compare complete resolved configs.

| Research direction | Requested change | Actual difference from Clang control |
| --- | --- | --- |
| 235.01 | Clang control, no LTO | Control hash `a7aa0d0b33365fcd81abf1b88afa6901e030f94d98670772c5f7ce30f08cae77` |
| 235.03 | ThinLTO | Zero differences. `CONFIG_LTO_NONE=y`. |
| 235.03 | Distributed ThinLTO | Zero differences. `CONFIG_LTO_NONE=y`. |
| 235.03 | Full LTO | Zero differences. `CONFIG_LTO_NONE=y`. |
| 235.04 | AutoFDO | Only `CONFIG_AUTOFDO_CLANG` changed from `n` to `y`. |
| 235.05 | Propeller | Only `CONFIG_PROPELLER_CLANG` changed from `n` to `y`. |

Pinned `arch/Kconfig` requires both the nm and ar tools to identify as LLVM on the first line of their help output for `HAS_LTO_CLANG`. Here the compiler and integrated assembler were Clang, the ELF linker was LLD, LLVM nm passed, the architecture allowed LTO, and the trace-recordmcount and kernel-GCOV exclusions were inactive. Xcode BSD ar failed the tool check. No standalone LLVM ar was found in PATH, Xcode/Command Line Tools, Homebrew, installed Swift SDKs, the two local Rust toolchains or the checked local SDK directories. Distributed LTO also has its own build workflow. The next native builder needs a matching LLVM toolchain with llvm-ar. Before compiling, select an exact expected Kconfig choice:

```sh
python3 -B scripts/relaybench/kernel_compiler.py \
  --config candidate.config --require-lto CONFIG_LTO_CLANG_THIN
```

Use `CONFIG_LTO_CLANG_THIN_DIST` for distributed ThinLTO or `CONFIG_LTO_CLANG_FULL` for full LTO. On the three fallback configs the respective checks exit 2. The no-LTO control passes with `CONFIG_LTO_NONE`.

## Actual compiler and linker outputs

A separate two-object check compiled the original kernel sources `lib/math/int_pow.c` and `lib/math/int_sqrt.c` with resolved worker headers. Both are unconditional objects in `lib/math/Makefile`. Each arm used Clang targeting Linux AArch64 at `-O2` and one LLD thread for a relocatable link. Each linked output passed ELF class, byte order, machine, relocatable type and symbol checks for both functions. The optional modes use flags from the pinned kernel’s Makefiles. The LTO rows exercise the compiler and linker directly. Whole-kernel eligibility is recorded separately above.

| Object compilation mode | Compiler output | Linked ELF bytes | Sum of text sections (bytes) | Observed metadata |
| --- | --- | ---: | ---: | --- |
| Control | ARM64 ELF | 2,040 | 140 | Both function symbols |
| ThinLTO | LLVM IR bitcode | 2,240 | 128 | Separate per-function text sections |
| Full LTO | LLVM IR bitcode | 2,120 | 128 | Separate per-function text sections |
| AutoFDO, collection flags | ARM64 ELF | 5,680 | 140 | Debug line data |
| Propeller, collection flags | ARM64 ELF | 5,688 | 140 | 62-byte `.llvm_bb_addr_map` plus relocations |

The trial measures the contents of these two objects. Differences in alignment, section layout and debug metadata contribute to the byte counts. It establishes neither link-time savings nor Micropod runtime throughput. No training profile was supplied. The archived stock kernel enables perf events and disables both `CONFIG_ARM_SPE_PMU` and `CONFIG_CORESIGHT`. The pinned AutoFDO and Propeller documentation describes arm64 profile collection through SPE or ETM. A training experiment still needs a verified sampling source, a workload representative of Micropod and distinct held-out measurements. Guest PMU exposure was unmeasured here.

## Reproduction inputs and preserved output

The archived source SHA-256 is `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. The Apple config SHA-256 is `a5dfc1ee37dcd4bc6d727e4de617bc45a40cf32e7ebc52fb6f0472c8fbf60c21`. The base checkout was `ea0989d6`. The host ran macOS 26.5.1 on arm64 with Apple Clang 21.0.0 (clang-2100.1.1.101), the integrated assembler, Xcode LLVM nm and Rust 1.99.1’s GNU-flavor LLD 23.1.1 and LLVM objcopy 23.1.1. The target compiler selected `aarch64-linux-gnu` even in probes that invoke CC without forwarding the target flags. The ELF objcopy was invoked with its local Rust runtime library path. Pahole was unavailable. These settings differ from the historical Alpine GCC worker toolchain.

The compressed evidence includes the three complete unique resolved configs, the six requested arms and their differences, the five base64-encoded linked ELF files and their SHA-256 values, individual input object hashes, source and Kconfig hashes, section sizes and the object compilation commands. It records a compile and link check, independent of the live benchmark fixtures. [Raw evidence](kernel-compiler-evidence.json.gz)

## Allocation policy and exec paths in the archived worker

This read-only inspection used the same pinned 7.3.5 source archive, the archived stock Image (`7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd`) and its accompanying config (`a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c`). It adds three checks to [#235](https://github.com/castlemilk/micropod/issues/235).

| Direction | Verified evidence | Remaining qualification |
| --- | --- | --- |
| 235.07 Allocation initialization | Stock explicitly disables both `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` and `CONFIG_INIT_ON_FREE_DEFAULT_ON`. The early parameter handlers for both policies are compiled into the stock Image. `include/linux/mm.h:4944` still honors per-allocation zeroing requests through `__GFP_ZERO`. | Effective boot policy, process isolation and allocation cost require evidence from the measured guest. Micropod appends optional `MICROPOD_SANDBOX_KERNEL_ARGS` at boot. A run claiming a gain from switching off the build default would duplicate the existing config. |
| 235.08 FD-anchored failfs and fchroot | The arm64 native syscall table is a symlink to `scripts/syscall.tbl`, whose entry 472 dispatches `fchroot` to `sys_fchroot`. `fs/open.c:621` implements it. `fs/Makefile:19` includes `failfs.o` unconditionally and `fs/namespace.c:6503` initializes it. Typed function records in the stock Image corroborate both implementations. | Direct searches of Micropod’s runtime, guest and CI code found no explicit adoption. Its OCI config selects a packaged crun 1.31 binary, whose internal runtime path remains unverified. Failfs deliberately rejects absolute lookups, including dynamic interpreter lookup, so compatibility with worker startup must be demonstrated. |
| 235.09 BPF-backed binary format handlers | Stock builds conventional `CONFIG_BINFMT_ELF`, `CONFIG_BINFMT_SCRIPT` and `CONFIG_BINFMT_MISC`. Ordinary `load_misc_binary` is present in Image BTF. `fs/Kconfig.binfmt:171` defines a separate `BINFMT_MISC_BPF` with dependencies on built-in misc, BPF syscall, JIT and debug BTF. The stock config satisfies those dependencies but explicitly disables this option. `fs/Makefile:36` consequently excludes `binfmt_misc_bpf.o` from that build. | A different kernel config and an actual handler/translator in the workload’s namespace are prerequisites. Native ELF and ordinary registration cannot establish BPF dispatch, translation correctness or lower exec latency. |

Pinned implementation details are independently inspectable. `mm/mm_init.c:2428` defines allocation and free static keys from their compile defaults and registers the early boot parameters. `Documentation/filesystems/failfs.rst` describes the kernel-internal filesystem’s lookup semantics. `fs/binfmt_misc_bpf.c:459` registers the `binfmt_misc_ops` struct_ops type. Micropod’s [VM argument handling](../../../Sources/MicropodRuntime/SandboxVM.swift) and [OCI backend selection](../../../ci/runner/containerd.toml) identify the local integration points. The inspection did not execute any syscalls inside a guest or attach any BPF programs.

**Binary identity.** The stock raw Image contains a validated BTF block at byte offset 19,550,208, length 5,670,041, SHA-256 `8902c848bb997484d17005ccea010f548c73411fd85f6d64adc608a3e8f8c034`. Parsing its type records to their declared lengths produced 124,713 records. The following are BTF function IDs, qualified to this exact Image.

| Stock function | BTF type ID |
| --- | ---: |
| `__arm64_sys_fchroot` | 56208 |
| `early_init_on_alloc` | 78724 |
| `early_init_on_free` | 78725 |
| `failfs_get_root` | 80518 |
| `failfs_init` | 80521 |
| `load_misc_binary` | 91287 |

| Pinned source member | SHA-256 |
| --- | --- |
| `security/Kconfig.hardening` | `42b1300f0a4d01932a584dbc8e2ae31f6746c41a3f8a88dcaba841567edfa2fb` |
| `mm/mm_init.c` | `6e92c75c09fddae79d152dd156dbc938f386a95aacefaab2ce14ba0981ceac65` |
| `scripts/syscall.tbl` | `f09f4c97a0c72c7cc73cc17f21844dee062693ddce3d08f9213d80d6803f3b81` |
| `fs/Makefile` | `5e8462335c1749e142a7ee484cf4fbca9cc88ff4a6e3a3face705b885dbde074` |
| `fs/open.c` | `d77a31fcf5328bc79f5ca4884e81e38df49cb90ba422dbdd5c41ee0ca71fad5f` |
| `fs/failfs.c` | `9495c0740531f35a0e756db841bc063e93f2c7f10b15b2955743ccc1b4c0b373` |
| `fs/Kconfig.binfmt` | `94e922c13950645542c0a8e442a1aff83e0125907f204e0aff15842794e044ca` |
| `fs/binfmt_misc.c` | `3b02a588711092fd8c163f7d691a761a11fcd149c0e12ad56852022967a9410f` |
| `fs/binfmt_misc_bpf.c` | `d35351b91b4027191b5844174d12dee9261985aa61badba28d875fe54106c0df` |
