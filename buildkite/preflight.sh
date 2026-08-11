#!/usr/bin/env bash

set -Eeuo pipefail

# This is a privileged, dedicated agent. Keep the preflight targets fixed so a
# Buildkite job cannot redirect its SSH or filesystem checks with environment
# variables before the global pre-command hook runs.
readonly WORKER_SSH_HOST=vllm-router-rocm-worker
readonly ROCM_VLLM_IMAGE=vllm/vllm-openai-rocm:nightly@sha256:d22922d540810d90c5a3eafe91d3b4a62c2b881f3e990d0b7180b2875a5d176d
readonly HF_CACHE_DIR=/var/lib/buildkite-agent/.cache/huggingface
readonly BUILDS_PATH=/var/lib/buildkite-agent/builds
readonly PLUGINS_PATH=/var/lib/buildkite-agent/plugins

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

gpu_count() {
  rocm-smi -l 2>/dev/null | grep -c '^GPU\['
}

rdma_count() {
  ibv_devices 2>/dev/null | awk '$1 ~ /^mlx5_[0-7]$/ { count++ } END { print count + 0 }'
}

[[ $(gpu_count) -eq 8 ]] || fail "coordinator does not expose eight GPUs"
[[ $(rdma_count) -eq 8 ]] || fail "coordinator does not expose eight mlx5 HCAs"
docker info >/dev/null
docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null
[[ -d "${HF_CACHE_DIR}/hub/models--Qwen--Qwen3-0.6B" ]] || fail "coordinator model cache is missing"

ssh -o BatchMode=yes "${WORKER_SSH_HOST}" true
[[ $(ssh "${WORKER_SSH_HOST}" rocm-smi -l 2>/dev/null | grep -c '^GPU\[') -eq 8 ]] \
  || fail "worker does not expose eight GPUs"
[[ $(ssh "${WORKER_SSH_HOST}" ibv_devices 2>/dev/null | awk '$1 ~ /^mlx5_[0-7]$/ { count++ } END { print count + 0 }') -eq 8 ]] \
  || fail "worker does not expose eight mlx5 HCAs"
ssh "${WORKER_SSH_HOST}" docker info >/dev/null
ssh "${WORKER_SSH_HOST}" docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null
ssh "${WORKER_SSH_HOST}" test -d "${HF_CACHE_DIR}/hub/models--Qwen--Qwen3-0.6B"

for writable_path in "${BUILDS_PATH}" "${PLUGINS_PATH}"; do
  [[ -d ${writable_path} && -w ${writable_path} ]] \
    || fail "Buildkite path is not writable: ${writable_path}"
done

for rail in {0..7}; do
  interface="eth$((rail + 2))"
  coordinator_address="192.168.200.$((rail * 4 + 1))/30"
  worker_address="192.168.200.$((rail * 4 + 2))/30"
  worker_ip=${worker_address%/30}

  ip -4 -o address show dev "${interface}" | grep -qw "${coordinator_address}" \
    || fail "coordinator ${interface} is missing ${coordinator_address}"
  [[ $(<"/sys/class/net/${interface}/mtu") -eq 9000 ]] \
    || fail "coordinator ${interface} does not use MTU 9000"
  [[ $(<"/sys/class/net/${interface}/operstate") == up ]] \
    || fail "coordinator ${interface} is not up"

  ssh "${WORKER_SSH_HOST}" ip -4 -o address show dev "${interface}" \
    | grep -qw "${worker_address}" \
    || fail "worker ${interface} is missing ${worker_address}"
  [[ $(ssh "${WORKER_SSH_HOST}" cat "/sys/class/net/${interface}/mtu") -eq 9000 ]] \
    || fail "worker ${interface} does not use MTU 9000"
  [[ $(ssh "${WORKER_SSH_HOST}" cat "/sys/class/net/${interface}/operstate") == up ]] \
    || fail "worker ${interface} is not up"

  ping -c 1 -W 2 -M do -s 8972 "${worker_ip}" >/dev/null \
    || fail "jumbo-frame fabric check failed for ${worker_ip}"
done

echo "MI300X coordinator/worker preflight passed: 8 GPUs, 8 HCAs, Docker image, model cache, SSH, and jumbo RoCE rails"
