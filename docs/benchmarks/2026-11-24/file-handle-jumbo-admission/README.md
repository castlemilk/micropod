# File-handle attachment send-buffer floor at MTU 9000

For the alternate device in #229.03, qualify the actual sender buffer against a full link-layer frame before testing the SDK's recommended 4:1 receive/send ratio. On Gamma, a 9,013-byte send buffer rejected every 9,014-byte untagged jumbo frame with `EMSGSIZE`. With a 9,014-byte send buffer and the same 64 KiB receive buffer, seven complete frames arrived per direction before further sends returned `ENOBUFS`. This held in every block.

| Client send / receive | Attachment fd send / receive | MTU 1500, client → fd / fd → client | MTU 9000, client → fd / fd → client |
| --- | --- | ---: | ---: |
| 8 / 32 KiB | 8 / 32 KiB | 21 / 21 | 0 / 0 |
| 16 / 32 KiB | 16 / 32 KiB | 21 / 21 | 3 / 3 |
| 16 / 64 KiB | 16 / 32 KiB | 21 / 42 | 3 / 7 |
| 16 / 64 KiB | 16 / 64 KiB | 42 / 42 | 7 / 7 |
| Frame length minus one / 64 KiB | Same as client | 0 / 0 | 0 / 0 |
| Frame length / 64 KiB | Same as client | 42 / 42 | 7 / 7 |

Each value counts whole frames received out of 48 offered in that direction. The two MTUs used 1,514- and 9,014-byte datagrams respectively, including an untagged Ethernet header and a checksummed IPv4 header. When the sender buffer was too small, every offer returned `EMSGSIZE`. After the receiver filled, surplus offers returned `ENOBUFS`. Configuring 4:1 on the client improved only its incoming burst capacity. For a subsequent file-handle VM trial, 16 KiB send and 64 KiB receive covers these frames. Read back each configurable side and check guest delivery in both directions before scoring.

Each of four blocks randomized the twelve cases. A fresh anonymous connected Darwin datagram pair carried each case. The harness paused both readers and alternated sends between endpoints. The starting side alternated by block. An Objective-C helper kept a real `VZFileHandleNetworkDeviceAttachment` alive on the inherited descriptor, set the requested MTU and returned its descriptor and MTU readback. The harness verified both socket options, ordered byte equality and SHA-256 against successful sends, successful offer accounting, and a smaller recovery frame in each direction after draining. The 48 pairs delivered 3,494,104 bytes plus recovery frames. A second invocation reproduced the full receipt byte for byte.

The SDK 26.5 header specifies a connected datagram socket, link-layer frames and the client-side buffer recommendation. The tested reads and writes ran in the harness on macOS 26.5.1 arm64. This establishes local buffer admission while an attachment is configured. VM forwarding, active guest route MTU, VLAN-tagged frames and Micropod versus OrbStack throughput still require separate measurements. The stock vmnet path uses a different attachment. The earlier one-way control used 1,500-byte datagrams with a 16 KiB sender. [Earlier control](../file-handle-datagram-room.json)

Reproduce from this directory with `python3 -B probe.py`. It compiles the helper in a temporary directory and prints the JSON receipt. [Probe](probe.py) · [Attachment helper](attachment.m) · [All measurements and source hashes](measurement.json)
