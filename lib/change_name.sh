#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# CHANGE NAME — modular user/SSH/root password changes
# ==================================================================================
# Usage:
#   ./change_name.sh [-d]
#   -d    Run all steps without prompting for confirmation
# ==================================================================================

SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_REAL")/../.." && pwd)"
UTILS_DIR="$ROOT_DIR/utils"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }

if [[ -f "$UTILS_DIR/utils.sh" ]]; then
  # shellcheck disable=SC1090
  source "$UTILS_DIR/utils.sh"
else
  echo "utils.sh not found at $UTILS_DIR/utils.sh"; exit 1
fi

load_server_conf
load_env

AUTO_RUN=false
if [[ $# -eq 0 ]]; then
  # No arguments: interactive mode
  AUTO_RUN=false
else
  case "${1:-}" in
    -d) AUTO_RUN=true ;;
    -h) printf "Usage : %s [-d]\n  -d    Run all steps without prompting for confirmation\n" "$0"; exit 0 ;;
    "") ;;
    *) print_error "Unknown argument: $1"; exit 1 ;;
  esac
fi

change_root_pass() {

  if [[ -n "${ROOT_PASSWORD:-}" ]]; then
    read -rp "Would you like to CREATE a new root password?(Strongly recomended)\n [Using .env password by default] (Y/n): " _new_pass; echo
    if [[ $_new_pass =~ $YES_REGEX ]]; then
      # Interactive password setup
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
      return
    else
      print_info "Setting root password from .env..."
      if printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd; then
        print_success "Root password updated from .env."
      else
        print_error "Failed to set root password from .env."; exit 1
      fi
      return
    fi
  fi
}

update_ssh() {

  DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
  printf "Backing up /etc/ssh/sshd_config to .bkp ..."
  backup_file "/etc/ssh/sshd_config"

  printf "Restoring SSH to secure settings..."
  if [[ -f "$DROPIN" ]]; then
    sudo rm -f "$DROPIN"
  fi

  SECURE_DROPIN="/etc/ssh/sshd_config.d/99-secure.conf"
  printf "Creating secure SSH configuration: $SECURE_DROPIN"
  if [[ -z "${SSH_SECURE_CONF:-}" ]]; then
    print_error "SSH_SECURE_CONF is empty in .env — cannot proceed."
    exit 1
  fi
  printf '%s\n' "$SSH_SECURE_CONF" | sudo tee "$SECURE_DROPIN" >/dev/null
  print_success "Created secure SSH configuration: $SECURE_DROPIN"

  printf "Validating sshd config..."
  if ! sudo sshd -t; then
    print_error "SSH config invalid. Aborting before reload."
    exit 1
  fi

  printf "Reloading SSH with secure settings..."
  if sudo systemctl is-active --quiet ssh; then
    sudo systemctl reload ssh || sudo systemctl restart ssh
  else
    printf "Starting SSH service..."
    sudo systemctl start ssh
  fi
  print_success "SSH secured."
}

change_username() {
  SOURCE_USER="${DEFAULT_USER:-ubuntu}"

  # Ask which user to rename
  if id "$SOURCE_USER" >/dev/null 2>&1; then
    read -rp "Do you want to rename the default user '$SOURCE_USER'? (y/N): " ans; echo
    if ! [[ $ans =~ $YES_REGEX ]]; then
      while true; do
        read -rp "Enter existing username to rename (not 'root'): " input_user
        [[ -z "$input_user" ]] && { print_error "Empty username."; continue; }
        [[ "$input_user" == "root" ]] && { print_error "Refusing to rename 'root'."; continue; }
        if id "$input_user" >/dev/null 2>&1; then
          SOURCE_USER="$input_user"
          break
        fi
        print_error "User '$input_user' not found. Try again."
      done
    fi
  else
  print_info "Default user '$SOURCE_USER' not found."
    while true; do
      read -rp "Enter existing username to rename (not 'root'): " input_user
      [[ -z "$input_user" ]] && { print_error "Empty username."; continue; }
      [[ "$input_user" == "root" ]] && { print_error "Refusing to rename 'root'."; continue; }
      if id "$input_user" >/dev/null 2>&1; then
        SOURCE_USER="$input_user"
        break
      fi
      print_error "User '$input_user' not found. Try again."
    done
  fi

  # Ask for target username
  while true; do
    read -rp "Do you want to use the default target username ('$NEW_USERNAME')? (y/N): " ans; echo
    if [[ $ans =~ $YES_REGEX ]]; then
      TARGET_USER="$NEW_USERNAME"
    else
      read -rp "Enter new username: " TARGET_USER
      [[ -z "$TARGET_USER" ]] && { print_error "Empty username."; continue; }
    fi
    [[ "$TARGET_USER" == "$SOURCE_USER" ]] && { print_error "New username cannot be the same as source."; continue; }
    if id "$TARGET_USER" >/dev/null 2>&1; then
      print_error "Target username '$TARGET_USER' already exists. Try another."
      continue
    fi
    break
  done

  read -rp "Do you want to change '$SOURCE_USER' to '$TARGET_USER? (y/N): " ans; echo
    if [[ $ans =~ $YES_REGEX ]]; then
      TARGET_USER="$NEW_USERNAME"
    else
  print_info "Changing username from '$SOURCE_USER' to '$TARGET_USER'..."
  usermod -l "$TARGET_USER" "$SOURCE_USER" || { print_error "usermod rename failed."; exit 1; }
  usermod -d "/home/$TARGET_USER" -m "$TARGET_USER"
  groupmod -n "$TARGET_USER" "$SOURCE_USER" || true
  chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER"
  print_success "User change complete!"
  print_info "Reconnect using: ssh $TARGET_USER@<host>"
}

main() {

  if $AUTO_RUN; then
  
    change_root_pass
    update_ssh
    change_username

  else

    read -rp "Do you want to change the root password ? (y/N): " _chg; echo
    [[ $_chg =~ $YES_REGEX ]] && change_root_pass || print_info "Skipping root password change."


    read -rp "Do you want to restore secure SSH settings? (y/N): " _chg; echo
    [[ $_chg =~ $YES_REGEX ]] && update_ssh || print_info "Skipping SSH update."
    
    read -rp "Do you want to rename a user? (y/N): " _chg; echo
    [[ $_chg =~ $YES_REGEX ]] && change_username || print_info "Skipping user rename."
  
  fi

  echo "Cleaning up...\n"
  rm -f /root/change_name.sh || true
}

main