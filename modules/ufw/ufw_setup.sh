#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# UFW MODULE — baseline firewall configuration
# ==================================================================================
# Expectations:
# - Called by server_auto.sh (interactive or force mode)
# - Loads SSH/ports/master IP and profiles from config/server.conf via utils.sh
# - Secrets stay in config/.env (not used here)
# - This script:
#     1) Optionally installs packages (from [ufw] PACKAGES)
#     2) Applies default policies and MASTER_IP allow-list
#     3) Writes UFW app profiles from [ufw.profile.*]
#     4) Enables UFW and configures rsyslog split logging
#     5) (Optional) Installs knockd and writes [knockd.profile.*]
#     6) (Optional) Enables unattended-upgrades (prompted)
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

# Load config (globals: MASTER_IP / ports); ufw specifics read below
load_server_conf

# Read UFW section from server.conf (fall back to sane defaults if absent)
UFW_DEFAULT_INCOMING="$(get_conf_value ufw DEFAULT_INCOMING || true)"; UFW_DEFAULT_INCOMING="${UFW_DEFAULT_INCOMING:-deny}"
UFW_DEFAULT_OUTGOING="$(get_conf_value ufw DEFAULT_OUTGOING || true)"; UFW_DEFAULT_OUTGOING="${UFW_DEFAULT_OUTGOING:-allow}"
UFW_PACKAGES="$(get_conf_value ufw PACKAGES || true)";           UFW_PACKAGES="${UFW_PACKAGES:-ufw unattended-upgrades}"

# ----------------------------------------------------------------------------------
# Packages (prompt before install)
# ----------------------------------------------------------------------------------
if [[ -n "${UFW_PACKAGES:-}" ]]; then
  print_info "The following packages will be installed: ${UFW_PACKAGES}"
  read -rp "Proceed with package installation? (y/N): " ans; echo
  if [[ $ans =~ $YES_REGEX ]]; then
    print_info "Updating apt cache..."
    apt-get update -y
    print_info "Installing packages..."
    # shellcheck disable=SC2086
    apt-get install -y ${UFW_PACKAGES}
    print_success "Packages installed."
  else
    print_info "Skipping package installation."
  fi
fi

# ----------------------------------------------------------------------------------
# Configure UFW defaults + MASTER_IP allow
# ----------------------------------------------------------------------------------
print_info "Configuring UFW default policies..."
ufw --force reset >/dev/null 2>&1 || true
ufw default "${UFW_DEFAULT_INCOMING}" incoming
ufw default "${UFW_DEFAULT_OUTGOING}" outgoing

print_info "Whitelisting management IP: ${MASTER_IP}"
ufw allow from "${MASTER_IP}"

# ----------------------------------------------------------------------------------
# Write UFW application profiles from server.conf
# ----------------------------------------------------------------------------------
print_info "Writing UFW application profiles from [ufw.profile.*]..."
write_ufw_profiles

# ----------------------------------------------------------------------------------
# Enable UFW and configure logging
# ----------------------------------------------------------------------------------
print_info "Enabling UFW (non-interactive)..."
ufw --force enable

print_info "Configuring UFW logging via rsyslog..."
rsys_conf="/etc/rsyslog.d/20-ufw.conf"
cat > "$rsys_conf" <<'RSYS'
# Log kernel-generated UFW messages to a dedicated file
:msg, contains, "[UFW " /var/log/ufw.log
& stop
RSYS
systemctl restart rsyslog

# ----------------------------------------------------------------------------------
# Optional: knockd (port knocking) — install + write [knockd.profile.*]
# ----------------------------------------------------------------------------------
read -rp "Do you want to configure knockd (port knocking)? (y/N): " ans; echo
if [[ $ans =~ $YES_REGEX ]]; then
  print_info "Installing knockd..."
  apt-get update -y
  apt-get install -y knockd

  print_info "Writing /etc/knockd.conf from [knockd.profile.*]..."
  write_knockd_config

  systemctl enable knockd >/dev/null 2>&1 || true
  systemctl restart knockd
  print_success "knockd installed and configured."
else
  print_info "Skipping knockd."
fi

# ----------------------------------------------------------------------------------
# Optional: unattended-upgrades (prompted)
# ----------------------------------------------------------------------------------
read -rp "Enable unattended security upgrades (auto-reboot at 02:00)? (y/N): " ans; echo
if [[ $ans =~ $YES_REGEX ]]; then
  apt-get update -y
  apt-get install -y unattended-upgrades
  cat >/etc/apt/apt.conf.d/51auto-reboot <<'UPD'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
UPD
  print_success "Unattended upgrades enabled."
else
  print_info "Skipping unattended-upgrades."
fi

print_success "UFW setup complete."
