#!/usr/bin/env bash

set -Eeuo pipefail

if (( EUID != 0 )); then
  echo "ERROR: run this script as root" >&2
  exit 2
fi

TARGET_KERNEL=${1:-6.8.0-134-generic}
GRUB_CONFIG=/boot/grub/grub.cfg
OVERRIDE_PATH=/etc/default/grub.d/99-vllm-router-kernel.cfg

if [[ ! -f "/boot/vmlinuz-${TARGET_KERNEL}" ]]; then
  echo "ERROR: kernel image is not installed: /boot/vmlinuz-${TARGET_KERNEL}" >&2
  exit 2
fi

submenu_id=$(awk -F"'" '
  /^submenu '\''Advanced options for Ubuntu'\''/ { print $4; exit }
' "${GRUB_CONFIG}")

entry_id=$(awk -F"'" -v target="Ubuntu, with Linux ${TARGET_KERNEL}" '
  $1 ~ /^[[:space:]]*menuentry / && $2 == target { print $4; exit }
' "${GRUB_CONFIG}")

if [[ -z ${submenu_id} || -z ${entry_id} ]]; then
  echo "ERROR: could not resolve the exact GRUB menu IDs for ${TARGET_KERNEL}" >&2
  exit 2
fi

umask 022
tmp_file=$(mktemp /tmp/vllm-router-kernel-pin.XXXXXX)
cleanup() {
  rm -f "${tmp_file}"
}
trap cleanup EXIT

printf 'GRUB_DEFAULT="%s>%s"\n' "${submenu_id}" "${entry_id}" >"${tmp_file}"
install -o root -g root -m 0644 "${tmp_file}" "${OVERRIDE_PATH}"

kernel_release=${TARGET_KERNEL%-generic}
for package in \
  "linux-image-${TARGET_KERNEL}" \
  "linux-modules-${TARGET_KERNEL}" \
  "linux-modules-extra-${TARGET_KERNEL}" \
  "linux-headers-${kernel_release}" \
  "linux-headers-${TARGET_KERNEL}" \
  "linux-tools-${kernel_release}" \
  "linux-tools-${TARGET_KERNEL}"; do
  if [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null || true) == "ii " ]]; then
    apt-mark manual "${package}" >/dev/null
  fi
done

update-grub

echo "Pinned the persistent GRUB default to ${TARGET_KERNEL}"
echo "Marked the installed ${TARGET_KERNEL} image, modules, headers, and tools as manually installed"
echo "Reboot, then run kernel/verify-kernel.sh ${TARGET_KERNEL}"
