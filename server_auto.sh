#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# SERVER_AUTO — main entrypoint for modular server setup automation
# ==================================================================================
# Usage:
#   -y            Install all modules (no questions). UFW runs first if missing.
#   -u            Run only the user module
#   -r <module>   Install/reinstall a specific module (prompts if already installed)
#   -l            List all modules with descriptions
#   -i <module>   Show module description + installed status
#   -h            Print help
#
# Notes:
#   • Run as root (sudo).
#   • Install stamps live in /var/lib/serverctl/modules/<module>.stamp
#   • Modules are discovered under ./modules/<name>/setup.sh
#   • Config: ./config/server.conf (INI-style), parsed by utils.sh
# ==================================================================================

# ----------------------------------------------------------------------------------
# Root & paths
# ----------------------------------------------------------------------------------
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }

SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
UTILS_DIR="$ROOT_DIR/utils"
MODULES_DIR="$ROOT_DIR/modules"

# ----------------------------------------------------------------------------------
# Utilities
# ----------------------------------------------------------------------------------
if [[ -f "$UTILS_DIR/utils.sh" ]]; then
  # shellcheck disable=SC1090
  source "$UTILS_DIR/utils.sh"
else
  echo "utils.sh not found at $UTILS_DIR/utils.sh" >&2
  exit 1
fi

# Load .env (secrets) and server.conf (scalars/blocks)
load_env
load_server_conf

# ----------------------------------------------------------------------------------
# Helpers (module discovery / info)
# ----------------------------------------------------------------------------------
valid_module() { [[ "$1" =~ ^[a-z0-9_-]+$ ]]; }

discover_modules() {
  find "$MODULES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

module_exists() { [[ -x "$MODULES_DIR/$1/setup.sh" ]]; }

module_desc() {
  [[ -f "$MODULES_DIR/$1/description.txt" ]] && cat "$MODULES_DIR/$1/description.txt" || echo "$1 module"
}

module_reqs() {
  local f="$MODULES_DIR/$1/requirements.txt"
  [[ -f "$f" ]] || return 0
  tr ' ' '\n' < "$f" | sed '/^$/d'
}

# ----------------------------------------------------------------------------------
# Core: run_module (ask | force | reinstall)
# ----------------------------------------------------------------------------------
run_module() {
  local m="$1"
  local mode="${2:-ask}"  # ask | force | reinstall

  valid_module "$m" || { print_error "Invalid module name: $m"; exit 1; }
  module_exists "$m" || { print_error "Missing setup.sh for $m"; exit 1; }

  # Short-circuit if already installed
  if is_installed "$m"; then
    case "$mode" in
      force)
        print_info "$m already installed, skipping..."
        return 0
        ;;
      reinstall)
        print_info "Reinstalling $m..."
        clear_installed "$m"
        ;;
      ask)
        read -rp "$m already installed. Reinstall with defaults? (y/N): " _ans; echo
        if [[ ! $_ans =~ $YES_REGEX ]]; then
          print_info "Skipping $m."
          return 0
        fi
        clear_installed "$m"
        ;;
    esac
  fi

  # Dependencies (only for new/reinstall)
  local dep
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" == "user" ]] && { print_error "user cannot be a dependency"; exit 1; }

    if ! is_installed "$dep"; then
      if [[ "$mode" == "force" || "$mode" == "reinstall" ]]; then
        run_module "$dep" "force"
      else
        print_info "Dependency '$dep' is not installed for module '$m'."
        read -rp "Install '$dep' now? (y/N): " ans; echo
        [[ $ans =~ $YES_REGEX ]] || { print_error "Cannot continue installing '$m' without '$dep'."; exit 1; }
        run_module "$dep" "ask"
      fi
    fi
  done < <(module_reqs "$m" || true)

  # Execute module
  print_info "Installing $m..."
  if bash "$MODULES_DIR/$m/setup.sh"; then
    mark_installed "$m"
    print_success "$m installed successfully."
  else
    local ec=$?
    print_error "$m failed with exit code $ec."
    print_error "Module NOT marked as installed. Fix errors and rerun."
    exit "$ec"
  fi
}

# ----------------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------------
ARG1="${1:-}"

case "$ARG1" in
  -h)
    print_help; exit 0 ;;

  -l)
    echo "Available modules:"
    for m in $(discover_modules); do
      printf "  %-12s - %s\n" "$m" "$(module_desc "$m")"
    done
    exit 0 ;;

  -i)
    mod="${2:-}"
    [[ -n "$mod" ]] || { print_error "Usage: $0 -i <module>"; exit 1; }
    valid_module "$mod" || { print_error "Invalid module name: $mod"; exit 1; }
    if module_exists "$mod"; then
      echo "Module: $mod"
      echo "Description: $(module_desc "$mod")"
      reqs="$(module_reqs "$mod" | tr '\n' ' ')"
      echo "Requires: ${reqs:-none}"
      if is_installed "$mod"; then
        printf "Status: \e[32m[installed]\e[0m\n"
      else
        printf "Status: \e[31m[not installed]\e[0m\n"
      fi
    else
      print_error "Module '$mod' not found."
      exit 1
    fi
    exit 0 ;;

  -u)
    print_info "Running user module..."
    run_module "user" "ask"
    exit 0 ;;

  -r)
    mod="${2:-}"
    [[ -n "$mod" ]] || { print_error "Usage: $0 -r <module>"; exit 1; }
    valid_module "$mod" || { print_error "Invalid module name: $mod"; exit 1; }
    module_exists "$mod" || { print_error "Module '$mod' not found"; exit 1; }
    run_module "$mod" "reinstall"
    exit 0 ;;

  -y)
    print_info "Full auto installation (-y)."
    # UFW first if missing
    if ! is_installed "ufw"; then
      run_module "ufw" "force"
    else
      print_info "The UFW module is already installed."
      read -rp "Do you want to reinstall it now? (y/N): " ans; echo
      if [[ $ans =~ $YES_REGEX ]]; then
        run_module "ufw" "force"
      else
        print_info "Skipping UFW module"
      fi
    fi
    for m in $(discover_modules); do
      [[ "$m" == "ufw" || "$m" == "user" ]] && continue
      run_module "$m" "force"
    done
    print_success "All modules installed (-y)."
    exit 0 ;;

  "")
    print_info "Interactive mode."
    # UFW first if missing
    if ! is_installed "ufw"; then
      run_module "ufw" "ask"
    else
      print_info "UFW already installed — skipping."
    fi
    for m in $(discover_modules); do
      [[ "$m" == "ufw" || "$m" == "user" ]] && continue
      run_module "$m" "ask"
    done
    print_success "Interactive installation complete."
    exit 0 ;;

  *)
    print_error "Unknown option: $ARG1"
    print_help
    exit 1 ;;
esac
