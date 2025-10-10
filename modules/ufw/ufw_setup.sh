#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# USER MODULE — bootstrap for user rename and temporary SSH relaxation
# ==================================================================================
# Expectations:
# - Run ONLY via server_auto.sh with -u mode (isolated user flow)
# - Loads config from config/.env (via utils.sh)
# - This script:
#     1) Ensures root has a password (if missing/locked)
#     2) Installs a temporary SSH drop-in from $SSH_BOOTSTRAP_CONF (port 42, root/pass)
#     3) Validates & reloads SSH
#     4) Stages /root/change_name.sh for phase 2
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
# Root password setup:
# - If root already has a password (status P) => skip
# - Else require non-empty $ROOT_PASSWORD from .env and set it
# ----------------------------------------------------------------------------------
root_status="$(sudo passwd -S root 2>/dev/null | awk '{print $2}')"
if [[ -z "${root_status:-}" ]]; then
  print_error "Unable to determine root password status (passwd -S). Aborting."
  exit 1
fi

if [[ "$root_status" == "P" ]]; then
  print_info "Root already has a password — skipping."
else
  if [[ -z "${ROOT_PASSWORD:-}" ]]; then
    print_error "Default root password is empty or missing in the .env file, please update the file and run the script again."
    exit 1
  fi
  print_info "Setting new root password..."
  printf 'root:%s\n' "$ROOT_PASSWORD" | sudo chpasswd
  print_success "Default root password set."
fi






# Validate required environment variables
required_vars=("UFW_PACKAGES" "UFW_DEFAULT_INCOMING" "UFW_DEFAULT_OUTGOING" "MASTER_IP" "CUSTOME_UFW_PROFILES")
for var in "${required_vars[@]}"; do
  [ -n "${!var:-}" ] || { echo "Error: $var is not set in .env file!"; exit 1; }
done

#-------------- Packeges ---------------# 
# - Update and install packages
apt-get update
apt install -y $UFW_PACKAGES
#---------------------------------------#


#----------------- UFW -----------------#
# - Set defaults (from .env)
# - Allow master ip
# - Enable UFW non-interactively

print_info "Configuring UFW..."

# Default policies
ufw default "$UFW_DEFAULT_INCOMING" incoming
ufw default "$UFW_DEFAULT_OUTGOING" outgoing


# Add IP to whitelist
ufw allow from "$MASTER_IP"
print_info "Added master IP to UFW whitelist"

ufw enable

# Set up UFW logging
print_info "Setting up UFW logging..."
touch /var/log/ufw.log
echo -e "# Log kernel generated UFW log messages to file\n:msg,contains,\"[UFW \" /var/log/ufw.log\n& stop" | sudo tee -a /etc/rsyslog.d/20-ufw.conf > /dev/null
systemctl restart rsyslog

#---------------------------------------#



#------------ Port knocking ------------#
read -rp "Do you want to set a knocked service on the server? (y/N): " -n 1 reply
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    apt install -y knockd
    for var in "${KNOCKED_PROFILE[@]}"; do
        [ -n "${!var:-}" ] && { echo "${!var}" >> /etc/knockd.conf } || { echo "Error: $var is not set in .env file!"; exit 1; }
    done
else
    print_help "Skipping knocked instalaltion....."
fi


#---------------------------------------#

#------------- Auto updates ------------#
# Configure automatic security updates
print_info "Configuring automatic security updates..."
sudo apt install -y unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "true";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null
echo 'Unattended-Upgrade::Automatic-Reboot-Time "02:00";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null

print_success "UFW setup complete!"