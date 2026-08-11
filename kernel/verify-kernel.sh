#!/usr/bin/env bash

set -Eeuo pipefail

EXPECTED_KERNEL=${1:-6.8.0-134-generic}
readonly -a REQUIRED_DKMS_MODULES=(amdgpu ionic mlnx-ofed-kernel)
actual_kernel=$(uname -r)

if [[ ${actual_kernel} != "${EXPECTED_KERNEL}" ]]; then
  echo "ERROR: running kernel ${actual_kernel}; expected ${EXPECTED_KERNEL}" >&2
  exit 1
fi

rocm-smi -l >/dev/null
[[ $(rocm-smi -l 2>/dev/null | grep -c '^GPU\[') -eq 8 ]] || {
  echo "ERROR: expected eight visible GPUs" >&2
  exit 1
}

[[ $(ibv_devices 2>/dev/null | awk '$1 ~ /^mlx5_[0-7]$/ { count++ } END { print count + 0 }') -eq 8 ]] || {
  echo "ERROR: expected eight mlx5 HCAs" >&2
  exit 1
}

dkms_status=$(dkms status 2>/dev/null)
for module in "${REQUIRED_DKMS_MODULES[@]}"; do
  printf '%s\n' "${dkms_status}" \
    | grep -Eq "^${module}/[^,]+, ${EXPECTED_KERNEL}, [^:]+: installed$" || {
      echo "ERROR: ${module} DKMS is not installed for ${EXPECTED_KERNEL}" >&2
      exit 1
    }
done

for rail in {0..7}; do
  device="mlx5_${rail}"
  [[ $(<"/sys/class/infiniband/${device}/ports/1/state") == *ACTIVE ]] || {
    echo "ERROR: ${device} is not ACTIVE" >&2
    exit 1
  }
  [[ $(<"/sys/class/infiniband/${device}/ports/1/phys_state") == *LinkUp ]] || {
    echo "ERROR: ${device} is not LinkUp" >&2
    exit 1
  }
  [[ $(<"/sys/class/infiniband/${device}/ports/1/link_layer") == Ethernet ]] || {
    echo "ERROR: ${device} does not use the Ethernet link layer" >&2
    exit 1
  }
done

echo "Kernel ${actual_kernel}, DKMS, eight GPUs, and eight active HCAs verified"
