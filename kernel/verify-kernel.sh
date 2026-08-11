#!/usr/bin/env bash

set -Eeuo pipefail

EXPECTED_KERNEL=${1:-6.8.0-134-generic}
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

echo "Kernel ${actual_kernel}, eight GPUs, and eight HCAs verified"
