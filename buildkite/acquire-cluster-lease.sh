#!/usr/bin/env bash

set -Eeuo pipefail

readonly HOLDER_PATH=/usr/local/sbin/vllm-router-rocm-hold-cluster-lease
readonly ACQUIRE_TIMEOUT_SECONDS=21600
readonly NOTICE_INTERVAL_SECONDS=60

find_bootstrap() {
  local pid=$PPID
  local command_line stat_line stat_tail
  local -a fields

  while (( pid > 1 )); do
    command_line=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
    if [[ ${command_line} == *buildkite-agent*bootstrap* ]]; then
      stat_line=$(<"/proc/${pid}/stat")
      stat_tail=${stat_line##*) }
      read -r -a fields <<<"${stat_tail}"
      [[ ${#fields[@]} -ge 20 ]] || return 1
      printf '%s %s\n' "${pid}" "${fields[19]}"
      return 0
    fi

    [[ -r /proc/${pid}/stat ]] || return 1
    stat_line=$(<"/proc/${pid}/stat")
    stat_tail=${stat_line##*) }
    read -r -a fields <<<"${stat_tail}"
    [[ ${#fields[@]} -ge 2 ]] || return 1
    pid=${fields[1]}
  done

  return 1
}

[[ -x ${HOLDER_PATH} ]] || {
  echo "ERROR: cluster lease holder is unavailable: ${HOLDER_PATH}" >&2
  exit 2
}

read -r owner_pid owner_starttime < <(find_bootstrap) || {
  echo "ERROR: could not identify this job's Buildkite bootstrap" >&2
  exit 1
}

ready_path=$(mktemp /tmp/vllm-router-rocm-lease.XXXXXX)
holder_pid=
lease_acquired=0
cleanup() {
  rm -f "${ready_path}" "${ready_path}.tmp."* 2>/dev/null || true
  if (( ! lease_acquired )) && [[ -n ${holder_pid} ]]; then
    kill "${holder_pid}" 2>/dev/null || true
    wait "${holder_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' TERM INT HUP

nohup "${HOLDER_PATH}" \
  "${owner_pid}" "${owner_starttime}" "${ready_path}" \
  </dev/null >/dev/null 2>&1 &
holder_pid=$!

deadline=$((SECONDS + ACQUIRE_TIMEOUT_SECONDS))
next_notice=$SECONDS
while (( SECONDS < deadline )); do
  if [[ -s ${ready_path} ]]; then
    status=$(<"${ready_path}")
    case "${status}" in
      acquired)
        lease_acquired=1
        echo "Acquired exclusive coordinator/worker AMD CI lease"
        exit 0
        ;;
      owner-gone)
        echo "ERROR: Buildkite bootstrap exited before the AMD CI lease was acquired" >&2
        exit 1
        ;;
      *)
        echo "ERROR: unexpected AMD CI lease status: ${status}" >&2
        exit 1
        ;;
    esac
  fi

  if ! kill -0 "${holder_pid}" 2>/dev/null; then
    wait "${holder_pid}" 2>/dev/null || true
    echo "ERROR: AMD CI cluster lease holder exited before acquisition" >&2
    exit 1
  fi

  if (( SECONDS >= next_notice )); then
    echo "Waiting for the shared MI300X hosts to become available"
    next_notice=$((SECONDS + NOTICE_INTERVAL_SECONDS))
  fi
  sleep 1
done

echo "ERROR: timed out waiting for the shared MI300X hosts" >&2
exit 1
