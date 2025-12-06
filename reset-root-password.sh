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
#   4) INSPECT inside real system:
#         - Effective SSH config (ports, PermitRootLogin, PasswordAuthentication)
#         - UFW config files for SSH ports (22, 2808)
#   5) Optionally APPLY a standard SSH config:
#         - Ports 22 and 2808
#         - PermitRootLogin yes
#         - PasswordAuthentication yes
#         - MaxAuthTries 5
#   6) Optionally create /root/post-rescue-ufw-fix.sh inside the real system
#      (to be run AFTER reboot, on the real OS, to fix UFW SSH rules)
#   7) Run: chroot /mnt passwd root   (you type new password interactively)
#   8) Cleanly unmount everything under /mnt
#
# Usage (from rescue):
#   bash <(curl -fsSL https://raw.githubusercontent.com/lunaweb89/rescue/main/reset-root-password.sh)
#

set -euo pipefail

log() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die() { warn "$@"; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root."
  fi
}

ROOT_DEV=""
BOOT_DEV=""

find_root_and_boot() {
  # Prefer md devices with ext4 / ext3, typical Hetzner setup
  ROOT_DEV="$(blkid -t TYPE=ext4 -o device | grep -E '^/dev/md' | head -n1 || true)"
  BOOT_DEV="$(blkid -t TYPE=ext3 -o device | grep -E '^/dev/md' | head -n1 || true)"

  if [[ -z "$ROOT_DEV" ]]; then
    # fallback: any ext4 device
    ROOT_DEV="$(blkid -t TYPE=ext4 -o device | head -n1 || true)"
  fi

  if [[ -z "$ROOT_DEV" ]]; then
    die "Could not detect root filesystem (ext4). Aborting."
  fi

  log "Detected root filesystem: $ROOT_DEV"
  if [[ -n "$BOOT_DEV" ]]; then
    log "Detected boot filesystem: $BOOT_DEV"
  else
    log "No separate /boot partition detected (this is OK on some setups)."
  fi
}

mount_real_system() {
  log "Mounting root filesystem on /mnt ..."
  mount "$ROOT_DEV" /mnt

  if [[ -n "$BOOT_DEV" ]]; then
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
      warn "Lazy unmount failed. Check mounts manually with: mount | grep mnt"
      exit 1
    }
  fi

  local remains
  remains="$(mount | grep 'on /mnt' || true)"
  if [[ -z "$remains" ]]; then
    log "/mnt fully unmounted. Safe to reboot."
  else
    warn "Some mounts remain under /mnt:"
    echo "$remains"
    warn "You may need to run: umount -l /mnt"
    exit 1
  fi
}

show_ssh_effective() {
  echo
  echo "=============================================="
  echo "  Effective SSH Settings (inside real system)"
  echo "=============================================="
  echo

  chroot /mnt bash -c '
    if command -v sshd >/dev/null 2>&1; then
      echo "sshd binary found: $(command -v sshd)"
      echo
      echo "---- sshd -T (filtered: port, permitrootlogin, passwordauthentication) ----"
      sshd -T 2>/dev/null | egrep "^(port|permitrootlogin|passwordauthentication) " | sort | uniq || \
        echo "  (sshd -T failed or no matching lines)"
    else
      echo "sshd binary not found inside chroot (/mnt)."
    fi
  '
}

inspect_ufw_config() {
  echo
  echo "=============================================="
  echo "  UFW SSH Rules from Config Files (offline)"
  echo "=============================================="
  echo
  local rules_file="/mnt/etc/ufw/user.rules"
  if [[ -f "$rules_file" ]]; then
    echo "Found UFW rules file: $rules_file"
    echo
    echo "---- Lines containing dpt 22 / 2808 ----"
    grep -E 'dpt (22|2808)' "$rules_file" || echo "No explicit SSH port rules for 22/2808 found in user.rules"
  else
    echo "No /etc/ufw/user.rules found inside /mnt. UFW may not be configured."
  fi
}

