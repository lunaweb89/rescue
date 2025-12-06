#!/usr/bin/env bash
#
# reset-root-password.sh
#
# Run this from Hetzner RESCUE SYSTEM.
#
# What it does:
#   1) Detect the real Linux root filesystem (/dev/md2 ext4, etc.)
#   2) Mount / on /mnt, and /boot if found
#   3) Bind /proc, /sys, /dev into /mnt
#   4) Run: chroot /mnt passwd root   (you type new password interactively)
#   5) Cleanly unmount everything under /mnt
#
# Usage (from rescue):
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/rescue/main/reset-root-password.sh)
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

find_root_and_boot() {
  # Prefer md devices with ext4 / ext3, typical Hetzner setup
  ROOT_DEV="$(blkid -t TYPE=ext4 -o device | grep -E '^/dev/md' | head -n1 || true)"
  BOOT_DEV="$(blkid -t TYPE=ext3 -o device | grep -E '^/dev/md' | head -n1 || true)"

  if [[ -z "$ROOT_DEV" ]]; then
    # fallback: any ext4 device
    ROOT_DEV="$(blkid -t TYPE=ext4 -o device | head -n1 || true)"
  fi

  if [[ -z "$ROOT_DEV" ]]; then
    err "Could not detect root filesystem (ext4). Aborting."
    exit 1
  fi

  log "Detected root filesystem: $ROOT_DEV"
  if [[ -n "${BOOT_DEV:-}" ]]; then
    log "Detected boot filesystem: $BOOT_DEV"
  else
    log "No separate /boot partition detected (this is OK on some setups)."
  fi
}

mount_real_system() {
  log "Mounting root filesystem on /mnt ..."
  mount "$ROOT_DEV" /mnt

  if [[ -n "${BOOT_DEV:-}" ]]; then
    log "Mounting /boot on /mnt/boot ..."
    mkdir -p /mnt/boot
    mount "$BOOT_DEV" /mnt/boot
  fi

  log "Binding system directories into chroot ..."
  mount -t proc proc /mnt/proc
  mount --rbind /sys /mnt/sys
  mount --rbind /dev /mnt/dev
}

unmount_real_system() {
  log "Attempting clean recursive unmount: umount -R /mnt ..."
  if umount -R /mnt 2>/tmp/unmount.err; then
    log "Clean unmount successful."
  else
    log "Clean unmount failed (likely some bind-mount still busy):"
    cat /tmp/unmount.err || true
    log "Falling back to lazy unmount: umount -l /mnt ..."
    umount -l /mnt || {
      err "Lazy unmount failed. Check mounts manually with: mount | grep mnt"
      exit 1
    }
  fi

  local remains
  remains="$(mount | grep 'on /mnt' || true)"
  if [[ -z "$remains" ]]; then
    log "/mnt fully unmounted. Safe to reboot."
  else
    err "Some mounts remain under /mnt:"
    echo "$remains"
    err "You may need to run: umount -l /mnt"
    exit 1
  fi
}

reset_root_password() {
  echo
  echo "======================================================"
  echo "  You are now about to change the REAL system's"
  echo "  ROOT password inside a chroot."
  echo "======================================================"
  echo
  echo "When prompted, type your NEW root password."
  echo "This password will be used for SSH login (root) later."
  echo

  # Run passwd inside the chroot, interactive prompts go to your terminal
  chroot /mnt passwd root || {
    err "'passwd root' inside chroot failed."
    err "Your root password may NOT have been changed."
    return 1
  }

  log "Root password changed successfully inside chroot."
}

main() {
  require_root

  echo
  echo "==========================================="
  echo "  Hetzner Rescue: Root Password Reset Tool"
  echo "==========================================="
  echo

  find_root_and_boot
  mount_real_system

  # Do the interactive password reset
  reset_root_password

  echo
  echo "[*] Exiting chroot password step. Now unmounting real system ..."
  unmount_real_system

  echo
  echo "=============================================="
  echo "  DONE. You can now reboot into your server:"
  echo "    reboot"
  echo "=============================================="
  echo
}

main "$@"
