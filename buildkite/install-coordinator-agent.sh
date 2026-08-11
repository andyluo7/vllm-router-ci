#!/usr/bin/env bash

set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "ERROR: run this installer as root on the coordinator" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_TEMPLATE="${SCRIPT_DIR}/coordinator-agent.cfg"
READINESS_STAGER_SOURCE="${SCRIPT_DIR}/stage-coordinator-readiness.sh"
PLUGIN_VALIDATOR_SOURCE="${SCRIPT_DIR}/validate-docker-plugin.sh"
CONFIG_PATH=${BUILDKITE_AGENT_CONFIG:-/etc/buildkite-agent/buildkite-agent.cfg}
PLUGIN_VALIDATOR_PATH=${VLLM_ROUTER_PLUGIN_VALIDATOR_PATH:-/usr/local/sbin/vllm-router-rocm-validate-docker-plugin}

token=${BUILDKITE_AGENT_TOKEN:-}
if [[ -n "${BUILDKITE_AGENT_TOKEN_FILE:-}" ]]; then
  token=$(<"${BUILDKITE_AGENT_TOKEN_FILE}")
elif [[ -z "${token}" && ! -t 0 ]]; then
  IFS= read -r token || true
fi

if ! [[ "${token}" =~ ^bkct_[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: supply a real token through BUILDKITE_AGENT_TOKEN, BUILDKITE_AGENT_TOKEN_FILE, or stdin" >&2
  exit 2
fi

if [[ ! -f "${CONFIG_TEMPLATE}" ]]; then
  echo "ERROR: missing config template: ${CONFIG_TEMPLATE}" >&2
  exit 2
fi
if [[ ! -f "${READINESS_STAGER_SOURCE}" ]]; then
  echo "ERROR: missing readiness stager: ${READINESS_STAGER_SOURCE}" >&2
  exit 2
fi
if [[ ! -f "${PLUGIN_VALIDATOR_SOURCE}" ]]; then
  echo "ERROR: missing Docker plugin validator: ${PLUGIN_VALIDATOR_SOURCE}" >&2
  exit 2
fi

umask 077
tmp_config=$(mktemp /tmp/vllm-router-buildkite-agent.XXXXXX)
cleanup() {
  rm -f "${tmp_config}"
}
trap cleanup EXIT

{
  printf 'token="%s"\n' "${token}"
  tail -n +2 "${CONFIG_TEMPLATE}"
} >"${tmp_config}"

bash "${READINESS_STAGER_SOURCE}"
install -o root -g root -m 0755 \
  "${PLUGIN_VALIDATOR_SOURCE}" "${PLUGIN_VALIDATOR_PATH}"
sudo -H -u buildkite-agent "${PLUGIN_VALIDATOR_PATH}"
install -o root -g buildkite-agent -m 0640 "${tmp_config}" "${CONFIG_PATH}"
systemctl enable buildkite-agent
systemctl restart buildkite-agent
systemctl is-active --quiet buildkite-agent

echo "Buildkite coordinator agent is active with queue router_rocm_mi300_2 and spawn=1"
