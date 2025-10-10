#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# UFW MODULE — baseline firewall configuration
# ==================================================================================
# Expectations:
# - Self-contained module called by server_auto.sh
# - Loads config from config/.env (via utils.sh)
# - This script:
#     1) Installs UFW + required packages
#     2) Applies default policies and master IP allow-list
#     3) Loads custom UFW profiles from .env (optional)
#     4) Enables UFW non-interactively and configures logging
#     5) (Optional) Configures knockd if requested
#     6) (Optional) Enables unattended-upgrades
# ==================================================================================

# ----------------------------------------------------------------------------------
# Locate project root and utils
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
  echo "utils.sh not found at $UTILS_DIR/utils.sh" >&2
  exit 1
fi

load_env

# ----------------------------------------------------------------------------------
# Validate required environment variables (keep names as in your .env)
# ----------------------------------------------------------------------------------
required_vars=("UFW_PACKAGES" "UFW_DEFAULT_INCOMING" "UFW_DEFAULT_OUTGOING" "MASTER_IP")
for var in "${required_vars[@]}"; do
  [[ -n "${!var:-}" ]] || { print_error "Missing required var in .env: $var"; exit 1; }
done

# ----------------------------------------------------------------------------------
# Install packages
# ----------------------------------------------------------------------------------
print_info "The following packages will be installed: ${UFW_PACKAGES}"
read -rp "Do you want to proceed with installation? (y/N): " ans; echo
if [[ $ans =~ $YES_REGEX ]]; then
  print_info "Updating apt cache..."
  apt-get update -y

  print_info "Installing packages..."
  apt-get install -y ${UFW_PACKAGES}
  print_success "Packages installed successfully."
else
  print_info "Skipping package installation as per user choice."
fi


# ----------------------------------------------------------------------------------
# Configure UFW defaults and master IP
# ----------------------------------------------------------------------------------
print_info "Configuring UFW default policies..."
ufw --force reset >/dev/null 2>&1 || true   # start clean, ignore if first run
ufw default "${UFW_DEFAULT_INCOMING}" incoming
ufw default "${UFW_DEFAULT_OUTGOING}" outgoing

print_info "Whitelisting master IP: ${MASTER_IP}"
ufw allow from "${MASTER_IP}"

# ----------------------------------------------------------------------------------
# Add custom UFW application profiles (optional)
# ----------------------------------------------------------------------------------
apps_dir="/etc/ufw/applications.d"
custom_file="${apps_dir}/custom-profiles.conf"
mkdir -p "$apps_dir"

added_profiles=0
if declare -p CUSTOM_UFW_PROFILES >/dev/null 2>&1; then
  print_info "Adding custom UFW profiles from .env variables (CUSTOM_UFW_PROFILES)..."
  : > "$custom_file.tmp" # Empty the temp file 
  for varname in "${CUSTOM_UFW_PROFILES[@]}"; do 
    if [[ -n "${!varname:-}" ]]; then
      printf '%s\n' "${!varname}" >> "$custom_file.tmp"
      added_profiles=1
    else
      print_error "Variable '$varname' listed in CUSTOM_UFW_PROFILES is empty or missing."
      exit 1
    fi
  done
  if (( added_profiles )); then
    mv -f "$custom_file.tmp" "$custom_file"
    print_success "Custom profiles written to: $custom_file"
  else
    rm -f "$custom_file.tmp" 2>/dev/null || true
  fi
elif [[ -n "${CUSTOM_UFW_PROFILE_TEXT:-}" ]]; then
  print_info "Adding custom UFW profiles from CUSTOM_UFW_PROFILE_TEXT..."
  printf '%s\n' "$CUSTOM_UFW_PROFILE_TEXT" > "$custom_file"
  print_success "Custom profiles written to: $custom_file"
else
  print_info "No custom UFW profiles defined; skipping."
fi

# ----------------------------------------------------------------------------------
# Enable UFW and configure logging
# ----------------------------------------------------------------------------------
print_info "Enabling UFW (non-interactive)..."
ufw --force enable

print_info "Configuring UFW logging via rsyslog..."
# Create/replace config to send UFW kernel messages to /var/log/ufw.log
rsys_conf="/etc/rsyslog.d/20-ufw.conf"
cat > "$rsys_conf" <<'RSYS'
# Log kernel-generated UFW messages to a dedicated file
:msg, contains, "[UFW " /var/log/ufw.log
& stop
RSYS
systemctl restart rsyslog

# ----------------------------------------------------------------------------------
# Optional: Port knocking (knockd)
# ----------------------------------------------------------------------------------
# .env options supported:
#   * KNOCKED_PROFILE : array of variable NAMES whose values are appended to /etc/knockd.conf
#   * KNOCKD_CONF_TEXT: literal multi-line text to write into /etc/knockd.conf
read -rp "Do you want to configure knockd (port knocking)? (y/N): " ans; echo
if [[ $ans =~ $YES_REGEX ]]; then
  print_info "Installing knockd..."
  apt-get install -y knockd
  conf="/etc/knockd.conf"
  if declare -p KNOCKED_PROFILE >/dev/null 2>&1; then
    print_info "Writing knockd profiles from KNOCKED_PROFILE..."
    : > "$conf.tmp"
    for varname in "${KNOCKED_PROFILE[@]}"; do
      [[ -n "${!varname:-}" ]] || { print_error "Variable '$varname' is empty or missing."; exit 1; }
      printf '%s\n' "${!varname}" >> "$conf.tmp"
    done
    mv -f "$conf.tmp" "$conf"
  elif [[ -n "${KNOCKD_CONF_TEXT:-}" ]]; then
    print_info "Writing knockd config from KNOCKD_CONF_TEXT..."
    printf '%s\n' "$KNOCKD_CONF_TEXT" > "$conf"
  else
    print_error "No knockd configuration provided in .env (KNOCKED_PROFILE or KNOCKD_CONF_TEXT)."
    exit 1
  fi
  systemctl enable knockd >/dev/null 2>&1 || true
  systemctl restart knockd
  print_success "knockd configured."
else
  print_info "Skipping knockd configuration."
fi

# ----------------------------------------------------------------------------------
# Optional: Automatic security updates
# ----------------------------------------------------------------------------------
print_info "Configuring unattended security updates..."
apt-get install -y unattended-upgrades
# Basic sane defaults; you can expand in .env later if needed
cat >/etc/apt/apt.conf.d/51auto-reboot <<'UPD'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
UPD

print_success "UFW setup complete."
