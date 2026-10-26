#!/usr/bin/env bash

set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "ERROR: run this staging script as root on the coordinator" >&2
  exit 2
fi

run_readiness=1
if [[ ${1:-} == --defer-readiness ]]; then
  run_readiness=0
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0 [--defer-readiness]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_SOURCE="${SCRIPT_DIR}/preflight.sh"
IMAGE_ENSURE_SOURCE="${SCRIPT_DIR}/ensure-pinned-image.sh"
READINESS_SOURCE="${SCRIPT_DIR}/wait-for-cluster.sh"
LEASE_HOLDER_SOURCE="${SCRIPT_DIR}/hold-cluster-lease.sh"
LEASE_ACQUIRE_SOURCE="${SCRIPT_DIR}/acquire-cluster-lease.sh"
PRE_COMMAND_HOOK_SOURCE="${SCRIPT_DIR}/pre-command"
SYSTEMD_DROP_IN_SOURCE="${SCRIPT_DIR}/vllm-router-rocm-readiness.conf"
SSH_CONFIG_SOURCE="${SCRIPT_DIR}/coordinator-ssh-config"

PREFLIGHT_PATH=/usr/local/sbin/vllm-router-rocm-preflight
IMAGE_ENSURE_PATH=/usr/local/sbin/vllm-router-rocm-ensure-image
IMAGE_LOCK_PATH=/var/lib/buildkite-agent/.vllm-router-rocm-image.lock
READINESS_PATH=/usr/local/sbin/vllm-router-rocm-wait-ready
LEASE_HOLDER_PATH=/usr/local/sbin/vllm-router-rocm-hold-cluster-lease
LEASE_ACQUIRE_PATH=/usr/local/sbin/vllm-router-rocm-acquire-cluster-lease
PRE_COMMAND_HOOK_PATH=/etc/buildkite-agent/hooks/pre-command
SYSTEMD_DROP_IN_PATH=/etc/systemd/system/buildkite-agent.service.d/vllm-router-rocm-readiness.conf
SSH_CONFIG_PATH=/var/lib/buildkite-agent/.ssh/config

for source_path in \
  "${PREFLIGHT_SOURCE}" \
  "${IMAGE_ENSURE_SOURCE}" \
  "${READINESS_SOURCE}" \
  "${LEASE_HOLDER_SOURCE}" \
  "${LEASE_ACQUIRE_SOURCE}" \
  "${PRE_COMMAND_HOOK_SOURCE}" \
  "${SYSTEMD_DROP_IN_SOURCE}" \
  "${SSH_CONFIG_SOURCE}"; do
  if [[ ! -f "${source_path}" ]]; then
    echo "ERROR: missing coordinator readiness source: ${source_path}" >&2
    exit 2
  fi
done

if ! id buildkite-agent >/dev/null 2>&1; then
  echo "ERROR: buildkite-agent user is unavailable" >&2
  exit 2
fi

install -d -o buildkite-agent -g buildkite-agent -m 0700 \
  /var/lib/buildkite-agent/.ssh
install -d -o buildkite-agent -g buildkite-agent -m 0755 \
  /var/lib/buildkite-agent/builds \
  /var/lib/buildkite-agent/plugins
install -o buildkite-agent -g buildkite-agent -m 0600 \
  /dev/null "${IMAGE_LOCK_PATH}"
install -d -o root -g root -m 0755 \
  /etc/buildkite-agent/hooks \
  /etc/systemd/system/buildkite-agent.service.d

install -o buildkite-agent -g buildkite-agent -m 0600 \
  "${SSH_CONFIG_SOURCE}" "${SSH_CONFIG_PATH}"
install -o root -g root -m 0755 \
  "${PREFLIGHT_SOURCE}" "${PREFLIGHT_PATH}"
install -o root -g root -m 0755 \
  "${IMAGE_ENSURE_SOURCE}" "${IMAGE_ENSURE_PATH}"
install -o root -g root -m 0755 \
  "${READINESS_SOURCE}" "${READINESS_PATH}"
install -o root -g root -m 0755 \
  "${LEASE_HOLDER_SOURCE}" "${LEASE_HOLDER_PATH}"
install -o root -g root -m 0755 \
  "${LEASE_ACQUIRE_SOURCE}" "${LEASE_ACQUIRE_PATH}"
install -o root -g root -m 0755 \
  "${PRE_COMMAND_HOOK_SOURCE}" "${PRE_COMMAND_HOOK_PATH}"
install -o root -g root -m 0644 \
  "${SYSTEMD_DROP_IN_SOURCE}" "${SYSTEMD_DROP_IN_PATH}"

systemctl daemon-reload
if (( run_readiness )); then
  sudo -H -u buildkite-agent "${READINESS_PATH}"
else
  echo "Readiness validation deferred because another CI owner is using the hosts"
fi

echo "Buildkite per-job readiness gate is staged; the agent service state was not changed"
