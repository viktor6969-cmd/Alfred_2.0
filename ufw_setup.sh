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
print_success "Added master IP to UFW whitelist"

yes | ufw enable

# Set up UFW logging
print_info "Setting up UFW logging..."
touch /var/log/ufw.log
echo -e "# Log kernel generated UFW log messages to file\n:msg,contains,\"[UFW \" /var/log/ufw.log\n& stop" | sudo tee -a /etc/rsyslog.d/20-ufw.conf > /dev/null
systemctl restart rsyslog

#---------------------------------------#



#------------ Port knocking ------------#
read -rp "Do you want to set a knocked service on the server? (y/N): " reply
echo
if [[ $reply =~ ^[Yy]$ ]]; then
    apt install -y knockd
    for var in "${KNOCKED_PROFILE[@]}"; do
        [ -n "${!var:-}" ] && { echo "${!var}" >> /etc/knockd.conf; } || { echo "Error: $var is not set in .env file!"; exit 1; }
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