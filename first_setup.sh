#!/usr/bin/env bash

# ==================================================================================
# INIT (bootstrap) script
# ==================================================================================
# Expectations from you:
# - Run this from the project directory (same dir as .env and change_name.sh)
# - Run via: sudo bash ./init.sh   (or equivalent)
# - After it finishes, reconnect as root and run /root/change_name.sh
# ==================================================================================

set -euo pipefail
    
# Load environment variables
if [ -f ./utils.sh ]; then
    source ./utils.sh
else
    echo "utils.sh file not found!"
    exit 1
fi

# Load the .env file
load_env

# Set root password
print_info "Setting root password..."
printf 'root:%s\n' "$ROOT_PASSWORD" | sudo chpasswd

# ------------------------------------------------------------------------------------
# SSH configs:
# - Back up curent settings (if not done yet)
# - Make a temp ssh config file
# - Allows root access via password 
# - Changes the ssh port to 42 
# ------------------------------------------------------------------------------------

# Check if drop-in already exists with different content
DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
if [ -f "$DROPIN" ]; then
    if ! grep -q "BOOTSTRAP: temporary relaxed SSH" "$DROPIN"; then
        print_error "Warning: $DROPIN exists but doesn't appear to be from this script."
        read -p "Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Aborting."
            exit 1
        fi
    fi
fi

# Backup sshd_config into local ./config.bkp
print_info "Backing up /etc/ssh/sshd_config to .backups ..."
backup_file "/etc/ssh/sshd_config"

# Modify the drop-in 
print_info "Writing SSH drop-in: $DROPIN"
sudo mkdir -p /etc/ssh/sshd_config.d
printf '%s\n' "$SSH_BOOTSTRAP_CONF" | sudo tee "$DROPIN" > /dev/null


# Validate SSH config before reloading
print_info "Validating sshd config..."
if sudo sshd -t || { print_error "SSH config invalid. Aborting before reload."; exit 1; }; then
    print_info "Reloading SSH with new settings..."
    if sudo systemctl is-active --quiet ssh; then
        sudo systemctl reload ssh || sudo systemctl restart ssh
    else
        print_info "Starting SSH service..."
        sudo systemctl start ssh && print_success "SSH configuration updated successfully"
    fi
else
    print_error "SSH configuration invalid. Aborting before reload."
    exit 1
fi


# ------------------------------------------------------------------------------------
# Add the change_name.sh script:
# - Make a soft link to the change_name.sh script in root dir (if not already exist)
# - Changes the permissions so it cna be run
# ------------------------------------------------------------------------------------


# Create the samilink for change_name.sh in the root dir
print_info "Creating /root/change_name.sh (symlink to project file)..."
if [ ! -f ./change_name.sh ]; then
    print_error "ERROR: ./change_name.sh not found in current directory."
    exit 1
fi

# Make executable
sudo ln -sf "$(pwd)/change_name.sh" /root/change_name.sh
sudo chmod 700 /root/change_name.sh
sudo chown root:root /root/change_name.sh

print_success "First installation complete!"
echo "Now please disconnect and log in as root with the temperery password"
echo "Then run: /root/change_name.sh"