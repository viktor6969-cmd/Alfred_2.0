#!/usr/bin/env bash


# ==================================================================================
# USER MODULE — bootstrap for user rename and temporary SSH relaxation
# ==================================================================================
# Expectations:
# - Run ONLY via server_auto.sh with -u mode (isolated user flow)
# - Loads config from config/.env (via utils.sh)
# - This script:
#     1) Ensures root has a password (if missing/locked)
#     2) Installs a temporary SSH drop-in from $SSH_BOOTSTRAP_CONF (port 42, root/pass)
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

load_env

# ----------------------------------------------------------------------------------
# Root password setup:
# - If root already has a password (status P) => skip
# - Else: offer to use $ROOT_PASSWORD from .env (if present), or prompt securely
# ----------------------------------------------------------------------------------
root_status="$(sudo passwd -S root 2>/dev/null | awk '{print $2}')"
if [[ -z "${root_status:-}" ]]; then
  print_error "Unable to determine root password status (passwd -S). Aborting."
  exit 1
fi

if [[ "$root_status" == "P" ]]; then
  print_info "Root already has a password — skipping."
else
  # Either use $ROOT_PASSWORD from .env (if set) or interactively prompt
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then
    read -rp "Use default root password from .env? (y/N): " ans; echo
    # Set the password from .env
    if [[ $ans =~ $YES_REGEX ]]; then
      if printf 'root:%s\n' "$ROOT_PASSWORD" | sudo chpasswd; then
        print_success "Root password set from .env."
      else
        print_error "Failed to set root password from .env."; exit 1
      fi
    else
      # Set the password interactively
      print_info "Entering interactive password setup..."
      while true; do
        read -srp "Enter new root password: " _pw1; echo
        read -srp "Confirm new root password: " _pw2; echo
        if [[ -z "$_pw1" || -z "$_pw2" ]]; then
          print_error "Password cannot be empty."; continue
        fi
        if [[ "$_pw1" != "$_pw2" ]]; then
          print_error "Passwords do not match, try again"; continue
        fi
        if printf 'root:%s\n' "$_pw1" | sudo chpasswd; then
          print_success "Root password set."
          unset _pw1 _pw2
          break
        else
          print_error "Failed to set root password. Try again."
        fi
      done
    fi
  else
    # No default in .env — must prompt
    print_info "No default root password in .env — entering interactive setup..."
    while true; do
      read -srp "Enter new root password: " _pw1; echo
      read -srp "Confirm new root password: " _pw2; echo
      if [[ -z "$_pw1" || -z "$_pw2" ]]; then
        print_error "Password cannot be empty."; continue
      fi
      if [[ "$_pw1" != "$_pw2" ]]; then
        print_error "Passwords do not match."; continue
      fi
      if printf 'root:%s\n' "$_pw1" | sudo chpasswd; then
        print_success "Root password set."
        unset _pw1 _pw2
        break
      else
        print_error "Failed to set root password. Try again."
      fi
    done
  fi
fi



# ----------------------------------------------------------------------------------
# SSH bootstrap drop-in:
# - Backup current sshd_config
# - Write /etc/ssh/sshd_config.d/99-bootstrap.conf from $SSH_BOOTSTRAP_CONF
# - Validate and reload sshd
# ----------------------------------------------------------------------------------
DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"

print_info "Backing up /etc/ssh/sshd_config to .bkp ..."
backup_file "/etc/ssh/sshd_config"

print_info "Writing SSH bootstrap drop-in: $DROPIN"
sudo mkdir -p /etc/ssh/sshd_config.d

# Sanity: refuse accidental here-doc markers inside the env content
if grep -qE '(^|\n)EOF(\n|$)' <<<"${SSH_BOOTSTRAP_CONF:-}"; then
  print_error "SSH_BOOTSTRAP_CONF contains a stray EOF marker. Fix .env and rerun."
  exit 1
fi

if [[ -z "${SSH_BOOTSTRAP_CONF:-}" ]]; then
  print_error "SSH_BOOTSTRAP_CONF is empty in .env — cannot proceed."
  exit 1
fi

printf '%s\n' "$SSH_BOOTSTRAP_CONF" | sudo tee "$DROPIN" >/dev/null

print_info "Validating sshd config..."
if ! sudo sshd -t; then
  print_error "SSH config invalid. Aborting before reload."
  exit 1
fi

print_info "Reloading SSH with bootstrap settings..."
if sudo systemctl is-active --quiet ssh; then
  sudo systemctl reload ssh || sudo systemctl restart ssh
else
  print_info "Starting SSH service..."
  sudo systemctl start ssh
fi
print_success "SSH bootstrap applied."

# ----------------------------------------------------------------------------------
# Stage rename tool:
# - Install modules/user/change_name.sh into /root/change_name.sh (700, root:root)
# ----------------------------------------------------------------------------------
SRC_CHANGE="$MODULE_DIR/change_name.sh"
DST_CHANGE="/root/change_name.sh"

if [[ ! -f "$SRC_CHANGE" ]]; then
  print_error "change_name.sh not found in $MODULE_DIR"
  exit 1
fi

print_info "Staging $DST_CHANGE ..."
install -m 700 -o root -g root "$SRC_CHANGE" "$DST_CHANGE"
print_success "Ready: run /root/change_name.sh after reconnecting as root (port 42)."
print_success "User module bootstrap complete. Reconnect as root on port 42 and run: /root/change_name.sh"