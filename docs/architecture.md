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

The coordinator service has two readiness gates:

1. A systemd `ExecStartPre` waits for `network-online.target`, Docker, all GPUs,
   all HCAs, SSH, model caches, and every jumbo-frame rail before the agent
   connects.
2. A global Buildkite `pre-command` hook repeats the same retrying check before
   every assigned job.

The readiness loop allows 600 seconds total, limits each attempt to 60 seconds,
and retries every 10 seconds. The Buildkite service startup timeout is 12
minutes.
