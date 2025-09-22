#!/bin/bash

# ==================================================================================
# CHANGE NAME (rename user + revert SSH)
# ==================================================================================
# Expectations from you:
# - Run this after reconnecting as root (port 42) per init.sh instructions
# - This will rename 'ubuntu' -> $NEW_USERNAME and tighten SSH again
# ==================================================================================

set -euo pipefail

# Load utils and .env
SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_REAL")"

if [ -f "$SCRIPT_DIR/utils.sh" ]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/utils.sh"
else
  echo "utils.sh file not found next to change_name.sh"; exit 1
fi

load_env


# ------------------------------------------------------------------------------------
# Rename the default user and migrate home:
# - Rename 'ubuntu' to $NEW_USERNAME
# - Move home to /home/$NEW_USERNAME
# - Rename primary group to $NEW_USERNAME
# - Fix ownership
# ------------------------------------------------------------------------------------

# Change user name and home dir
print_info "Changing username from 'ubuntu' to '$NEW_USERNAME'..."
usermod -l "$NEW_USERNAME" ubuntu
usermod -d "/home/$NEW_USERNAME" -m "$NEW_USERNAME"
groupmod -n "$NEW_USERNAME" ubuntu

# Update file ownership
print_info "Updating ownership for /home/$NEW_USERNAME ..."
chown -R "$NEW_USERNAME:$NEW_USERNAME" "/home/$NEW_USERNAME"

# Set custom prompt
print_info "Applying custom prompt to $NEW_USERNAME ..."
printf "PS1='%s'\n" "$CUSTOM_PS1" >> "/home/$NEW_USERNAME/.bashrc"

# ------------------------------------------------------------------------------------
# Revert SSH from bootstrap:
# - Remove temporary drop-in (root login + port settings)
# - Install final drop-in with Port 42 and root login disabled
# - Validate and reload SSH
# ------------------------------------------------------------------------------------
DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"

print_info "Backing up /etc/ssh/sshd_config to .backups ..."
backup_file "/etc/ssh/sshd_config"

print_info "Restoring SSH to original settings..."
if [ -f "$DROPIN" ]; then
    sudo rm -f "$DROPIN"
    print_info "Removed $DROPIN"
fi

# Create secure SSH configuration
SECURE_DROPIN="/etc/ssh/sshd_config.d/99-secure.conf"
print_info "Creating secure SSH configuration: $SECURE_DROPIN"
printf '%s\n' "$SSH_SECURE_CONF" | sudo tee "$SECURE_DROPIN" >/dev/null
print_success "Created secure SSH configuration: $SECURE_DROPIN"

# Validate SSH config before reloading
print_info "Validating sshd config..."
if sudo sshd -t; then
    print_info "Reloading SSH with current settings..."
    if sudo systemctl is-active --quiet ssh; then
        sudo systemctl reload ssh || sudo systemctl restart ssh
    else
        print_info "Starting SSH service..."
        sudo systemctl start ssh && print_success "SSH configs updated successfully"
    fi
else
    print_error "SSH config invalid. Aborting before reload."
    exit 1
fi


# ------------------------------------------------------------------------------------
# Set a new root password (interactive, with confirmation)
# ------------------------------------------------------------------------------------
print_info "Setting a new root password..."
while true; do
  printf "Please enter new root password: "
  read -r -s password1
  echo
  printf "Please confirm new root password: "
  read -r -s password2
  echo

  if [ "$password1" != "$password2" ]; then
    print_error "Passwords do not match. Try again."
    continue
  fi

  if printf 'root:%s\n' "$password1" | chpasswd; then
    print_success "Root password successfully changed."
    break
  else
    print_error "Failed to set password. Please try again."
  fi
done

# ------------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------------

echo "Cleaning up..."
rm -f /root/change_name.sh

print_success "User change complete!"
print_info "Please reconnect using ssh as $NEW_USERNAME"