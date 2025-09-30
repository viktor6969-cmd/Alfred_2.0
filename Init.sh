#!/usr/bin/env bash

# ==================================================================================
# FIRST INIT (Initiate the instalation sequence, and ask you about each step)
# ==================================================================================
# Expectations from you:
# - Run this from the project directory (same dir as .env and utils.sh)
# - Run via: sudo bash ./init.sh (or as root)
# - For a defualt installation add -d to the arguments ( sudo ./init.sh -d)
# ==================================================================================

set -euo pipefail

[ "${EUID:-$(id -u)}" -eq 0 ] || { print_error "Please run as root (sudo)."; exit 1; }
# Load environment variables
if [ -f ./utils.sh ]; then
    # shellcheck disable=SC1091
    source ./utils.sh
else
    echo "utils.sh file not found!"
    exit 1
fi

# Load the .env file
load_env

[[ "$1" == "-d" ]] && run=1 || run=0

# ------------------------------------------------------------------------------------
# User initiation runs user_setup.sh:
# - Ask the user if he want to change the default ubuntu user
# - Does it without asking if script runs in default mode 
# ------------------------------------------------------------------------------------

if (( run )); then 
    sudo $SCRIPT_DIR/user_setup.sh 

else 
    read -rp "Do you want to change the default ubuntu user to $NEW_USERNAME? (y/N): " -n 1
    echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Runing user setup..."
            sudo $SCRIPT_DIR/user_setup.sh 
        
        else
            print_help "Skipping....."
    fi
fi

# ------------------------------------------------------------------------------------
# Main setup:
# - Ask the user if he wants to set the server rules from the .env file 
# - Does it without asking if script runs in default mode 
# ------------------------------------------------------------------------------------


if (( run )); then 
    print_info "Runing user setup..."
    sudo $SCRIPT_DIR/user_setup.sh 
else
    read -rp "Do you want to set the UFW rules from the .env file? (y/N): " -n 1
    echo
fi