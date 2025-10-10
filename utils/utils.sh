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
CONFIG_DIR="$SCRIPT_DIR/config"
ENV_FILE="$CONFIG_DIR/.env"
ENV_TEMPLATE="$CONFIG_DIR/change_me.env"

BACKUP_DIR="$SCRIPT_DIR/.bkp"
mkdir -p "$BACKUP_DIR"

#=============== .env handling ====================#
ensure_env() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$ENV_TEMPLATE" ]]; then
      cp -n "$ENV_TEMPLATE" "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      chown root:root "$ENV_FILE" 2>/dev/null || true
      print_error "Created $ENV_FILE from template. Edit it and re-run."
      exit 1
    else
      print_error "Missing $ENV_FILE and no $ENV_TEMPLATE template. Aborting."
      exit 1
    fi
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  chown root:root "$ENV_FILE" 2>/dev/null || true
}

load_env() {
  ensure_env
  ensure_env_security()
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

# Basic security hardening for .env
ensure_env_security() {
  if [[ -e "$ENV_FILE" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      chown root:root "$ENV_FILE" 2>/dev/null || true
      chmod 600 "$ENV_FILE" 2>/dev/null || true
    fi
  fi
}

#=============== Module handling ====================#
MODULES_DIR="$SCRIPT_DIR/modules"

is_installed() { [[ -f "$MODULES_DIR/$1/.installed.stamp" ]]; }

mark_installed() {
  local m="$1" v ts
  v="$(cat "$MODULES_DIR/$m/version.txt" 2>/dev/null || echo unknown)"
  ts="$(date -Is)"
  printf 'name=%s\nversion=%s\ninstalled_at=%s\n' "$m" "$v" "$ts" \
    > "$MODULES_DIR/$m/.installed.stamp.tmp"
  mv "$MODULES_DIR/$m/.installed.stamp.tmp" "$MODULES_DIR/$m/.installed.stamp"
}

clear_installed() { rm -f "$MODULES_DIR/$1/.installed.stamp"; }



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

