**24 November 2026 · 233.03 · Checking whether netkit transmit bytes prove peer delivery**

Source/fixture, Micropod `7d9b565173a901cb18942e00384838da96e0ba98`, Linux 7.3.5 source tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Compiled the original netkit transmit function and redirect helper with a modeled egress program and device table. Changed only whether the redirect destination’s interface index resolved.

One deterministic pair of 32 × 1,514-byte frames per arm. Both arms returned transmit success 32/32, credited 48,448 bytes on the source and incremented its TX drop counter by zero. The destination fixture received 32/32 when present and 0/32 when absent. In the latter arm the kernel branch freed all 32 frames. The existing source-byte qualifier, supplied the same independent synthetic client receipt in both arms, accepted both. No physical loss, real client delivery, timed throughput, fresh p95/p99 or per-process costs were measured.

Source TX accounting alone cannot establish where benchmark data went. Before timing netkit, bind the attached program and peer identity to a destination-side observation of the tagged payload. Raw-verified local result `netkit-redirect.json`, SHA-256 `7e01509ee7cf6204ea200b73abc278c84dad1082a5ec07c444db632f332113bb`, replay `netkit_redirect.py` and `netkit_fixture.c`.
