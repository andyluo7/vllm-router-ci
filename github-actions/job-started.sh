#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED for SMG's shared AMD runners.

set -Eeuo pipefail

readonly HOLDER_PATH=/usr/local/sbin/amd-ci-hold-host-lease
readonly ACQUIRE_TIMEOUT_SECONDS=21600
readonly NOTICE_INTERVAL_SECONDS=60
readonly GPU_IDLE_TIMEOUT_SECONDS=120
readonly RUNNER_ROOT=/opt/actions-runner/smg

find_runner_worker() {
  local pid=$PPID
  local command_line stat_line stat_tail
  local -a fields

  while (( pid > 1 )); do
    command_line=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
    if [[ ${command_line} == *Runner.Worker* ]]; then
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
  echo "::error::shared AMD CI lease holder is unavailable: ${HOLDER_PATH}"
  exit 1
}

read -r owner_pid owner_starttime < <(find_runner_worker) || {
  echo "::error::could not identify this job's Runner.Worker process"
  exit 1
}

ready_path=$(mktemp /tmp/smg-amd-ci-lease.XXXXXX)
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
  "${ACQUIRE_TIMEOUT_SECONDS}" </dev/null >/dev/null 2>&1 &
holder_pid=$!

deadline=$((SECONDS + ACQUIRE_TIMEOUT_SECONDS + 30))
next_notice=$SECONDS
while (( SECONDS < deadline )); do
  if [[ -s ${ready_path} ]]; then
    status=$(<"${ready_path}")
    case "${status}" in
      acquired)
        lease_acquired=1
        echo "Acquired exclusive AMD CI lease for $(hostname)"
        break
        ;;
      busy)
        echo "::error::timed out waiting for the shared AMD CI lease"
        exit 1
        ;;
      owner-gone)
        echo "::error::Runner.Worker exited before the shared AMD CI lease was acquired"
        exit 1
        ;;
      *)
        echo "::error::unexpected shared AMD CI lease status: ${status}"
        exit 1
        ;;
    esac
  fi

  if ! kill -0 "${holder_pid}" 2>/dev/null; then
    wait "${holder_pid}" 2>/dev/null || true
    echo "::error::shared AMD CI lease holder exited before acquisition"
    exit 1
  fi

  if (( SECONDS >= next_notice )); then
    echo "Waiting for another CI owner to release $(hostname)'s GPUs"
    next_notice=$((SECONDS + NOTICE_INTERVAL_SECONDS))
  fi
  sleep 1
done

(( lease_acquired )) || {
  echo "::error::timed out waiting for the shared AMD CI lease"
  exit 1
}

# Only remove containers mounted from this runner's own work directory. The old
# hook removed every container on the host, which could terminate Router CI or
# an operator workload that happened to overlap.
runner_work_root=$(readlink -f "${RUNNER_ROOT}/_work")
mapfile -t running_containers < <(docker ps -q)
smg_leftovers=()
for container_id in "${running_containers[@]}"; do
  work_source=$(docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/__w"}}{{.Source}}{{end}}{{end}}' \
    "${container_id}" 2>/dev/null || true)
  if [[ ${work_source} == "${runner_work_root}" ]]; then
    smg_leftovers+=("${container_id}")
  fi
done

if (( ${#smg_leftovers[@]} > 0 )); then
  echo "Removing containers left by an earlier SMG job:"
  for container_id in "${smg_leftovers[@]}"; do
    docker ps --filter "id=${container_id}" \
      --format '  {{.Names}} ({{.Image}}, {{.Status}})'
  done
  docker rm -f "${smg_leftovers[@]}" >/dev/null
fi

gpu_deadline=$((SECONDS + GPU_IDLE_TIMEOUT_SECONDS))
while true; do
  memory_csv=$(rocm-smi --showmemuse --csv 2>/dev/null)
  busy_gpus=$(printf '%s\n' "${memory_csv}" | awk -F, '
    $1 ~ /^card[0-7]$/ {
      gsub(/[[:space:]]/, "", $2)
      if (($2 + 0) > 5) {
        printf "%s=%s%% ", $1, $2
      }
    }
  ')
  if [[ -z ${busy_gpus} ]]; then
    break
  fi
  if (( SECONDS >= gpu_deadline )); then
    echo "::error::GPUs are already occupied after SMG cleanup: ${busy_gpus}"
    exit 1
  fi
  echo "Waiting for prior GPU allocations to drain: ${busy_gpus}"
  sleep 5
done
printf '%s\n' "${memory_csv}" | sed 's/^/gpu: /'

docker_gb=$(df --output=avail -BG /var/lib/docker | tail -n 1 | tr -dc 0-9)
models_gb=$(df --output=avail -BG /models | tail -n 1 | tr -dc 0-9)
echo "disk: ${docker_gb} GB free for Docker, ${models_gb} GB free for /models"
if (( docker_gb < 150 || models_gb < 300 )); then
  echo "::error::not enough free disk on this runner (Docker needs 150 GB, /models 300 GB)"
  exit 1
fi