apply_standard_ssh_config() {
  echo
  log "Applying standard SSH config template inside real system..."

  local ssh_dir="/mnt/etc/ssh/sshd_config.d"
  local harden_file="$ssh_dir/99-hardening.conf"

  mkdir -p "$ssh_dir"

  cat > "$harden_file" <<'EOF'
# SSH Hardening (rescue script template)

# Listen on BOTH ports:
Port 22
Port 2808
Protocol 2

# Allow root login with password (you control strong password)
PermitRootLogin yes

# Allow password authentication (for root login / users)
PasswordAuthentication yes

ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes

# Security options
X11Forwarding no
AllowTcpForwarding yes
AllowAgentForwarding yes

LoginGraceTime 30
MaxAuthTries 5
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  log "Wrote SSH hardening file: $harden_file"

  # Validate syntax only; we don't reload ssh here (system is offline under rescue)
  chroot /mnt bash -c '
    if command -v sshd >/dev/null 2>&1; then
      echo "[*] Testing sshd configuration inside chroot (sshd -t)..."
      if sshd -t 2>/dev/null; then
        echo "[*] sshd config OK (will be used after you reboot)."
      else
        echo "[!] sshd -t reported an error. Please review /etc/ssh/sshd_config* after boot."
      fi
    else
      echo "[!] sshd binary not found; cannot test config."
    fi
  '
}

maybe_apply_ssh_template() {
  echo
  echo "------------------------------------------------------"
  echo "Current SSH settings have been printed above."
  echo "You can optionally apply a STANDARD template with:"
  echo "  - Ports: 22 and 2808"
  echo "  - PermitRootLogin yes"
  echo "  - PasswordAuthentication yes"
  echo "  - MaxAuthTries 5"
  echo "------------------------------------------------------"
  echo

  read -rp "Apply this SSH template inside the real system? [y/N]: " ans
  ans="${ans,,}"
  if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
    apply_standard_ssh_config
  else
    log "Leaving SSH configuration unchanged."
  fi
}

maybe_create_post_ufw_fix_script() {
  echo
  echo "------------------------------------------------------"
  echo "We can prepare a helper script INSIDE the real system:"
  echo "  /root/post-rescue-ufw-fix.sh"
  echo
  echo "You will run it AFTER reboot, from the real OS, to:"
  echo "  - ufw allow 22/tcp && ufw limit 22/tcp"
  echo "  - ufw allow 2808/tcp && ufw limit 2808/tcp"
  echo "  - ufw reload && ufw status verbose"
  echo "------------------------------------------------------"
  echo

  read -rp "Create /root/post-rescue-ufw-fix.sh inside the real system? [y/N]: " ans
  ans="${ans,,}"
  if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
    log "Skipping creation of post-rescue UFW fix script."
    return
  fi

  local script_path="/mnt/root/post-rescue-ufw-fix.sh"

  cat > "$script_path" <<'EOS'
#!/usr/bin/env bash
#
# Run this AFTER reboot, on the REAL system (not rescue).
# It will adjust UFW to allow SSH on ports 22 and 2808.
set -euo pipefail

echo "[+] Fixing UFW SSH rules (22/tcp and 2808/tcp)..."

if ! command -v ufw >/dev/null 2>&1; then
  echo "[!] ufw not found. Install it first: apt-get install ufw"
  exit 1
fi

ufw allow 22/tcp    || true
ufw limit 22/tcp    || true
ufw allow 2808/tcp  || true
ufw limit 2808/tcp  || true

ufw reload          || true
ufw status verbose  || true

echo "[+] Done. Verify SSH connectivity on ports 22 and 2808."
EOS

  chmod +x "$script_path"
  log "Created: /root/post-rescue-ufw-fix.sh (inside real system)"
  log "After reboot and SSH login, run: bash /root/post-rescue-ufw-fix.sh"
}

reset_root_password() {
  echo
  echo "======================================================"
  echo "  Now changing the REAL system's ROOT password"
  echo "======================================================"
  echo
  echo "When prompted, type your NEW root password."
  echo "This password will be used later for SSH login as root."
  echo

  chroot /mnt passwd root || {
    warn "'passwd root' inside chroot failed."
    warn "Your root password may NOT have been changed."
    return 1
  }

  log "Root password changed successfully inside real system."
}

main() {
  require_root

  echo
  echo "==========================================="
  echo "  Hetzner Rescue: SSH & Root Recovery Tool"
  echo "==========================================="
  echo

  find_root_and_boot
  mount_real_system

  # 1) Inspect SSH & UFW
  show_ssh_effective
  inspect_ufw_config

  # 2) Optionally apply standard SSH template
  maybe_apply_ssh_template

  # 3) Optionally create post-boot UFW fix script
  maybe_create_post_ufw_fix_script

  # 4) Reset root password interactively
  reset_root_password

  echo
  echo "[*] Exiting chroot steps. Now unmounting real system ..."
  unmount_real_system

  echo
  echo "=============================================="
  echo "  DONE."
  echo "  Next steps:"
  echo "    1) reboot"
  echo "    2) SSH back with: ssh root@IP -p 2808  (or -p 22)"
  echo "    3) (Optional) run: bash /root/post-rescue-ufw-fix.sh"
  echo "=============================================="
  echo
}

main "$@"
