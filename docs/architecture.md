# Architecture

```text
Buildkite queue: router_rocm_mi300_2
                 |
                 v
Coordinator / node A (8x MI300X, agent spawn=1)
  - runs same-host XGMI jobs on two GPUs
  - starts local RDMA-side containers
  - controls the worker through vllm-router-rocm-worker
                 |
          eight MTU-9000 RoCE rails
                 |
Worker / node B (8x MI300X, no active Buildkite agent)
  - runs remote RDMA-side containers
```

Only the coordinator accepts Buildkite work. This prevents two independent
agents from allocating the paired cluster concurrently and lets one job own
cross-node setup and cleanup.

The coordinator service waits only for network and Docker before connecting.
Hardware ownership and readiness are job-scoped because the two hosts are also
SMG GitHub Actions runners:

1. SMG's job-start hook claims the local host lock before cleanup or GPU use and
   retains it for the lifetime of that job's `Runner.Worker`.
2. Router's global Buildkite `pre-command` hook atomically claims both host
   locks for the lifetime of the Buildkite bootstrap.
3. After ownership is established, Router restores the exact image digest and
   validates the kernel and DKMS builds, loaded GPU/RDMA drivers, idle GPUs,
   all active HCAs, SSH, model caches, and every jumbo-frame rail.

The readiness loop allows 600 seconds total, limits each attempt to 60 seconds,
and retries every 10 seconds. Lease acquisition can wait up to six hours for a
long SMG job without letting either CI system touch the other's containers.
