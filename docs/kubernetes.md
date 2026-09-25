# Kubernetes on Micropod — the lightweight engine

Micropod can run a full Kubernetes cluster as **one micro-VM**: a k3s image
whose `server` command is the VM's workload — etcd, apiserver, kubelet, and
containerd inside a single ~550 MB guest. No second runtime daemon, no
nested docker-in-docker, no Desktop-grade VM underneath.

It's an **opt-in** feature:

```bash
micropod k8s enable          # writes ~/Library/Application Support/micropod/k8s.json
micropod k8s up              # create the VM, wait for API, write kubeconfig
micropod k8s status
micropod k8s down            # remove the VM (state goes with it)
micropod k8s kubeconfig      # print the kubeconfig path
```

CI can skip the toggle with `MICROPOD_K8S=1`.

## What you get

- **Real `kubectl` from the host** — the kubeconfig is rewritten to the VM's
  vmnet address (`https://192.168.64.x:6443`); the apiserver cert SANs already
  cover it, so `export KUBECONFIG=~/.micropod/k8s/kubeconfig` just works.
- **MetalLB on the VM subnet** — `--metallb` (default on) installs MetalLB
  v0.14.9 and hands it the subnet tail (`x.x.x.240–250`). `type: LoadBalancer`
  services get a real IP that the host routes natively — the thing kind on
  Docker Desktop can't do without a tunnel.
- **Ingress** — traefik stays installed (default) and serves on the node
  address; `--no-ingress` disables it. `--disable=servicelb` is always passed
  so MetalLB owns LoadBalancer type.
- **Zero idle daemons** — stop the VM and the cluster is gone; nothing else
  stays resident.

## How it works

The unlock is that Apple's container runtime boots each container as a
micro-VM with a real kernel — so `k3s server` can be the workload directly:

```bash
container run -d --name micropod-k3s -m 1G -c 2 \
  --cap-add ALL --read-only-path NONE --masked-path NONE \
  rancher/k3s server --disable=servicelb
```

`--cap-add ALL` plus clearing the runtime's default read-only/masked procfs
paths is required — kubelet writes `/proc/sys/kernel/panic` on boot and dies
without it. Pod networking, cgroup management, and nested containerd all work
because the VM owns its kernel.

## Measured on the same Mac

|                       | micropod k8s | kind (Docker Desktop) |
|-----------------------|--------------|-----------------------|
| create → node Ready   | **21 s** cold, 2.4 s resume | 53–70 s |
| memory in use         | **~550 MB** guest | ~760 MB container + Docker Desktop's ~1.2 GB VM |
| `LoadBalancer` svc    | real IP, curlable | `<pending>` without extra tooling |

Reproduce: `scripts/bench_k8s.sh`

## Configuration

`k8s.json` (edit or pass flags to `enable`/`up`):

```json
{
  "enabled": true,
  "image": "docker.io/rancher/k3s:v1.34.1-k3s1",
  "memory": "1G",
  "cpus": 2,
  "metalLB": true,
  "ingress": true,
  "lbPool": null,                  // default: <subnet>.240-.250
  "clusterName": "micropod-k3s"
}
```

Flags: `--image`, `--memory`/`-m`, `--cpus`/`-c`, `--metallb`/`--no-metallb`,
`--ingress`/`--no-ingress`, `--lb-pool a.b.c.d-e.f.g.h`, `--name`.

## Known caveats

- First MetalLB install pulls ~60 MB from quay.io inside the guest; cold
  egress can take several minutes (the installer retries a stalled pull once
  and then reports instead of failing the cluster).
- One VM = one node. Multi-node is not the design goal; this is the
  cheap-local-cluster story, not a cluster-autoscaler story.
- The VM is privileged (`--cap-add ALL`). It's still a VM boundary, but don't
  run hostile workloads expecting a hardened multi-tenant edge.
