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

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }
# Load environment variables
if [ -f ./utils.sh ]; then
    # shellcheck disable=SC1091
    source ./utils.sh
else
    echo "utils.sh file not found!"
    exit 1
fi
echo "Please notice, that before running this script you should edit the .env file to your needs!"
read -rp "Would you like to proceed? (y/N): " reply
echo
[[ ! $reply =~ $YES_REGEX ]] && { echo "Aborting as per user request."; exit 1; }

# Load the .env file
load_env

# If the script run via -d flag, set the run to 1
[[ "${1:-}" == "-d" ]] && run=1 || run=0

# ------------------------------------------------------------------------------------
# A loop going thrue all the modules in .env file, and running them depends on the usre input:
# - Does it without asking if script runs in default mode 
# ------------------------------------------------------------------------------------

if [[ "${#MODULES[@]}" -eq 0 ]]; then
  print_error "MODULES array is empty or undefined."
  exit 1
fi

if (( run )); then 
    # Default mode - install all modules without asking
    print_info "Installing all modules automatically..."
    
    for module in "${MODULES[@]}"; do 
        print_info "Running ${module} setup..."
        if [ -f "$SCRIPT_DIR/${module}_setup.sh" ]; then
            bash "$SCRIPT_DIR/${module}_setup.sh"
        else
            print_error "Setup script for ${module} not found: $SCRIPT_DIR/${module}_setup.sh"
        fi
    done 

else 
    for module in "${MODULES[@]}"; do 
        read -rp "Do you want to run the ${module} module? (y/N): " reply
        echo
        if [[ $reply =~ $YES_REGEX ]]; then
            print_info "Running ${module} setup..."
            if [ -f "$SCRIPT_DIR/${module}_setup.sh" ]; then
                bash "$SCRIPT_DIR/${module}_setup.sh"
            else
                print_error "Setup script for ${module} not found: $SCRIPT_DIR/${module}_setup.sh"
            fi
        else
            print_info "Skipping ${module}....."
        fi
    done
fi

print_success "Installation complite!"