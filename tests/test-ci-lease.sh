#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOST_HOLDER=${ROOT_DIR}/shared/hold-host-lease.sh
REMOTE_HOLDER=${ROOT_DIR}/shared/hold-remote-lease.sh
TEST_DIR=$(mktemp -d)
trap 'jobs -pr | xargs -r kill 2>/dev/null || true; rm -rf "${TEST_DIR}"' EXIT

proc_starttime() {
  local pid=$1
  local stat_line stat_tail
  local -a fields

  stat_line=$(<"/proc/${pid}/stat")
  stat_tail=${stat_line##*) }
  read -r -a fields <<<"${stat_tail}"
  printf '%s\n' "${fields[19]}"
}

wait_status() {
  local path=$1
  local expected=$2
  local deadline=$((SECONDS + 10))

  while (( SECONDS < deadline )); do
    if [[ -s ${path} && $(<"${path}") == "${expected}" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "ERROR: expected ${expected} in ${path}" >&2
  return 1
}

lock_path=${TEST_DIR}/host.lock
owner_one_ready=${TEST_DIR}/owner-one.ready
sleep 60 &
owner_one=$!
owner_one_start=$(proc_starttime "${owner_one}")
"${HOST_HOLDER}" --lock-path "${lock_path}" \
  "${owner_one}" "${owner_one_start}" "${owner_one_ready}" 2 &
holder_one=$!
wait_status "${owner_one_ready}" acquired

owner_two_ready=${TEST_DIR}/owner-two.ready
sleep 60 &
owner_two=$!
owner_two_start=$(proc_starttime "${owner_two}")
set +e
"${HOST_HOLDER}" --lock-path "${lock_path}" \
  "${owner_two}" "${owner_two_start}" "${owner_two_ready}" 1
busy_status=$?
set -e
[[ ${busy_status} -eq 75 ]]
wait_status "${owner_two_ready}" busy

kill "${owner_one}"
wait "${owner_one}" 2>/dev/null || true
wait "${holder_one}"

owner_three_ready=${TEST_DIR}/owner-three.ready
sleep 60 &
owner_three=$!
owner_three_start=$(proc_starttime "${owner_three}")
"${HOST_HOLDER}" --lock-path "${lock_path}" \
  "${owner_three}" "${owner_three_start}" "${owner_three_ready}" 2 &
holder_three=$!
wait_status "${owner_three_ready}" acquired
kill "${owner_three}"
wait "${owner_three}" 2>/dev/null || true
wait "${holder_three}"

remote_lock=${TEST_DIR}/remote.lock
coproc REMOTE_TEST { "${REMOTE_HOLDER}" --lock-path "${remote_lock}"; }
remote_read_fd=${REMOTE_TEST[0]}
remote_write_fd=${REMOTE_TEST[1]}
remote_pid=${REMOTE_TEST_PID}
IFS= read -r -t 5 -u "${remote_read_fd}" remote_status
[[ ${remote_status} == acquired ]]
if flock -n "${remote_lock}" true; then
  echo "ERROR: remote holder did not retain its lock" >&2
  exit 1
fi
eval "exec ${remote_write_fd}>&-"
wait "${remote_pid}"
flock -n "${remote_lock}" true

kill "${owner_two}"
wait "${owner_two}" 2>/dev/null || true

echo "Shared AMD CI lease tests passed"
