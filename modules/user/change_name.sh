#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# CHANGE NAME — rename default user and revert SSH hardening
# ==================================================================================
# Expectations:
# - Run AFTER reconnecting as root on bootstrap port (from server.conf)
# - Renames 'ubuntu' -> $NEW_USERNAME (from .env) and restores secure SSH settings
# ==================================================================================

# ----------------------------------------------------------------------------------
# Locate project root + utils
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
  echo "utils.sh not found at $UTILS_DIR/utils.sh"; exit 1
fi

# Load secrets (.env) and server.conf scalars/templates
load_env
load_server_conf

# ------------------------------------------------------------------------------------
# Rename the default user and migrate home:
# - Check that 'ubuntu' exists and $NEW_USERNAME does not
# - Rename 'ubuntu' to $NEW_USERNAME; move home; rename primary group
# - Fix ownership; append custom prompt (optional)
# ------------------------------------------------------------------------------------
id ubuntu >/dev/null 2>&1 || { print_error "User 'ubuntu' not found."; exit 1; }
[[ -n "${NEW_USERNAME:-}" ]] || { print_error "NEW_USERNAME is empty (from .env)."; exit 1; }
id -u "$NEW_USERNAME" >/dev/null 2>&1 && { print_error "User '$NEW_USERNAME' already exists."; exit 1; }
getent group "$NEW_USERNAME" >/dev/null && { print_error "Group '$NEW_USERNAME' already exists."; exit 1; }

print_info "Changing username from 'ubuntu' to '$NEW_USERNAME'..."
usermod -l "$NEW_USERNAME" ubuntu || { print_error "usermod rename failed."; exit 1; }
usermod -d "/home/$NEW_USERNAME" -m "$NEW_USERNAME"
groupmod -n "$NEW_USERNAME" ubuntu

print_info "Fixing ownership for /home/$NEW_USERNAME ..."
chown -R "$NEW_USERNAME:$NEW_USERNAME" "/home/$NEW_USERNAME"

# Optional PS1 from .env
if [[ -n "${CUSTOM_PS1:-}" ]]; then
  print_info "Applying custom prompt to $NEW_USERNAME ..."
  printf '%s\n' "PS1=${CUSTOM_PS1@Q}" >> "/home/$NEW_USERNAME/.bashrc"
fi

# ------------------------------------------------------------------------------------
# Optional root password change (prompted)
# ------------------------------------------------------------------------------------
read -rp "Do you want to set a NEW root password now? (y/N): " _chg; echo
if [[ $_chg =~ $YES_REGEX ]]; then
  if [[ -n "${ROOT_PASSWORD:-}" ]]; then
    read -rp "Use default ROOT_PASSWORD from .env? (y/N): " _use_env; echo
    if [[ $_use_env =~ $YES_REGEX ]]; then
      print_info "Setting root password from .env..."
      if printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd; then
        print_success "Root password updated from .env."
      else
        print_error "Failed to set root password from .env."; exit 1
      fi
    else
      print_info "Interactive password setup..."
      while true; do
        read -srp "Enter new root password: " _p1; echo
        read -srp "Confirm new root password: " _p2; echo
        [[ -z "$_p1" || -z "$_p2" ]] && { print_error "Password cannot be empty."; continue; }
        [[ "$_p1" != "$_p2" ]] && { print_error "Passwords do not match."; continue; }
        if printf 'root:%s\n' "$_p1" | chpasswd; then
          print_success "Root password updated."
          unset _p1 _p2
          break
        else
          print_error "Failed to set password. Try again."
        fi
      done
    fi
  else
    print_info "No ROOT_PASSWORD in .env — interactive setup..."
    while true; do
      read -srp "Enter new root password: " _p1; echo
      read -srp "Confirm new root password: " _p2; echo
      [[ -z "$_p1" || -z "$_p2" ]] && { print_error "Password cannot be empty."; continue; }
      [[ "$_p1" != "$_p2" ]] && { print_error "Passwords do not match."; continue; }
      if printf 'root:%s\n' "$_p1" | chpasswd; then
        print_success "Root password updated."
        unset _p1 _p2
        break
      else
        print_error "Failed to set password. Try again."
      fi
    done
  fi
else
  print_info "Skipping root password change."
fi

# ------------------------------------------------------------------------------------
# Revert SSH from bootstrap to secure using server.conf
# ------------------------------------------------------------------------------------
print_info "Backing up /etc/ssh/sshd_config to .bkp ..."
backup_file "/etc/ssh/sshd_config"

print_info "Restoring SSH to secure settings from [ssh.secure]..."
DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
[[ -f "$DROPIN" ]] && { rm -f "$DROPIN"; print_info "Removed $DROPIN"; }

write_ssh_secure

print_info "Validating sshd config..."
if ! sshd -t; then
  print_error "SSH config invalid. Aborting before reload."
  exit 1
fi

print_info "Reloading SSH with secure settings..."
if systemctl is-active --quiet ssh; then
  systemctl reload ssh || systemctl restart ssh
else
  print_info "Starting SSH service..."
  systemctl start ssh
fi
print_success "SSH secured (port ${SSH_PORT_FINAL})."

# ------------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------------
print_info "Cleaning up..."
rm -f /root/change_name.sh || true

print_success "User change complete!"
print_info "Reconnect using: ssh $NEW_USERNAME@<host> -p ${SSH_PORT_FINAL}"
