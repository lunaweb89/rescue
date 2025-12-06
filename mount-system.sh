#!/usr/bin/env bash
#
# mount-system.sh
#
# Automatically detect and mount your REAL server filesystem from Hetzner Rescue Mode.
# Steps performed:
#   - Detect real root filesystem (RAID md*, ext4, xfs, btrfs)
#   - Mount root filesystem on /mnt
#   - Auto-mount /boot and /boot/efi based on /mnt/etc/fstab
#   - Bind /proc, /sys, /dev, /run
#   - chroot into the REAL system
#
# Run directly from GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/rescue/main/mount-system.sh)
#

set -euo pipefail

log() { echo "[*] $*"; }
err() { echo "[!] $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  }
}

# Detect the installed OS's real root device
detect_root_device() {
  local root_dev

  # Prefer RAID md arrays with ext4/xfs/btrfs
  root_dev=$(lsblk -pnro NAME,FSTYPE,MOUNTPOINT \
    | awk '$2 ~ /(ext4|xfs|btrfs)/ && $3 == "" && $1 ~ /md[0-9]+$/ {print $1; exit}')

  if [[ -n "${root_dev:-}" ]]; then
    echo "$root_dev"
    return 0
  fi

  # Fallback: any standalone ext4/xfs/btrfs partition unmounted
  root_dev=$(lsblk -pnro NAME,FSTYPE,MOUNTPOINT \
    | awk '$2 ~ /(ext4|xfs|btrfs)/ && $3 == "" {print $1; exit}')

  if [[ -n "${root_dev:-}" ]]; then
    echo "$root_dev"
    return 0
  fi

  return 1
}

resolve_fstab_spec() {
  local spec="$1"

  if [[ "$spec" =~ ^UUID= ]]; then
    blkid -U "${spec#UUID=}" 2>/dev/null || return 1
  elif [[ "$spec" =~ ^LABEL= ]]; then
    blkid -L "${spec#LABEL=}" 2>/dev/null || return 1
  else
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
  log "Mounting $dev → $mnt"
  mount "$dev" "$mnt"
}

mount_root() {
  local root_dev
  root_dev=$(detect_root_device) || {
    err "Unable to detect root filesystem automatically."
    exit 1
  }

  log "Detected root device: $root_dev"
  mount_if_not_mounted "$root_dev" /mnt
}

mount_from_fstab() {
  local target="$1"
  local fstab_dev

  if [[ ! -f /mnt/etc/fstab ]]; then
    log "WARNING: /mnt/etc/fstab not found. Skipping $target."
    return 0
  fi

  fstab_dev=$(awk -v t="$target" '$1 !~ /^#/ && $2 == t {print $1; exit}' /mnt/etc/fstab || true)

  if [[ -z "$fstab_dev" ]]; then
    log "fstab: No entry for $target"
    return 0
  fi

  local real_dev
  real_dev=$(resolve_fstab_spec "$fstab_dev") || {
    err "Could not resolve device for $target ($fstab_dev)"
    return 0
  }

  mount_if_not_mounted "$real_dev" "/mnt${target}"
}

bind_system_dirs() {
  log "Binding system directories..."

  mount -t proc proc /mnt/proc || true
  mount --rbind /sys /mnt/sys || true
  mount --rbind /dev /mnt/dev || true
  mount --rbind /run /mnt/run || true
}

summary() {
  echo
  echo "============================="
  echo " Real System Mount Summary"
  echo "============================="
  mount | grep "/mnt" || true
  echo
  echo "You are now inside your REAL server."
  echo "Use commands normally, for example:"
  echo "  passwd root"
  echo "  nano /etc/ssh/sshd_config.d/99-hardening.conf"
  echo "  systemctl restart sshd   (ignored but safe)"
  echo
  echo "When finished, exit chroot:"
  echo "  exit"
  echo
}

main() {
  require_root

  log "Mounting real root filesystem..."
  mount_root

  log "Mounting /boot (if defined)..."
  mount_from_fstab "/boot"

  log "Mounting /boot/efi (if defined)..."
  mount_from_fstab "/boot/efi"

  bind_system_dirs
  summary

  log "Entering chroot → /mnt ..."
  exec chroot /mnt /bin/bash
}

main "$@"
