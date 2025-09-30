#!/usr/bin/env bash

# ==================================================================================
# UFW SETUP (packages, UFW, SSH cosmetics, auto updates)
# ==================================================================================
# Expectations from you:
# - Run this from the project directory (same dir as .env and utils.sh)
# - Run via: sudo bash ./main_setup.sh (or as root)
# ==================================================================================

set -euo pipefail

[ "${EUID:-$(id -u)}" -eq 0 ] || { print_error "Please run as root (sudo)."; exit 1; }

# Load helpers and env
if [ -f ./utils.sh ]; then
    # shellcheck disable=SC1091
    source ./utils.sh
else
    echo "utils.sh file not found!"
    exit 1
fi
load_env



# Validate required environment variables
required_vars=("PACKAGES" "NGINX_PORTS" "UFW_DEFAULT_INCOMING" "UFW_DEFAULT_OUTGOING" "UFW_ALLOW_SERVICES")
for var in "${required_vars[@]}"; do
  [ -n "${!var:-}" ] || { echo "Error: $var is not set in .env file!"; exit 1; }
done

#-------------- Packeges ---------------# 
# Update and install packages
echo "Updating package list and installing packages..."
sudo apt-get update
sudo apt install -y $PACKAGES


#----------------- UFW -----------------#
# - Set defaults (from .env)
# - Allow SSH port from .env to avoid lockout
# - Allow additional services/ports
# - Enable UFW non-interactively

print_info "Configuring UFW..."

# Default policies
ufw default "$UFW_DEFAULT_INCOMING" incoming
ufw default "$UFW_DEFAULT_OUTGOING" outgoing

# Criete Profiles in /
sudo ufw allow $UFW_ALLOW_SERVICES
sudo ufw enable

# Add IP to whitelist
ufw allow from "$MASTER_IP"
echo "Added master IP $MASTER_IP to UFW whitelist"

# Set up UFW logging
echo "Setting up UFW logging..."
sudo touch /var/log/ufw.log
echo -e "# Log kernel generated UFW log messages to file\n:msg,contains,\"[UFW \" /var/log/ufw.log\n& stop" | sudo tee -a /etc/rsyslog.d/20-ufw.conf > /dev/null
sudo systemctl restart rsyslog

#----------------- SSH -----------------#
echo "Configuring SSH security..."

# Backup original SSH config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Hide SSH version banner
sed -i 's/^#Banner none/Banner none/' /etc/ssh/sshd_config
sed -i 's/^#DebianBanner no/DebianBanner no/' /etc/ssh/sshd_config


#------------- Auto updates ------------#
# Configure automatic security updates
echo "Configuring automatic security updates..."
sudo apt install -y unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "true";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null
echo 'Unattended-Upgrade::Automatic-Reboot-Time "02:00";' | sudo tee -a /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null

echo "Package installation complete!"