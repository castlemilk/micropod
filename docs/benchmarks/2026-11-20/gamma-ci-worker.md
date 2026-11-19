# The warm CI worker on Gamma

The physical 18-core Apple M5 Max ran both Micropod and OrbStack with four vCPUs and 4 GiB per Linux engine. Each timed batch used the public Micropod CI command or the stock Docker client for OrbStack. The table gives median seconds for the complete batch over five alternating rounds. The npm and Go rows use offline lockfiles in fresh containers. [Raw Mac samples](gamma-worker-orbstack.json)

| Runtime and workload | 1 job | 4 jobs | 8 jobs | 16 jobs |
| --- | ---: | ---: | ---: | ---: |
| micropod-worker | 0.104 | 0.160 | 0.322 | 0.661 |
| orbstack | 1.795 | 4.990 | 14.802 | 30.408 |
| micropod-worker · npm | 0.557 | 0.586 | 1.153 | 2.033 |
| micropod-worker · go | 0.358 | 0.499 | 1.080 | 1.817 |
| orbstack · npm | 1.330 | 6.048 | 10.945 | 20.311 |
| orbstack · go | 0.819 | 7.271 | 10.797 | 16.016 |

The complete Go, Node and PostgreSQL pipeline took a median 13.02 s on Micropod and 21.66 s on OrbStack over three warm passes. Sixteen concurrent starts joined one Linux kernel. The same package files and Docker identity survived both clean restart and forced supervisor exit. [Application pipeline](gamma-worker-pipelines.json) · [Startup and cache checks](gamma-worker-recovery.json)

Two independent native ARM Ubuntu allocations completed 16 warm Alpine launches in 0.590 s and 0.599 s. Gamma took 0.661 s on Micropod. These are client-clock container measurements from different physical hardware. [First Ubuntu run](../2026-11-19/live-kernel-arm64.json) · [Independent Ubuntu run](../2026-11-19/live-kernel-arm64-repeat.json)
