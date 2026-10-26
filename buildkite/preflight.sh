#!/usr/bin/env bash

set -Eeuo pipefail

# This is a privileged, dedicated agent. Keep the preflight targets fixed so a
# Buildkite job cannot redirect its SSH or filesystem checks with environment
# variables before the global pre-command hook runs.
readonly WORKER_SSH_HOST=vllm-router-rocm-worker
readonly EXPECTED_KERNEL=6.8.0-134-generic
readonly ROCM_VLLM_IMAGE=vllm/vllm-openai-rocm:nightly@sha256:d22922d540810d90c5a3eafe91d3b4a62c2b881f3e990d0b7180b2875a5d176d
readonly HF_CACHE_DIR=/var/lib/buildkite-agent/.cache/huggingface
readonly BUILDS_PATH=/var/lib/buildkite-agent/builds
readonly PLUGINS_PATH=/var/lib/buildkite-agent/plugins
readonly GRUB_OVERRIDE_PATH=/etc/default/grub.d/99-vllm-router-kernel.cfg
readonly -a REQUIRED_DKMS_MODULES=(amdgpu ionic mlnx-ofed-kernel)
readonly -a REQUIRED_LOADED_MODULES=(amdgpu mlx5_ib)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

gpu_count() {
  rocm-smi -l 2>/dev/null | grep -c '^GPU\['
}

rdma_count() {
  ibv_devices 2>/dev/null | awk '$1 ~ /^mlx5_[0-7]$/ { count++ } END { print count + 0 }'
}

