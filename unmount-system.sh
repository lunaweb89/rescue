#!/usr/bin/env bash
#
# unmount-system.sh
#
# Safely unmount the REAL server filesystem after using mount-system.sh
# This script:
#   - Checks if /mnt and its bind mounts are active
#   - Attempts clean unmount (umount -R /mnt)
#   - Falls back to safe lazy unmount (umount -l /mnt) if busy
#   - Verifies nothing remains mounted under /mnt
#
# Run from rescue mode:
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/rescue/main/unmount-system.sh)
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

check_active_mounts() {
  mount | grep "on /mnt" || true
}

try_clean_unmount() {
  log "Attempting clean unmount: umount -R /mnt ..."
  if umount -R /mnt 2>/tmp/umount.err; then
    log "Clean unmount successful."
    return 0
  fi

  log "Clean unmount failed:"
  cat /tmp/umount.err
  return 1
}

force_lazy_unmount() {
  log "Performing SAFE lazy unmount: umount -l /mnt ..."
  umount -l /mnt || {
    err "Lazy unmount failed — unexpected error."
    exit 1
  }
  log "Lazy unmount successful."
}

verify_unmounted() {
  local remains
  remains=$(mount | grep "on /mnt" || true)

  if [[ -z "$remains" ]]; then
    log "All /mnt mountpoints fully unmounted."
    return 0
  else
    err "Some mounts remain:"
    echo "$remains"
    err "You may need: umount -l /mnt"
    exit 1
  fi
}

main() {
  require_root

  echo
  echo "=============================="
  echo " Unmounting Real System (/mnt)"
  echo "=============================="
  echo

  log "Checking active mounts under /mnt ..."
  local before
  before=$(check_active_mounts)

  if [[ -z "$before" ]]; then
    log "No mounts found under /mnt — nothing to unmount."
    exit 0
  fi

  echo "$before"

  # Step 1: Try clean recursive unmount
  if try_clean_unmount; then
    verify_unmounted
    return 0
  fi

  # Step 2: Fall back to safe lazy unmount
  log "Falling back to lazy unmount (this is normal in rescue mode) ..."
  force_lazy_unmount

  # Step 3: Final verification
  verify_unmounted

  echo
  echo "=================================="
  echo "  /mnt successfully unmounted."
  echo "  It is now safe to reboot."
  echo "=================================="
  echo
}

main "$@"
