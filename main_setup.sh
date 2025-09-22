#!/usr/bin/env bash

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo "Error: .env file not found!"
    exit 1
fi

# Validate required environment variables
required_vars=("SSH_PORT" "NGINX_PORTS" "UFW_DEFAULT_INCOMING" "UFW_DEFAULT_OUTGOING" "MASTER_IP" "PACKAGES")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in .env file!"
        exit 1
    fi
done

#-------------- Packeges ---------------# 
# Update and install packages
echo "Updating package list and installing packages..."
sudo apt-get update
sudo apt install -y $PACKAGES


#----------------- UFW -----------------#

# Configure UFW
echo "Configuring UFW..."

# Criete Profiles in /
sudo ufw allow $UFW_ALLOW_SERVICES
sudo ufw default $UFW_DEFAULT_INCOMING incoming
sudo ufw default $UFW_DEFAULT_OUTGOING outgoing
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