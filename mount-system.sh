#!/usr/bin/env bash
#
# mount-system.sh
#
# Helper to run from rescue mode (e.g. Hetzner):
#  - Detects the installed system's root filesystem
#  - Mounts it on /mnt
#  - Uses /mnt/etc/fstab to mount /boot and /boot/efi if configured
#  - Binds /proc, /sys, /dev, /run
#  - Enters chroot /mnt /bin/bash
#
# Usage (from rescue):
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/rescue/main/mount-system.sh)
#
# Or:
#   wget -O enter-real-system.sh https://raw.githubusercontent.com/lunaweb89/rescue/main/mount-system.sh
#   chmod +x mount-system.sh
#   ./mount-system.sh
#

set -euo pipefail

log() { echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  fi
}

# Detect a likely root filesystem device:
#  - prefer RAID md devices (md*)
#  - otherwise pick first ext4/xfs/btrfs that is not mounted
detect_root_device() {
  # Prefer md* devices with ext4/xfs/btrfs
  local root_dev
  root_dev=$(lsblk -pnro NAME,FSTYPE,MOUNTPOINT 2>/dev/null \
    | awk '$2 ~ /(ext4|xfs|btrfs)/ && $3 == "" && $1 ~ /md[0-9]+$/ {print $1; exit}')

  if [[ -n "${root_dev:-}" ]]; then
    echo "$root_dev"
    return 0
  fi

  # Fallback: any unmounted ext4/xfs/btrfs
  root_dev=$(lsblk -pnro NAME,FSTYPE,MOUNTPOINT 2>/dev/null \
    | awk '$2 ~ /(ext4|xfs|btrfs)/ && $3 == "" {print $1; exit}')

  if [[ -n "${root_dev:-}" ]]; then
    echo "$root_dev"
    return 0
  fi

  return 1
}

# Resolve UUID= / LABEL= to an actual device
resolve_fstab_spec() {
  local spec="$1"
  if [[ "$spec" =~ ^UUID= ]]; then
    local uuid="${spec#UUID=}"
    blkid -U "$uuid" 2>/dev/null || return 1
  elif [[ "$spec" =~ ^LABEL= ]]; then
    local label="${spec#LABEL=}"
    blkid -L "$label" 2>/dev/null || return 1
  else
    # Assume it's a direct device path (/dev/...)
    echo "$spec"
  fi
}

mount_if_not_mounted() {
  local dev="$1"
  local mnt="$2"

  if mountpoint -q "$mnt"; then
    log "$mnt already mounted."
    return 0
  fi

  mkdir -p "$mnt"
  log "Mounting $dev on $mnt..."
  mount "$dev" "$mnt"
}

mount_root() {
  local root_dev
  root_dev=$(detect_root_device) || {
    err "Could not auto-detect root filesystem device. Please mount manually."
    exit 1
  }

  log "Detected root device: $root_dev"

  if mountpoint -q /mnt; then
    log "/mnt already mounted, skipping root mount."
  else
    mkdir -p /mnt
    log "Mounting root filesystem..."
    mount "$root_dev" /mnt
  fi
}

mount_from_fstab() {
  local target="$1"   # e.g. /boot or /boot/efi
  local fstab_dev

  if [[ ! -f /mnt/etc/fstab ]]; then
    err "/mnt/etc/fstab not found; skipping $target mount."
    return 0
  fi

  fstab_dev=$(awk -v t="$target" '$1 !~ /^#/ && $2 == t {print $1; exit}' /mnt/etc/fstab || true)

  if [[ -z "${fstab_dev:-}" ]]; then
    log "No $target entry in /mnt/etc/fstab; skipping $target."
    return 0
  fi

  local real_dev
  real_dev=$(resolve_fstab_spec "$fstab_dev") || {
    err "Failed to resolve $fstab_dev for $target."
    return 0
  }

  mount_if_not_mounted "$real_dev" "/mnt${target}"
}

bind_system_dirs() {
  log "Binding /proc, /sys, /dev, /run into chroot..."

  mount -t proc proc /mnt/proc || true
  mount --rbind /sys /mnt/sys || true
  mount --rbind /dev /mnt/dev || true
  mount --rbind /run /mnt/run || true
}

summary() {
  echo
  echo "=================="
  echo " Chroot Environment"
  echo "=================="
  echo "Mounted:"
  mount | grep "^/dev" | grep "/mnt" || true
  echo
  echo "You are about to enter your REAL system:"
  echo "  chroot /mnt /bin/bash"
  echo
}

main() {
  require_root

  log "Detecting and mounting real root filesystem..."
  mount_root

  log "Attempting to mount /boot (if present in fstab)..."
  mount_from_fstab "/boot"

  log "Attempting to mount /boot/efi (if present in fstab)..."
  mount_from_fstab "/boot/efi"

  bind_system_dirs
  summary

  log "Entering chroot now: /mnt"
  exec chroot /mnt /bin/bash
}

main "$@"
