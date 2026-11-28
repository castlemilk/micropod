package main

import "strconv"

// A pod's sandbox cgroup gets a working CPU weight.
//
// CRI gives every sandbox the minimum CPU shares, 2: cgroup v2 weight 1.
// crun's init sets the pod up inside that cgroup (namespaces, mounts, the
// pause exec), so RunPodSandbox waits for the CPU at weight 1 against every
// CPU-bound container at 100, and at 10000 while they are in their start
// boost (docker_start_boost_linux.go). With 32 busy loops started at once on
// 16 vCPUs, the next `docker run` spent 4.7-22.9 s in RunPodSandbox in 9 of 9
// runs with the boost and at most 1.8 s without it; the engine's goroutine
// waited in CRI's RunPodSandbox the whole time, and every pause cgroup read
// weight 1.
//
// So a crun pod names its sandbox's shares (the annotation below, which
// containerd as the runner bundle builds it turns into the sandbox's CPU
// shares: ci/patches/containerd/0003-sandbox-cpu-shares.patch): the kernel's
// default weight, or the boost's on a machine that turned the boost on. Only the pause
// process lives in that cgroup, and it sleeps once it has started, so the
// weight only decides how soon a pod is set up. A containerd without the
// patch ignores the annotation. An untrusted Kata job's pod carries none.
const sandboxCPUSharesAnnotation = "io.micropod.sandbox.cpu-shares"

// defaultWeightShares is the CPU shares crun maps to the kernel's default
// weight, 100. crun 1.23 and later convert shares to a weight with
// 10^((l*l + 125*l)/612 - 7/34), l = log2(shares), which takes 1024 to 100
// and 262144 to 10000 (2598, the linear formula's 100, read 210 on the
// bundle's crun 1.31).
const defaultWeightShares = 1024

// sandboxCPUShares is the shares a crun pod's sandbox asks for.
func sandboxCPUShares(boost bool) uint64 {
	if boost {
		return startBoostShares
	}
	return defaultWeightShares
}

// withSandboxCPUShares adds the annotation to a pod's annotations.
func withSandboxCPUShares(annotations map[string]string, boost bool) map[string]string {
	if annotations == nil {
		annotations = map[string]string{}
	}
	annotations[sandboxCPUSharesAnnotation] = strconv.FormatUint(sandboxCPUShares(boost), 10)
	return annotations
}
