#!/usr/bin/env bash

# =============================================================================
# UFW Module Installation/Removal Script
# =============================================================================
# This script handles the installation and removal of the UFW firewall module.
# It manages package dependencies, service control, configuration backup/restore,
# and state initialization for the UFW module.
#
# Usage:
#   ./ufw_install.sh install    - Install UFW module and dependencies
#   ./ufw_install.sh remove     - Remove UFW module and cleanup
#
# Features:
#   - Installs required packages (ufw, fail2ban, knockd)
#   - Stops and disables services during installation
#   - Backs up existing UFW configuration
#   - Initializes module state with stage management
#   - Provides clean removal with configuration restoration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
ALFRED_ROOT="$(dirname "$MODULE_DIR")"
source "$ALFRED_ROOT/lib/utils.sh"

# Dependencies array
readonly UFW_DEPENDENCIES=("ufw" "fail2ban" "knockd")


# =============================================================================
# Action fucntioncs 
# =============================================================================

# Stop and disable services
stop_services() { # {no args}
    print_debug "Stopping and disabling services..."
    
    local services=("ufw" "fail2ban" "knockd")
    for service in "${services[@]}"; do
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        print_debug "Stopped and disabled: $service"
    done
}

# Backup UFW configuration
backup_configuration() { # {no args}
    print_info "Backing up UFW configuration..."
    
    # Create main backup directory
    local backup_dir="/var/lib/alfred/backups/ufw"
    mkdir -p "$backup_dir"
    
    # Backup individual components
    create_backup "ufw" "/etc/ufw" || print_warning "Could not backup UFW configuration"
    
    # Additional specific backups for critical files
    if [[ -f "/etc/ufw/ufw.conf" ]]; then
        create_backup "ufw" "/etc/ufw/ufw.conf"
    fi
    
    if [[ -f "/etc/ufw/before.rules" ]]; then
        create_backup "ufw" "/etc/ufw/before.rules"
    fi
    
    if [[ -d "/etc/ufw/applications.d" ]]; then
        create_backup "ufw" "/etc/ufw/applications.d"
    fi
    
    # Cleanup old backups, keep only last 3
    cleanup_backups "ufw" 3
}

# Restore UFW configuration from backup
restore_configuration() { # {no args}

    local exit_code=0
    print_debug "Restoring UFW configuration..."
    
    # Try to restore the entire UFW directory first
    if ! restore_backup "ufw" "/etc/ufw"; then
        # If full restore fails, try individual components
        print_debug "Global restore failed. Trying one by one" 
        restore_backup "ufw" "/etc/ufw/ufw.conf" || print_warning "Could not restore ufw.conf"
        restore_backup "ufw" "/etc/ufw/before.rules" || print_warning "Could not restore before.rules"
        restore_backup "ufw" "/etc/ufw/applications.d" || print_warning "Could not restore applications.d"
    fi
}

# =============================================================================
# Installation Functions
# =============================================================================

# Install required packages
install_packages() { # {no args}
    # Check if all required packages are already installed
    local missing_deps=()
    
    for dep in "${UFW_DEPENDENCIES[@]}"; do
        # Check if it's available as a command
        if command -v "$dep" &> /dev/null; then
            continue
        # Check if it's a service/package that's installed (using package manager)
        elif dpkg -l | grep -q "^ii  $dep "; then
            continue
        # Check if it's running as a service
        elif systemctl is-active --quiet "$dep" 2>/dev/null; then
            continue
        else
            missing_deps+=("$dep")
        fi
    done
    
    # If all dependencies are already installed, skip installation
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        print_debug "All required dependencies are already installed"
        return 0
    fi
    
    print_info "The ufw module requires the following packages to be installed: ${missing_deps[*]}..."
    confirm_action "Do you want to proceed with the installation of these packages?" || return 1
    
    if install_pkgs "${missing_deps[@]}"; then
        print_success "All dependencies installed successfully"
        return 0
    else
        print_error "Failed to install dependencies"
        return 1
    fi
}

# Initialize module state
initialize_state() { # {no args}
    print_debug "Initializing UFW module state..."
    
    make_state "ufw"
    init_module_state "ufw" '{
    "current_stage": "not_configured",
    "installed_apps": [],
    "knockd_enabled": false,
    "ssh_profile": "none"
}'
    update_state "ufw" "status" "installation_incomplete"
}

# Add this function to ufw_install.sh
setup_knockd_configs() { # {no args} - Setup knockd configuration during installation
    print_info "Setting up knockd configuration..."
    
    local ufw_conf="$ALFRED_ROOT/config/ufw.conf"
    
    # Extract all knockd configurations from ufw.conf
    local knockd_config
    knockd_config=$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        
        /^\[knockd\./ {
            collecting = 1
            print $0
            next
        }
        
        /^\[.*\]$/ && !/^\[knockd\./ {
            collecting = 0
            next
        }
        
        collecting { print }
    ' "$ufw_conf")
    
    if [[ -n "$knockd_config" ]]; then
        echo "$knockd_config" > /etc/knockd.conf
        print_success "Knockd configuration created"
    else
        print_warning "No knockd configuration found in ufw.conf"
    fi
}

# =============================================================================
# Removal Functions
# =============================================================================

remove_packages() { # {no args}
    print_info "Removing packages: ufw, fail2ban, knockd..."
    
    if apt-get remove -y ufw fail2ban knockd; then
        print_success "Packages removed successfully"
        return 0
    else
        print_error "Failed to remove packages"
        return 1
    fi
}

# Remove Alfred profiles file
remove_app_profiles() { # {no args} - Clean up UFW profiles
    print_info "Removing Alfred UFW profiles..."
    
    local profile_file="/etc/ufw/applications.d/alfred_profiles"
    
    if [[ -f "$profile_file" ]]; then
        if rm -f "$profile_file"; then
            print_success "Removed Alfred UFW profiles: $profile_file"
        else
            print_error "Failed to remove Alfred UFW profiles: $profile_file"
            return 1
        fi
    else
        print_debug "No Alfred UFW profiles found to remove"
    fi
    
    return 0
}

cleanup_state() { # {no args}
    print_debug "Cleaning up module state..."
    local state_file="/var/lib/alfred/state/ufw.json" 
    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"
        print_debug "State file removed: $state_file"
    fi
    remove_app_profiles
    print_debug "App profiles removed" 
}

# =============================================================================
# Main Functions
# =============================================================================

install_ufw() { # {no args}
    echo -e "Installing UFW Firewall Foundation"
    install_packages || return 1
    stop_services
    create_backup "ufw" "/etc/ufw" || print_warning "No configuration to backup or backup failed"
    setup_app_profiles
    setup_knockd_configs
    initialize_state
    print_warning "Firewall is NOT active yet. Use 'alfred ufw stage <open|close|hide>' to applay a profile"
}

remove_ufw() { # {$1 = "reinstall" (optional) Reinsallation flag}
    stop_services
    if [[ ! "$1" == "reinstall" ]]; then
        confirm_action "Do you want to remove the installed packages (ufw, fail2ban, knockd)?" && remove_packages
    fi
    restore_configuration
    cleanup_state
}

# =============================================================================
# Main Execution
# =============================================================================

main() { # {$1 = <action>}
    local action="${1:-install}"
    check_root || return 1
    case "$action" in
        "install") install_ufw;;
        "remove") remove_ufw ;;
        "reinstall") remove_ufw "reinstall" && install_ufw;;
        *)
            print_error "Unknown action: $action"
            echo "Usage: $0 [install|remove|reinstall]"
            return 1 ;;
    esac
    return $?
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi