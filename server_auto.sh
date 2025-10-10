#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail

# ===================================================================================
# Server_auto entrypoint
# Modes:
#   -u            run only the user module, then exit (marks installed)
#   -y            run ALL modules except user, non-interactive; UFW runs only if not stamped
#   -l            list modules
#   -i <module>   show module info (description + requirements)
#   -h            print help (from utils)
#   (no args)     interactive: UFW runs silently if not installed; then ask per module (except user)
# Notes:
#   * user module is isolated and runs ONLY in -u mode.
#   * UFW is a prerequisite for network-facing modules; we also enforce dep order from requirements.txt
#   * Each module tracks install via modules/<name>/.installed.stamp
# ===================================================================================


# ----------------------------------------------------------------------------------
# ROOT DETECTION AND ENVIRONMENT
# ----------------------------------------------------------------------------------
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }

SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
UTILS_DIR="$ROOT_DIR/utils"
MODULES_DIR="$ROOT_DIR/modules"

# Load utilities
if [[ -f "$UTILS_DIR/utils.sh" ]]; then
  # shellcheck disable=SC1090
  source "$UTILS_DIR/utils.sh"
else
  echo "utils.sh not found!"; exit 1
fi

load_env

# ----------------------------------------------------------------------------------
# FUNCTIONS
# ----------------------------------------------------------------------------------

valid_module() { [[ "$1" =~ ^[a-z0-9_-]+$ ]]; }

discover_modules() {
  find "$MODULES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

module_exists() {
  [[ -x "$MODULES_DIR/$1/setup.sh" ]]
}

module_desc() {
  local f="$MODULES_DIR/$1/description.txt"
  [[ -f "$f" ]] && cat "$f" || echo "$1 module"
}

module_reqs() {
  local f="$MODULES_DIR/$1/requirements.txt"
  [[ -f "$f" ]] && tr ' ' '\n' < "$f" | sed '/^$/d'
}

# Execute one module with dependency awareness
run_module() {
  local m="$1"
  valid_module "$m" || { print_error "Invalid module name: $m"; exit 1; }
  module_exists "$m" || { print_error "Missing setup.sh for $m"; exit 1; }

  # Already installed -> ask to reinstall
  if is_installed "$m"; then
    read -rp "$m is already installed. Reinstall? (y/N): " ans; echo
    if [[ $ans =~ $YES_REGEX ]]; then
      print_info "Reinstalling $m..."
      rm -f "$MODULES_DIR/$m/.installed.stamp" 2>/dev/null || true
    else
      print_info "Skipping reinstall of $m."
      return 0
    fi
  fi

  # Resolve requirements (only for new/reinstall)
  local dep
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" == "user" ]] && { print_error "user cannot be a dependency"; exit 1; }
    if ! is_installed "$dep"; then
      print_info "Dependency '$dep' is not installed for module '$m'."
      read -rp "Do you want to install '$dep' now? (y/N): " ans; echo
      if [[ $ans =~ $YES_REGEX ]]; then
        run_module "$dep"
      else
        print_error "Cannot continue installing '$m' without '$dep'. Aborting."
        exit 1
      fi
    fi
  done < <(module_reqs "$m" || true)

  print_info "Installing $m..."
  bash "$MODULES_DIR/$m/setup.sh"
  exit_code=$?
  if (( exit_code == 0 )); then
    mark_installed "$m"
    print_success "$m installed successfully."
  else
    print_error "$m failed with exit code $exit_code."
    print_error "Module NOT marked as installed. Fix errors and rerun."
    exit "$exit_code"
  fi
}


# ----------------------------------------------------------------------------------
# MAIN LOGIC
# ----------------------------------------------------------------------------------

ARG1="${1:-}"

case "$ARG1" in
  -h)
    print_help
    exit 0
    ;;

  -l)
    echo "Available modules:"
    for m in $(discover_modules); do
      printf "  %-10s - %s\n" "$m" "$(module_desc "$m")"
    done
    exit 0
    ;;

  -i)
    mod="${2:-}"
    [[ -z "$mod" ]] && { print_error "Usage: $0 -i <module>"; exit 1; }
    valid_module "$mod" || { print_error "Invalid module name: $mod"; exit 1; }
    if module_exists "$mod"; then
      echo "Module: $mod"
      echo "Description: $(module_desc "$mod")"
      reqs="$(module_reqs "$mod" | tr '\n' ' ')"
      echo "Requires: ${reqs:-none}"
      if is_installed "$mod"; then
        echo "Status: \e[32m[installed]\e[0m"
      else
        echo "Status: \e[31m[not installed]\e[0m"
      fi
    else
      print_error "Module '$mod' not found."
    fi
    exit 0
    ;;

  -u)
    # Run only user module via the shared handler
    print_info "Running user module..."
    run_module "user"
    exit 0
    ;;

  -r)
    mod="${2:-}"
    [[ -z "$mod" ]] && { print_error "Usage: $0 -r <module>"; exit 1; }
    run_module "$mod"    
    exit 0
    ;;

  -y)
    print_info "Running full auto installation (-y mode)..."
    # Always start with UFW if not installed
    run_module "ufw"

    for m in $(discover_modules); do
      [[ "$m" == "ufw" || "$m" == "user" ]] && continue
      run_module "$m"
    done
    print_success "All modules installed successfully."
    exit 0
    ;;

  "")
    print_info "Interactive mode. (Press Enter for default 'no')"
    # Run UFW first if missing
    run_module "ufw"

    for m in $(discover_modules); do
      [[ "$m" == "ufw" || "$m" == "user" ]] && continue
      read -rp "Install module $m? (y/N): " ans; echo
      [[ $ans =~ $YES_REGEX ]] && run_module "$m" || print_info "Skipping $m."
    done

    print_success "Interactive installation complete."
    exit 0
    ;;

  *)
    print_error "Unknown option: $ARG1"
    print_help
    exit 1
    ;;
esac