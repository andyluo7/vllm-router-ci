#!/usr/bin/env bash

set -Eeuo pipefail

# Keep the image and worker fixed: this script runs before job-controlled
# environment variables may be trusted on the dedicated coordinator.
readonly WORKER_SSH_HOST=vllm-router-rocm-worker
readonly ROCM_VLLM_IMAGE=vllm/vllm-openai-rocm:nightly@sha256:d22922d540810d90c5a3eafe91d3b4a62c2b881f3e990d0b7180b2875a5d176d
readonly LOCK_PATH=/var/lib/buildkite-agent/.vllm-router-rocm-image.lock
readonly LOCK_TIMEOUT_SECONDS=60
readonly PULL_TIMEOUT_SECONDS=3300

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for command_name in docker flock ssh timeout; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required command is unavailable: ${command_name}"
done

exec 9>"${LOCK_PATH}"
flock -w "${LOCK_TIMEOUT_SECONDS}" 9 \
  || fail "timed out waiting for pinned-image lock: ${LOCK_PATH}"

ensure_coordinator_image() {
  if docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null 2>&1; then
    echo "Pinned ROCm image is present on coordinator"
    return 0
  fi

  echo "Pinned ROCm image is missing on coordinator; pulling exact digest"
  timeout --signal=TERM --kill-after=30s \
    "${PULL_TIMEOUT_SECONDS}s" \
    docker pull "${ROCM_VLLM_IMAGE}"
  docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null
  echo "Pinned ROCm image restored on coordinator"
}

ensure_worker_image() {
  if ssh -o BatchMode=yes "${WORKER_SSH_HOST}" \
    docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null 2>&1; then
    echo "Pinned ROCm image is present on worker"
    return 0
  fi

  echo "Pinned ROCm image is missing on worker; pulling exact digest"
  timeout --signal=TERM --kill-after=30s \
    "${PULL_TIMEOUT_SECONDS}s" \
    ssh -o BatchMode=yes "${WORKER_SSH_HOST}" \
      docker pull "${ROCM_VLLM_IMAGE}"
  ssh -o BatchMode=yes "${WORKER_SSH_HOST}" \
    docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null
  echo "Pinned ROCm image restored on worker"
}

ensure_coordinator_image &
coordinator_pid=$!
ensure_worker_image &
worker_pid=$!

cleanup() {
  local pid
  for pid in "${coordinator_pid}" "${worker_pid}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
    fi
  done
  wait "${coordinator_pid}" 2>/dev/null || true
  wait "${worker_pid}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

set +e
wait "${coordinator_pid}"
coordinator_status=$?
wait "${worker_pid}"
worker_status=$?
set -e
trap - EXIT INT TERM

(( coordinator_status == 0 )) \
  || fail "failed to restore pinned ROCm image on coordinator"
(( worker_status == 0 )) \
  || fail "failed to restore pinned ROCm image on worker"

echo "Pinned ROCm image is ready on coordinator and worker"
