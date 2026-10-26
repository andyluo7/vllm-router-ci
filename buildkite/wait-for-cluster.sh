#!/usr/bin/env bash

set -Eeuo pipefail

# Keep these values fixed rather than accepting job-controlled environment
# overrides. This script runs after the global Buildkite hook has claimed both
# shared hosts for the assigned job.
readonly PREFLIGHT_PATH=/usr/local/sbin/vllm-router-rocm-preflight
readonly IMAGE_ENSURE_PATH=/usr/local/sbin/vllm-router-rocm-ensure-image
readonly READINESS_TIMEOUT_SECONDS=600
readonly PREFLIGHT_ATTEMPT_TIMEOUT_SECONDS=60
readonly RETRY_DELAY_SECONDS=10

if [[ ! -x "${IMAGE_ENSURE_PATH}" ]]; then
  echo "ERROR: pinned-image restorer is unavailable: ${IMAGE_ENSURE_PATH}" >&2
  exit 2
fi
if [[ ! -x "${PREFLIGHT_PATH}" ]]; then
  echo "ERROR: cluster preflight is unavailable: ${PREFLIGHT_PATH}" >&2
  exit 2
fi

# A missing digest cannot become ready through repeated image inspection. Pull
# the fixed reference on both hosts once, before entering the hardware retry
# loop. The helper serializes concurrent boot/per-job invocations.
"${IMAGE_ENSURE_PATH}"

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
