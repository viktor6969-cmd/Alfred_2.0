#!/usr/bin/env bash

#================= Printing =================#
# Printing colors
INFO="\e[33m[!]\e[0m "
ERROR="\e[31m[-]\e[0m "
SUCCESS="\e[32m[+]\e[0m "
YES_REGEX="^([yY]|yes|YES|Yes|yep)$"

# Utility function to print info messages
print_info()    { printf "%b%s\n" "$INFO"    "$*"; }
# Utility function to print error messages
print_error()   { printf "%b%s\n" "$ERROR"   "$*"; }
# Utility function to print success messages
print_success() { printf "%b%s\n" "$SUCCESS" "$*"; }

print_help() { printf "help\n"; }

#=============== Global Vars ======================#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/.bkp"
mkdir -p "$BACKUP_DIR"

#=============== .env handling ====================#
ENV_FILE="$SCRIPT_DIR/.env"

# Basic security hardening for .env
ensure_env_security() {
  if [[ -e "$ENV_FILE" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      chown root:root "$ENV_FILE" 2>/dev/null || true
      chmod 600 "$ENV_FILE" 2>/dev/null || true
    fi
  fi
}

# .env file loader
load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    print_error "The .env file not found at: $ENV_FILE"
    exit 1
  fi
  ensure_env_security
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

#=============== Backups ==========================#
# Put all backups into .backups
backup_file() {
  # usage: backup_file /etc/ssh/sshd_config
  local src="$1"
  if [[ -z "${src:-}" || ! -r "$src" ]]; then
    print_error "Cannot read source file: $src"
    return 1
  fi
  local stamp base
  stamp="$(date +%Y%m%d-%H%M%S)"
  base="$(basename "$src")"
  cp "$src" "$BACKUP_DIR/$base.$stamp"
  print_success "Backed up $src -> $BACKUP_DIR/$base.$stamp"
}

