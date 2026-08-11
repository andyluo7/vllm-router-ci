#!/usr/bin/env bash

set -Eeuo pipefail

# Keep these values fixed rather than accepting job-controlled environment
# overrides. This script runs both as a systemd ExecStartPre command and as a
# global Buildkite hook on a dedicated agent.
readonly PREFLIGHT_PATH=/usr/local/sbin/vllm-router-rocm-preflight
readonly READINESS_TIMEOUT_SECONDS=600
readonly PREFLIGHT_ATTEMPT_TIMEOUT_SECONDS=60
readonly RETRY_DELAY_SECONDS=10

if [[ ! -x "${PREFLIGHT_PATH}" ]]; then
  echo "ERROR: cluster preflight is unavailable: ${PREFLIGHT_PATH}" >&2
  exit 2
fi

deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
attempt=1

while (( SECONDS < deadline )); do
  echo "MI300X cluster readiness attempt ${attempt}"
  if timeout --signal=TERM --kill-after=5s \
    "${PREFLIGHT_ATTEMPT_TIMEOUT_SECONDS}s" \
    "${PREFLIGHT_PATH}"; then
    echo "MI300X cluster is ready for Buildkite work"
    exit 0
  fi

  remaining=$((deadline - SECONDS))
  if (( remaining <= 0 )); then
    break
  fi

  sleep_seconds=${RETRY_DELAY_SECONDS}
  if (( remaining < sleep_seconds )); then
    sleep_seconds=${remaining}
  fi
  echo "Cluster is not ready; retrying in ${sleep_seconds}s" >&2
  sleep "${sleep_seconds}"
  ((attempt += 1))
done

echo "ERROR: MI300X cluster did not become ready within ${READINESS_TIMEOUT_SECONDS}s" >&2
exit 1
