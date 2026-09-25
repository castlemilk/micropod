# Kubernetes on Micropod — the lightweight engine

Micropod can run a full Kubernetes cluster as **one micro-VM**: a k3s image
whose `server` command is the VM's workload — etcd, apiserver, kubelet, and
containerd inside a single ~700 MB guest. No second runtime daemon, no
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
| pod create → Ready (cached, p50) | ~1.1 s | ~0.6 s |
| 5-pod burst → all Ready | 1.5–1.9 s | ~1.0 s |
| apiserver `kubectl get` (p50) | 41 ms | 39 ms |
| ingress → pod (p50) | ~20 ms via NodePort; ~3 ms via LB IP | not host-routable |
| `LoadBalancer` svc    | real IP, curlable | `<pending>` without extra tooling |
| memory in use         | **~700 MB** guest | ~760 MB container + Docker Desktop's ~1.2 GB VM |

kind launches pods ~2x faster (warm Docker VM sandbox path — extra vCPUs
don't move ours); everywhere else the vmnet path wins or ties.

E2E image → pod-Ready, 181MB image, all three engines (p50 of 2):

| engine | load | run→Ready | total |
|---|---|---|---|
| kind | 2.48s | 0.52s | 3.00s |
| **micropod k8s** | **2.23s** | 1.15s | **3.17s** |
| minikube (docker driver) | 8.24s | 0.43s | 8.67s |

kind stays marginally quicker on pod start; micropod is at parity on the
load path and needs no Docker Desktop underneath. On a 13.6MB image the
shape holds (1.2s / 1.7s / 5.6s).

Reproduce: `scripts/bench_k8s.sh` (lifecycle), `scripts/bench_k8s_perf.sh`
(pod launch / apiserver / ingress / footprint / load),
`scripts/bench_k8s_e2e.sh` (image → pod Ready, all engines).

## Loading images

Workload `image:` references pull through the guest's vmnet NAT, which is
slow (minutes for ~20 MB). `k8s load` bypasses it entirely — the host puller
fetches (or the local image store supplies) and the archive is injected
straight into the cluster's containerd:

```bash
micropod build -t myapp:dev .            # any Micropod-built or pulled image
micropod k8s load myapp:dev              # local store → guest, no network
micropod k8s load redis:alpine           # host pull → guest, on a miss
micropod k8s load ./myapp.tar            # `container image save`/`docker save` tarball
micropod k8s images                      # what's in the cluster's containerd
```

Source resolution for a ref: Micropod's store → a **local Docker daemon's
store** (Docker Desktop, colima, Lima — probed via `DOCKER_HOST`,
`~/.docker/run/docker.sock`, `~/.colima/default/docker.sock`, lima
instance sockets, `/var/run/docker.sock`; fetched with
`GET /images/{ref}/get` — `docker save` over the socket, no copy through a
registry) → the host puller as the last resort. An image that exists in
Docker Desktop transfers at disk speed; one that exists nowhere pulls once
on the host.

Then reference the ref normally — `image: myapp:dev` with
`imagePullPolicy: IfNotPresent` (or `Never`) and the pod starts in ~1s with
no pull at all.

The pipeline streams: the archive is piped into the guest's containerd over
exec stdin (`ctr images import -`) — no `container copy`, no guest-side
tar. Measured on a 273MB image: save 0.6s + streamed import 1.6s ≈ **2.8s
end-to-end** (was ~11.5s via copy+import-file). A 4MB dev-loop image loads
in ~0.5s. Progress lines report per-stage timings. The same ops exist on every surface:
`LoadK8sImage`/`ListK8sImages` on Connect (`archive` accepts tarball bytes —
base64 in Connect JSON), `GET|POST /v1/k8s/images` on REST, and
`k8s_load_image`/`k8s_images` MCP tools.

### Docker-API clients

The image store is shared with the Docker Engine shim, so stock `docker`
commands compose with the cluster: `docker build -t app:dev .` lands in the
store `k8s load` reads (no network hop), `docker save`/`docker load` work on
the shim socket (`GET /images/get`, `POST /images/load`), `docker push`
forwards to `container image push`, and `docker top` lists in-container
processes. For API callers, `?k8s=1` on `POST /images/load` or `POST /build`
injects the result into the cluster's containerd in the same request —
`build → cluster` is one call:

```bash
curl --unix-socket ~/.micropod/docker.sock -X POST \
  "http://localhost/build?t=myapp:dev&k8s=1" -T context.tar
```

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

- Workload `image:` references still pull through the guest's vmnet NAT,
  which is slow (minutes for ~20 MB). MetalLB's own images are seeded by the
  host puller (`image save` → `copy` → `ctr import`) so add-on install is
  fast; workload seeding is the obvious next step.
- One VM = one node. Multi-node is not the design goal; this is the
  cheap-local-cluster story, not a cluster-autoscaler story.
- The VM is privileged (`--cap-add ALL`). It's still a VM boundary, but don't
  run hostile workloads expecting a hardened multi-tenant edge.
