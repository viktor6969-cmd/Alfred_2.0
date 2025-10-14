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
#   -h            print help and exit
#   (no args)     Interactive mode; UFW runs first if missing, then prompts per module
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

load_server_conf

# ----------------------------------------------------------------------------------
# Core: run_module (ask | force | reinstall)
# ----------------------------------------------------------------------------------

run_module() {
  local m="$1"
  local mode="${2:-ask}"  # ask | force | reinstall

  valid_module "$m" || { print_error "Invalid module name: $m"; exit 1; }
  module_exists "$m" || { print_error "Missing setup.sh for $m"; exit 1; }

  # Short-circuit if already installed
  if is_installed "$m" && [[ ! "$mode" == "reinstall" ]]; then
    read -rp "$m already installed. Reinstall with defaults? (y/N): " ans; echo
    [[ ! $ans =~ $YES_REGEX ]] && { print_info "Skipping $m"; return 0; }
  fi

  # Dependencies (only for new/reinstall)
  local dep
  while read -r dep; do
    [[ -z "$dep" || "$dep" =~ ^# || "$dep" =~ ^[Ee]mpty$ ]] && continue
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
  print_msg "Installing $m...\n"
  if bash "$MODULES_DIR/$m/"$m"_setup.sh"; then
    mark_installed "$m"
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
      print_msg "\e[33m%-12s\e[0m - %s\n" "$m" "$(module_desc "$m")"
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
    print_msg "Full auto installation (-y).\n"
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
    print_msg "** Interactive mode **\n"
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
