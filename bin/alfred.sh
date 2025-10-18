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

# =================================================================================
# Module management functions
# =================================================================================

run_module() {   # $1 {module name} $2 { ask | force }
  local m="${1//[^a-zA-Z0-9_-]/}"  # Sanitize module name
  local mode="${2:-ask}"

  valid_module "$m" || { print_error "Invalid module name: $m"; exit 1; }
  module_exists "$m" || { print_error "Missing setup.sh for $m"; exit 1; }


  if [[ "$mode" == "ask" ]]; then
    if is_installed "$m"; then
      read -rp "$m already installed. Reinstall with defaults? (y/N): " ans; echo
      [[ ! $ans =~ $YES_REGEX ]] && { print_info "Skipping $m"; return 0; }
    else
      read -rp "Install the $m module? (y/N): " ans; echo
      [[ ! $ans =~ $YES_REGEX ]] && { print_info "Skipping $m"; return 0; }
    fi
  fi

  # Clear install stamp if reinstalling
  clear_installed "$m"

  install_module_dep "$m" "$mode" || { print_error "Failed to install dependencies for $m"; return 1; }

  # Execute module
  print_msg "Installing $m...\n"
  local script_path="$MODULES_DIR/$m/${m}_setup.sh"
  [[ -f "$script_path" ]] || { print_error "Script not found: $script_path"; return 1; }
  if ! bash "$script_path"; then
      local ec=$?
      print_error "$m failed with exit code $ec"
      return $ec
  fi
  mark_installed "$m"
}

module_reqs() {
  local f="$MODULES_DIR/$1/requirements.txt"
  [[ -f "$f" ]] || return 0
  awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {print $0}' "$f"
}

install_module_dep() {  # $1 module, $2 ask|force
  local m="$1" mode="${2:-ask}" f="$MODULES_DIR/$m/packages.txt" pkg
  [[ -f "$f" ]] || return 0
  if [[ "$mode" != "force" ]]; then
    print_info "The $m module needs the following packages:"
    sed -E '/^[[:space:]]*(#|$)/d' "$f" | sed 's/^/  - /'
    read -rp "Install them now? (y/N): " ans; echo
    [[ $ans =~ $YES_REGEX ]] || { print_error "Skipping $m due to missing packages."; return 1; }
  fi
  apt-get -qq update
  while read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    dpkg -s "$pkg" &>/dev/null && continue
    apt-get -qq install -y "$pkg" || { print_error "Failed to install '$pkg'"; return 1; }
  done < "$f"
}


sanitize_module_name() {
    local name="${1//[^a-zA-Z0-9_-]/}"
    echo "$name"
}

# Validate module name (alphanumeric, _, -)
valid_module()      { [[ "$1" =~ ^[a-z0-9_-]+$ ]]; }

# Check if module setup.sh exists
module_exists()     { [[ -f "$MODULES_DIR/$1/"$1"_setup.sh" ]]; }

# Read module description
module_desc()       { [[ -f "$MODULES_DIR/$1/description.txt" ]] && cat "$MODULES_DIR/$1/description.txt" || echo "$1 module";}

# Check if module is installed
is_installed()      { [[ -f "$MODULES_DIR/$1/.installed" ]]; }

# Add installed stamp
mark_installed()    { printf 'Installed: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$MODULES_DIR/$1/.installed"; }

# List available modules
discover_modules()  { find "$MODULES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort ;}

# Clear installed stamp
clear_installed()   { rm -f "$MODULES_DIR/$1/.installed"; }

# =================================================================================
# Case managment functions
# =================================================================================

list_modules() {
  echo "Available modules:"
  for m in $(discover_modules); do
    printf "%-12s : %s\n" "$m" "$(module_desc "$m")"
  done
}

print_module_info() { # $1 {module name}
  local mod="$1"
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
}

handle_auto_mode() {
  print_msg "Full auto installation (-y).\n"
  for m in $(discover_modules); do
    [[ "$m" == "user" ]] && continue
    print_msg "Installing module: $m"
    run_module "$m" "force" || { print_error "Module $m installation failed."; return 1; }
  done
  print_success "Auto installation complete."
  return 0
}

handle_interactive_mode() {
  for m in $(discover_modules); do
    [[ "$m" == "user" ]] && continue
    
    read -rp "Install the $m module? (y/N): " ans; echo
    if [[ $ans =~ $YES_REGEX ]]; then
        if ! run_module "$m" "ask"; then
            print_error "Module $m installation failed. Skipping."
        fi
    fi
  done
  print_success "Interactive installation complete."
}

handle_dark_mode() {
  #Add an iptables rule to block all incoming connections including ssh and ICMP (ping)
    print_info "*** WARNING ***\nThis action will overwrite curent UFW rules and settings!\n Block all incoming connections (Exept the master ip) including ssh and ICMP (ping), and the server will apear dead to the outside world."
    print_info "Make sure to secure access to the server via console or other means before proceeding."
    read -rp "Are you sure you want to continue? (y/N): " ans; echo
    if [[ $ans =~ $YES_REGEX ]]; then
      print_msg "Activating dark mode..."
      if ! is_installed "ufw"; then
        print_info "The UFW module is not installed. Installing it first..."
        run_module "ufw" "force"
      fi
      print_success "Bravo six go dark"
    fi
}

handle_unexpected_error() {
    local exit_code=$?
    print_error "Unexpected error occurred (line: ${BASH_LINENO[0]}). Exiting."
    exit $exit_code
}
# =================================================================================
# Main function
# =================================================================================
main() {
  local exit_code=0
  local arg1="${1:-}"

  case "$arg1" in
    -h)     print_help; exit_code=0 ;;
    -l)     list_modules; exit_code=0 ;;
    -y)     handle_auto_mode; exit_code=$?;;
    -u)     run_module "user" "ask"; exit_code=0 ;;
    "")     handle_interactive_mode; exit_code=$? ;;
    -i)     print_module_info "${2:-}"; exit_code=0 ;;
    -r)     run_module "$(sanitize_module_name "${2:-}")" "force"; exit_code=$?;;
    -dark)  handle_dark_mode; exit_code=$?;; 
    *)      print_error "Unknown option: $arg1"; print_help; exit_code=1;;
  esac

  return $exit_code
}

# ==================================================================================
# EXECUTION GUARD & CLEANUP
# ==================================================================================

# Only run main if script is executed, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Set up error trapping
    trap 'handle_unexpected_error' ERR
    
    # Execute main with all arguments
    main "$@"
    exit_code=$?
    
    # Final exit with proper code
    exit $exit_code
fi