check_gpu_idle() {
  local host=$1
  local memory_csv=$2
  local busy_gpus

  busy_gpus=$(printf '%s\n' "${memory_csv}" | awk -F, '
    $1 ~ /^card[0-7]$/ {
      gsub(/[[:space:]]/, "", $2)
      if (($2 + 0) > 5) {
        printf "%s=%s%% ", $1, $2
      }
    }
  ')
  [[ -z ${busy_gpus} ]] \
    || fail "${host} GPUs are not idle: ${busy_gpus}"
}

check_dkms_status() {
  local host=$1
  local status=$2
  local module

  for module in "${REQUIRED_DKMS_MODULES[@]}"; do
    printf '%s\n' "${status}" \
      | grep -Eq "^${module}/[^,]+, ${EXPECTED_KERNEL}, [^:]+: installed$" \
      || fail "${host} is missing installed ${module} DKMS for ${EXPECTED_KERNEL}"
  done
}

check_loaded_modules() {
  local host=$1
  local modules=$2
  local module

  for module in "${REQUIRED_LOADED_MODULES[@]}"; do
    printf '%s\n' "${modules}" | awk -v expected="${module}" '
      $1 == expected { found = 1 }
      END { exit !found }
    ' || fail "${host} is missing loaded kernel module ${module}"
  done
}

check_rdma_port() {
  local host=$1
  local device=$2
  local state=$3
  local physical_state=$4
  local link_layer=$5

  [[ ${state} == *ACTIVE ]] \
    || fail "${host} ${device} is not ACTIVE: ${state}"
  [[ ${physical_state} == *LinkUp ]] \
    || fail "${host} ${device} is not LinkUp: ${physical_state}"
  [[ ${link_layer} == Ethernet ]] \
    || fail "${host} ${device} does not use Ethernet link layer: ${link_layer}"
}

[[ $(uname -r) == "${EXPECTED_KERNEL}" ]] \
  || fail "coordinator kernel is $(uname -r), expected ${EXPECTED_KERNEL}"
[[ -f /boot/vmlinuz-${EXPECTED_KERNEL} ]] \
  || fail "coordinator is missing /boot/vmlinuz-${EXPECTED_KERNEL}"
[[ $(dpkg-query -W -f='${db:Status-Abbrev}' "linux-image-${EXPECTED_KERNEL}" 2>/dev/null || true) == "ii " ]] \
  || fail "coordinator linux-image-${EXPECTED_KERNEL} package is not installed"
grep -Eq "^GRUB_DEFAULT=\"gnulinux-advanced-[^\"]+>gnulinux-${EXPECTED_KERNEL}-advanced-[^\"]+\"$" \
  "${GRUB_OVERRIDE_PATH}" \
  || fail "coordinator GRUB default is not pinned to ${EXPECTED_KERNEL}"
check_dkms_status coordinator "$(dkms status 2>/dev/null)"
check_loaded_modules coordinator "$(cat /proc/modules)"

[[ $(gpu_count) -eq 8 ]] || fail "coordinator does not expose eight GPUs"
check_gpu_idle coordinator "$(rocm-smi --showmemuse --csv 2>/dev/null)"
[[ $(rdma_count) -eq 8 ]] || fail "coordinator does not expose eight mlx5 HCAs"
docker info >/dev/null
docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null
[[ -d "${HF_CACHE_DIR}/hub/models--Qwen--Qwen3-0.6B" ]] || fail "coordinator model cache is missing"

ssh -o BatchMode=yes "${WORKER_SSH_HOST}" true
worker_kernel=$(ssh "${WORKER_SSH_HOST}" uname -r)
[[ ${worker_kernel} == "${EXPECTED_KERNEL}" ]] \
  || fail "worker kernel is ${worker_kernel}, expected ${EXPECTED_KERNEL}"
ssh "${WORKER_SSH_HOST}" test -f "/boot/vmlinuz-${EXPECTED_KERNEL}" \
  || fail "worker is missing /boot/vmlinuz-${EXPECTED_KERNEL}"
worker_image_status=$(ssh "${WORKER_SSH_HOST}" \
  "dpkg-query -W -f='\${db:Status-Abbrev}' 'linux-image-${EXPECTED_KERNEL}'" 2>/dev/null || true)
[[ ${worker_image_status} == "ii " ]] \
  || fail "worker linux-image-${EXPECTED_KERNEL} package is not installed"
worker_grub_default=$(ssh "${WORKER_SSH_HOST}" cat "${GRUB_OVERRIDE_PATH}" 2>/dev/null || true)
printf '%s\n' "${worker_grub_default}" \
  | grep -Eq "^GRUB_DEFAULT=\"gnulinux-advanced-[^\"]+>gnulinux-${EXPECTED_KERNEL}-advanced-[^\"]+\"$" \
  || fail "worker GRUB default is not pinned to ${EXPECTED_KERNEL}"
check_dkms_status worker "$(ssh "${WORKER_SSH_HOST}" dkms status 2>/dev/null)"
check_loaded_modules worker "$(ssh "${WORKER_SSH_HOST}" cat /proc/modules)"

[[ $(ssh "${WORKER_SSH_HOST}" rocm-smi -l 2>/dev/null | grep -c '^GPU\[') -eq 8 ]] \
  || fail "worker does not expose eight GPUs"
check_gpu_idle worker "$(ssh "${WORKER_SSH_HOST}" rocm-smi --showmemuse --csv 2>/dev/null)"
[[ $(ssh "${WORKER_SSH_HOST}" ibv_devices 2>/dev/null | awk '$1 ~ /^mlx5_[0-7]$/ { count++ } END { print count + 0 }') -eq 8 ]] \
  || fail "worker does not expose eight mlx5 HCAs"
ssh "${WORKER_SSH_HOST}" docker info >/dev/null
ssh "${WORKER_SSH_HOST}" docker image inspect "${ROCM_VLLM_IMAGE}" >/dev/null
ssh "${WORKER_SSH_HOST}" test -d "${HF_CACHE_DIR}/hub/models--Qwen--Qwen3-0.6B"

for writable_path in "${BUILDS_PATH}" "${PLUGINS_PATH}"; do
  [[ -d ${writable_path} && -w ${writable_path} ]] \
    || fail "Buildkite path is not writable: ${writable_path}"
done

for rail in {0..7}; do
  rdma_device="mlx5_${rail}"
  interface="eth$((rail + 2))"
  coordinator_address="192.168.200.$((rail * 4 + 1))/30"
  worker_address="192.168.200.$((rail * 4 + 2))/30"
  worker_ip=${worker_address%/30}

  check_rdma_port \
    coordinator \
    "${rdma_device}" \
    "$(<"/sys/class/infiniband/${rdma_device}/ports/1/state")" \
    "$(<"/sys/class/infiniband/${rdma_device}/ports/1/phys_state")" \
    "$(<"/sys/class/infiniband/${rdma_device}/ports/1/link_layer")"
  check_rdma_port \
    worker \
    "${rdma_device}" \
    "$(ssh "${WORKER_SSH_HOST}" cat "/sys/class/infiniband/${rdma_device}/ports/1/state")" \
    "$(ssh "${WORKER_SSH_HOST}" cat "/sys/class/infiniband/${rdma_device}/ports/1/phys_state")" \
    "$(ssh "${WORKER_SSH_HOST}" cat "/sys/class/infiniband/${rdma_device}/ports/1/link_layer")"

  ip -4 -o address show dev "${interface}" | grep -qw "${coordinator_address}" \
    || fail "coordinator ${interface} is missing ${coordinator_address}"
  [[ $(<"/sys/class/net/${interface}/mtu") -eq 9000 ]] \
    || fail "coordinator ${interface} does not use MTU 9000"
  [[ $(<"/sys/class/net/${interface}/operstate") == up ]] \
    || fail "coordinator ${interface} is not up"

  ssh "${WORKER_SSH_HOST}" ip -4 -o address show dev "${interface}" \
    | grep -qw "${worker_address}" \
    || fail "worker ${interface} is missing ${worker_address}"
  [[ $(ssh "${WORKER_SSH_HOST}" cat "/sys/class/net/${interface}/mtu") -eq 9000 ]] \
    || fail "worker ${interface} does not use MTU 9000"
  [[ $(ssh "${WORKER_SSH_HOST}" cat "/sys/class/net/${interface}/operstate") == up ]] \
    || fail "worker ${interface} is not up"

  ping -c 1 -W 2 -M do -s 8972 "${worker_ip}" >/dev/null \
    || fail "jumbo-frame fabric check failed for ${worker_ip}"
done

echo "MI300X coordinator/worker preflight passed: pinned kernel, DKMS, loaded drivers, idle GPUs, 8 active HCAs, Docker image, model cache, SSH, and jumbo RoCE rails"
