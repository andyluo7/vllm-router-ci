# Operations runbook

## Initial host preparation

1. Apply the matching file under `netplan/` to each host and run
   `netplan generate` before applying it.
2. Install the Buildkite package on both hosts, but leave the worker service
   disabled.
3. Create the coordinator-to-worker SSH key at
   `/var/lib/buildkite-agent/.ssh/vllm_router_ci_ed25519`, install its public key
   for the worker's `buildkite-agent` account, and populate strict
   `known_hosts`. Never commit either generated file.
4. Populate the pinned ROCm Docker image and `Qwen/Qwen3-0.6B` model cache on
   both hosts.
5. Pin both hosts to the validated kernel with `kernel/pin-kernel.sh`, reboot,
   and run `kernel/verify-kernel.sh`.

## Coordinator readiness and activation

Stage and validate readiness without changing the agent service:

```bash
sudo ./buildkite/stage-coordinator-readiness.sh
```

Activate only after the queue exists and the agent-registration token is
available through a protected file:

```bash
sudo BUILDKITE_AGENT_TOKEN_FILE=/secure/path/agent-token \
  ./buildkite/install-coordinator-agent.sh
```

The installer validates the Docker plugin contract, installs the token-bearing
configuration with mode `0640`, enables the coordinator agent, and restarts it.

Keep the worker agent disabled:

```bash
sudo systemctl disable --now buildkite-agent
```

## Routine checks

On the coordinator:

```bash
systemctl show buildkite-agent \
  -p ActiveState -p SubState -p After -p Requires -p TimeoutStartUSec
journalctl -u buildkite-agent -n 100 --no-pager
sudo -u buildkite-agent -H /usr/local/sbin/vllm-router-rocm-wait-ready
```

On the worker:

```bash
systemctl is-enabled buildkite-agent
systemctl is-active buildkite-agent
```

The expected worker results are `disabled` and `inactive`.

## Reboot sequence

1. Drain or pause the coordinator Buildkite agent.
2. Reboot the worker first.
3. Verify its kernel, GPUs, HCAs, Docker, model cache, and rails.
4. Reboot the coordinator.
5. Confirm the coordinator boots the pinned kernel and that the readiness gate
   brings the agent online only after the worker is ready.
6. Trigger a trusted manual XGMI/RDMA build before returning the pair to normal
   service.

## Kernel and DKMS updates

The `6.8.0-137-generic` update caused an amdgpu/PeerDirect regression on this
cluster. Both hosts therefore boot the exact validated
`6.8.0-134-generic` GRUB entry.

Do not move the production pair to a new kernel merely because a DKMS update
completed. Validate the candidate kernel on a drained host, including amdgpu,
PeerDirect, all HCAs, GPU-memory RDMA, XGMI, and both live MoRI RDMA modes. Keep
the known-good kernel installed so rollback remains possible.
