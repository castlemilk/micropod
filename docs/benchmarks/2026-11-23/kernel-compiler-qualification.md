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
