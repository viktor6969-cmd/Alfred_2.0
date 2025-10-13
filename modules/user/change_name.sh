#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# CHANGE NAME — rename default user and revert SSH hardening
# ==================================================================================
# Expectations:
# - Run this AFTER reconnecting as root (port 42) per user module bootstrap
# - Renames 'ubuntu' -> $NEW_USERNAME and restores secure SSH settings
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

load_env

# ------------------------------------------------------------------------------------
# Rename the default user and migrate home:
# - Check that 'ubuntu' exists and $NEW_USERNAME does not
# - Rename 'ubuntu' to $NEW_USERNAME; move home; rename primary group
# - Fix ownership; append custom prompt
# ------------------------------------------------------------------------------------

SOURCE_USER="ubuntu"
if ! id "$SOURCE_USER" >/dev/null 2>&1; then
  print_info "Default user '$SOURCE_USER' not found."
  read -rp "Do you want to rename a different user? (y/N): " ans; echo
  [[ $ans =~ $YES_REGEX ]] || { print_error "Nothing to rename. Aborting."; exit 1; }
  while true; do
    read -rp "Enter existing username to rename (not 'root'): " SOURCE_USER
    [[ -z "$SOURCE_USER" ]] && { print_error "Empty username."; continue; }
    [[ "$SOURCE_USER" == "root" ]] && { print_error "Refusing to rename 'root'."; continue; }
    id "$SOURCE_USER" >/dev/null 2>&1 && break
    print_error "User '$SOURCE_USER' not found. Try again."
  done
fi

[[ -n "${NEW_USERNAME:-}" ]] || { print_info "The defoult username value in .env is empty!";}
# id -u "$NEW_USERNAME" >/dev/null 2>&1 && { print_error "User '$NEW_USERNAME' already exists."; exit 1; }
# getent group "$NEW_USERNAME" >/dev/null && { print_error "Group '$NEW_USERNAME' already exists."; exit 1; }

print_info "Changing username from '$SOURCE_USER' to '$NEW_USERNAME'..."
usermod -l "$NEW_USERNAME" "$SOURCE_USER" || { print_error "usermod rename failed."; exit 1; }
usermod -d "/home/$NEW_USERNAME" -m "$NEW_USERNAME"
groupmod -n "$NEW_USERNAME" "$SOURCE_USER" || true   # group may not exist with same name; ignore if so
chown -R "$NEW_USERNAME:$NEW_USERNAME" "/home/$NEW_USERNAME"

# ------------------------------------------------------------------------------------
# Optional root password change (prompted):
# - Ask user if they want to set a new root password now
# - If yes and .env has ROOT_PASSWORD, offer to use it; otherwise prompt (double-check)
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
      echo -i "Entering interactive password setup..."
      while true; do
        read -srp "Enter new root password: " _p1; echo
        read -srp "Confirm new root password: " _p2; echo
        if [[ -z "$_p1" || -z "$_p2" ]]; then
          print_error "Password cannot be empty."; continue
        fi
        if [[ "$_p1" != "$_p2" ]]; then
          print_error "Passwords do not match."; continue
        fi
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
      if [[ -z "$_p1" || -z "$_p2" ]]; then
        print_error "Password cannot be empty."; continue
      fi
      if [[ "$_p1" != "$_p2" ]]; then
        print_error "Passwords do not match."; continue
      fi
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
# Revert SSH from bootstrap to secure:
# - Remove temporary drop-in (root login / permissive settings)
# - Install final drop-in from $SSH_SECURE_CONF
# - Validate and reload SSH
# ------------------------------------------------------------------------------------
DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"

echo -i "Backing up /etc/ssh/sshd_config to .bkp ..."
backup_file "/etc/ssh/sshd_config"

echo -i "Restoring SSH to secure settings..."
if [[ -f "$DROPIN" ]]; then
  sudo rm -f "$DROPIN"
fi

SECURE_DROPIN="/etc/ssh/sshd_config.d/99-secure.conf"
echo -i "Creating secure SSH configuration: $SECURE_DROPIN"
if [[ -z "${SSH_SECURE_CONF:-}" ]]; then
  print_error "SSH_SECURE_CONF is empty in .env — cannot proceed."
  exit 1
fi
printf '%s\n' "$SSH_SECURE_CONF" | sudo tee "$SECURE_DROPIN" >/dev/null
print_success "Created secure SSH configuration: $SECURE_DROPIN"

echo -i "Validating sshd config..."
if ! sudo sshd -t; then
  print_error "SSH config invalid. Aborting before reload."
  exit 1
fi

echo -i "Reloading SSH with secure settings..."
if sudo systemctl is-active --quiet ssh; then
  sudo systemctl reload ssh || sudo systemctl restart ssh
else
  echo -i "Starting SSH service..."
  sudo systemctl start ssh
fi
print_success "SSH secured."

# ------------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------------
echo -i "Cleaning up..."
rm -f /root/change_name.sh || true

print_success "User change complete!"
print_info "Reconnect using: ssh $NEW_USERNAME@<host>"
