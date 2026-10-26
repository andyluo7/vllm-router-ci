#!/usr/bin/env bash

set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "ERROR: run this staging script as root on each shared MI300X host" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly RUNNER_ROOT=/opt/actions-runner/smg
readonly RUNNER_ENV=${RUNNER_ROOT}/.env
readonly HOOK_DIR=/opt/actions-runner/hooks
readonly LOCK_PATH=/run/lock/amd-ci-gpu.lock
readonly TMPFILES_PATH=/etc/tmpfiles.d/amd-ci-gpu-lock.conf

for source_path in \
  "${SCRIPT_DIR}/hold-host-lease.sh" \
  "${SCRIPT_DIR}/hold-remote-lease.sh" \
  "${ROOT_DIR}/github-actions/job-started.sh" \
  "${ROOT_DIR}/github-actions/job-completed.sh"; do
  [[ -f ${source_path} ]] || {
    echo "ERROR: missing shared-host source: ${source_path}" >&2
    exit 2
  }
done

id ghrunner >/dev/null 2>&1 || {
  echo "ERROR: ghrunner user is unavailable" >&2
  exit 2
}
[[ -f ${RUNNER_ENV} ]] || {
  echo "ERROR: SMG runner environment is unavailable: ${RUNNER_ENV}" >&2
  exit 2
}

install -d -o root -g root -m 0755 "${HOOK_DIR}"
install -o root -g root -m 0755 \
  "${SCRIPT_DIR}/hold-host-lease.sh" /usr/local/sbin/amd-ci-hold-host-lease
install -o root -g root -m 0755 \
  "${SCRIPT_DIR}/hold-remote-lease.sh" /usr/local/sbin/amd-ci-hold-remote-lease
install -o root -g root -m 0755 \
  "${ROOT_DIR}/github-actions/job-started.sh" "${HOOK_DIR}/job-started.sh"
install -o root -g root -m 0755 \
  "${ROOT_DIR}/github-actions/job-completed.sh" "${HOOK_DIR}/job-completed.sh"

touch "${LOCK_PATH}"
chown root:root "${LOCK_PATH}"
chmod 0666 "${LOCK_PATH}"
printf 'f %s 0666 root root -\n' "${LOCK_PATH}" >"${TMPFILES_PATH}"
chmod 0644 "${TMPFILES_PATH}"

set_runner_env() {
  local key=$1
  local value=$2
  local temporary_path

  temporary_path=$(mktemp "${RUNNER_ENV}.XXXXXX")
  awk -F= -v key="${key}" '$1 != key { print }' "${RUNNER_ENV}" >"${temporary_path}"
  printf '%s=%s\n' "${key}" "${value}" >>"${temporary_path}"
  chown --reference="${RUNNER_ENV}" "${temporary_path}"
  chmod --reference="${RUNNER_ENV}" "${temporary_path}"
  mv -f "${temporary_path}" "${RUNNER_ENV}"
}

set_runner_env ACTIONS_RUNNER_HOOK_JOB_STARTED "${HOOK_DIR}/job-started.sh"
set_runner_env ACTIONS_RUNNER_HOOK_JOB_COMPLETED "${HOOK_DIR}/job-completed.sh"

echo "Shared AMD CI coordination staged; the running SMG service was not restarted"
