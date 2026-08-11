#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $(id -un) != buildkite-agent ]]; then
  echo "ERROR: run this validator as buildkite-agent" >&2
  exit 2
fi

CHECKOUT_PATH=${CHECKOUT_PATH:-/var/lib/buildkite-agent/work/vllm-router-rocm-ci}
ROCM_VLLM_IMAGE=${ROCM_VLLM_IMAGE:-vllm/vllm-openai-rocm:nightly@sha256:d22922d540810d90c5a3eafe91d3b4a62c2b881f3e990d0b7180b2875a5d176d}
PLUGIN_VERSION=v5.14.0
PLUGIN_COMMIT=ae0bd411c9aa2dcba4194717e2d3a6c70f51ce2d
PLUGIN_PARENT=/var/lib/buildkite-agent/plugins/vllm-router-rocm-do-a
PLUGIN_DIR=${PLUGIN_PARENT}/github-com-buildkite-plugins-docker-v5-14-0

[[ -d ${CHECKOUT_PATH} ]] || {
  echo "ERROR: checkout path is missing: ${CHECKOUT_PATH}" >&2
  exit 2
}

mkdir -p "${PLUGIN_PARENT}"
if [[ ! -d ${PLUGIN_DIR}/.git ]]; then
  git clone --quiet --depth 1 --branch "${PLUGIN_VERSION}" \
    https://github.com/buildkite-plugins/docker-buildkite-plugin.git \
    "${PLUGIN_DIR}"
fi

actual_commit=$(git -C "${PLUGIN_DIR}" rev-parse HEAD)
if [[ ${actual_commit} != "${PLUGIN_COMMIT}" ]]; then
  echo "ERROR: Docker plugin ${PLUGIN_VERSION} resolved to ${actual_commit}, expected ${PLUGIN_COMMIT}" >&2
  exit 2
fi

VALIDATION_COMMAND=$(cat <<'EOF'
set -Eeuo pipefail
test -c /dev/kfd
test -d /dev/dri
test -d /dev/infiniband
test -x /usr/bin/buildkite-agent
test -d /root/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B
test "$(ulimit -l)" = unlimited
test "$(ulimit -s)" -eq 65536
test "$(df --output=size -B1 /dev/shm | tail -n 1)" -ge 274877906944
test "$(rocm-smi -l 2>/dev/null | grep -c '^GPU\[')" -eq 8
python3 - <<'PY'
import torch
import vllm

assert torch.version.hip
assert torch.cuda.device_count() == 8
print(f"ROCm {torch.version.hip}; vLLM {vllm.__version__}; GPUs {torch.cuda.device_count()}")
PY
buildkite-agent --version
echo "Buildkite Docker plugin ROCm contract passed"
EOF
)

export BUILDKITE_AGENT_ID=manual-plugin-validation
export BUILDKITE_AGENT_NAME=vllm-router-rocm-do-a
export BUILDKITE_BUILD_ID=manual-plugin-validation
export BUILDKITE_BUILD_NUMBER=0
export BUILDKITE_COMMAND=
export BUILDKITE_ENV_FILE=/dev/null
export BUILDKITE_JOB_ID=manual-plugin-validation
export BUILDKITE_LABEL='ROCm Docker plugin validation'
export BUILDKITE_PIPELINE_NAME=vllm-router
export BUILDKITE_PIPELINE_SLUG=router
export BUILDKITE_STEP_KEY=rocm-plugin-validation
export BUILDKITE_PLUGIN_DOCKER_CHOWN=true
export BUILDKITE_PLUGIN_DOCKER_CHOWN_IMAGE=busybox@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616
export BUILDKITE_PLUGIN_DOCKER_COMMAND_0=bash
export BUILDKITE_PLUGIN_DOCKER_COMMAND_1=-c
export BUILDKITE_PLUGIN_DOCKER_COMMAND_2="${VALIDATION_COMMAND}"
export BUILDKITE_PLUGIN_DOCKER_DEVICES_0=/dev/kfd
export BUILDKITE_PLUGIN_DOCKER_DEVICES_1=/dev/dri
export BUILDKITE_PLUGIN_DOCKER_ENTRYPOINT=
export BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_0=MORIIO_READ_MODE=true
export BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_1=MORIIO_BACKEND=xgmi
export BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_2=MODEL_NAMES=Qwen/Qwen3-0.6B
export BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_3=ROUTER_BIN=/workdir/target/release/vllm-router
export BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_4=LOG_DIR=/workdir/target/ci-logs/plugin-validation
export BUILDKITE_PLUGIN_DOCKER_ENVIRONMENT_5=ENGINE_STARTUP_TIMEOUT=3600
export BUILDKITE_PLUGIN_DOCKER_IMAGE="${ROCM_VLLM_IMAGE}"
export BUILDKITE_PLUGIN_DOCKER_INIT=true
export BUILDKITE_PLUGIN_DOCKER_IPC=host
export BUILDKITE_PLUGIN_DOCKER_MOUNT_BUILDKITE_AGENT=true
export BUILDKITE_PLUGIN_DOCKER_PRIVILEGED=true
export BUILDKITE_PLUGIN_DOCKER_PROPAGATE_ENVIRONMENT=true
export BUILDKITE_PLUGIN_DOCKER_SECURITY_OPTS_0=seccomp=unconfined
export BUILDKITE_PLUGIN_DOCKER_SHM_SIZE=256g
export BUILDKITE_PLUGIN_DOCKER_TTY=false
export BUILDKITE_PLUGIN_DOCKER_ULIMITS_0=memlock=-1
export BUILDKITE_PLUGIN_DOCKER_ULIMITS_1=stack=67108864
export BUILDKITE_PLUGIN_DOCKER_VOLUMES_0=/var/lib/buildkite-agent/.cache/huggingface:/root/.cache/huggingface
export BUILDKITE_PLUGIN_DOCKER_WORKDIR=/workdir

cd "${CHECKOUT_PATH}"
"${PLUGIN_DIR}/hooks/command"
"${PLUGIN_DIR}/hooks/pre-exit"
