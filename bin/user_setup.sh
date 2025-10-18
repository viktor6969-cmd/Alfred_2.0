#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# USER MODULE — bootstrap for user rename and temporary SSH relaxation
# ==================================================================================
# Expectations:
# - Run ONLY via server_auto.sh with -u mode (isolated user flow)
# - Reads secrets from config/.env (NEW_USERNAME, ROOT_PASSWORD)
# - Reads SSH templates/ports from config/server.conf via utils.sh
# - This script:
#     1) Ensures root has a password (if missing/locked)
#     2) Writes bootstrap SSH drop-in from [ssh.bootstrap] (port {{SSH_PORT_BOOTSTRAP}})
#     3) Validates & reloads SSH
#     4) Stages /root/change_name.sh for phase 2
# ==================================================================================

# ----------------------------------------------------------------------------------
# Locate project root and utils
# ----------------------------------------------------------------------------------
SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
MODULE_DIR="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
ROOT_DIR="$(cd "$MODULE_DIR/../.." && pwd)"
UTILS_DIR="$ROOT_DIR/utils"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }

if [[ -f "$UTILS_DIR/utils.sh" ]]; then
  # shellcheck disable=SC1090
  source "$UTILS_DIR/utils.sh"
else
  echo "utils.sh not found at $UTILS_DIR/utils.sh" >&2
  exit 1
fi

# Load env (secrets) + server.conf (ports/templates)
load_env
load_server_conf

# ----------------------------------------------------------------------------------
# Root password setup:
# - If root already has a password (status P) => skip
# - Else: offer to use $ROOT_PASSWORD from .env (if present), or prompt securely
# ----------------------------------------------------------------------------------
root_status="$(passwd -S root 2>/dev/null | awk '{print $2}')"
if [[ -z "${root_status:-}" ]]; then
  print_error "Unable to determine root password status (passwd -S). Aborting."
  exit 1
fi

if [[ "$root_status" == "P" ]]; then
  print_info "Root already has a password — skipping."
else
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then
    read -rp "Use default root password from .env? (y/N): " ans; echo
    if [[ $ans =~ $YES_REGEX ]]; then
      if printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd; then
        print_success "Root password set from .env."
      else
        print_error "Failed to set root password from .env."; exit 1
      fi
    else
      print_info "Interactive password setup..."
      while true; do
        read -srp "Enter new root password: " _pw1; echo
        read -srp "Confirm new root password: " _pw2; echo
        [[ -z "$_pw1" || -z "$_pw2" ]] && { print_error "Password cannot be empty."; continue; }
        [[ "$_pw1" != "$_pw2" ]] && { print_error "Passwords do not match."; continue; }
        if printf 'root:%s\n' "$_pw1" | chpasswd; then
          print_success "Root password set."
          unset _pw1 _pw2
          break
        else
          print_error "Failed to set password. Try again."
        fi
      done
    fi
  else
    print_info "No default root password in .env — interactive setup..."
    while true; do
      read -srp "Enter new root password: " _pw1; echo
      read -srp "Confirm new root password: " _pw2; echo
      [[ -z "$_pw1" || -z "$_pw2" ]] && { print_error "Password cannot be empty."; continue; }
      [[ "$_pw1" != "$_pw2" ]] && { print_error "Passwords do not match."; continue; }
      if printf 'root:%s\n' "$_pw1" | chpasswd; then
        print_success "Root password set."
        unset _pw1 _pw2
        break
      else
        print_error "Failed to set password. Try again."
      fi
    done
  fi
fi

# ----------------------------------------------------------------------------------
# SSH bootstrap drop-in from server.conf
# ----------------------------------------------------------------------------------
echo -e "Backing up /etc/ssh/sshd_config to .bkp ..."
backup_file "/etc/ssh/sshd_config"

echo -e "Writing SSH bootstrap drop-in from [ssh.bootstrap]..."
mkdir -p /etc/ssh/sshd_config.d
write_ssh_bootstrap

echo -e "Validating sshd config..."
if ! sshd -t; then
  print_error "SSH config invalid. Aborting before reload."
  exit 1
fi

echo -e "Reloading SSH with bootstrap settings..."
if systemctl is-active --quiet ssh; then
  systemctl reload ssh || systemctl restart ssh
else
  echo -e "Starting SSH service..."
  systemctl start ssh
fi
print_success "SSH bootstrap applied (port ${SSH_PORT_BOOTSTRAP})."

# ----------------------------------------------------------------------------------
# Stage rename tool:
# - Install modules/user/change_name.sh into /root/change_name.sh (700, root:root)
# ----------------------------------------------------------------------------------
SRC_CHANGE="$MODULE_DIR/change_name.sh"
DST_CHANGE="/root/change_name.sh"

[[ -f "$SRC_CHANGE" ]] || { print_error "change_name.sh not found in $MODULE_DIR"; exit 1; }

echo -e "Staging $DST_CHANGE ..."
ln -sfn "$SRC_CHANGE" "$DST_CHANGE"
chmod 700 "$SRC_CHANGE"        # ensure the target is executable
chown root:root "$SRC_CHANGE"  # optional if you care

print_success "User bootstrap complete."
print_info "Reconnect as root on port ${SSH_PORT_BOOTSTRAP} and run: /root/change_name.sh"
