[file name]: ufw_install.sh
[file content begin]
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
# Installation Functions
# =============================================================================

# Install required packages
install_packages() { # {no args}
    print_info "The ufw module requires the following packages to be installed : ${UFW_DEPENDENCIES[*]}..."
    confirm_action "Do you want to proceed with the installation of these packages?" || return 1
    
    if install_pkgs "${UFW_DEPENDENCIES[@]}"; then
        print_success "All dependencies installed successfully"
        return 0
    else
        print_error "Failed to install dependencies"
        return 1
    fi
}

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
    create_backup "ufw" "/etc/ufw/before.rules" || print_warning "Could not backup before.rules"
    create_backup "ufw" "/etc/ufw/ufw.conf" || print_warning "Could not backup ufw.conf"
    create_backup "ufw" "/etc/ufw/applications.d" || print_warning "Could not backup applications.d"
}

# Restore UFW configuration from backup
restore_configuration() { # {no args}
    print_info "Restoring UFW configuration..."
    restore_backup "ufw" "/etc/ufw/before.rules" || print_warning "Could not restore before.rules"
    restore_backup "ufw" "/etc/ufw/ufw.conf" || print_warning "Could not restore ufw.conf"
    restore_backup "ufw" "/etc/ufw/applications.d" || print_warning "Could not restore applications.d"
}

# Initialize module state
initialize_state() { # {no args}
    print_info "Initializing UFW module state..."
    
    make_state "ufw"
    init_module_state "ufw" '{
    "current_stage": "not_configured",
    "installed_apps": [],
    "knockd_enabled": false,
    "ssh_profile": "none"
}'
    update_state "ufw" "status" "installation_ongoing"
}

# Setup application profiles from ufw.conf
setup_app_profiles() { # {no args}
    print_info "Setting up application profiles..."
    print_debug "Application profiles setup - placeholder"
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

cleanup_state() { # {no args}
    print_info "Cleaning up module state..."
    local state_file="/var/lib/alfred/state/ufw.json"
    
    if [[ -f "$state_file" ]]; then
        rm -f "$state_file"
        print_debug "State file removed: $state_file"
    fi
}

# =============================================================================
# Main Functions
# =============================================================================

install_ufw() { # {no args}
    print_header "Installing UFW Firewall Foundation"
    
    install_packages || return 1
    stop_services
    create_backup "ufw" "/etc/ufw" || print_warning "No configuration to backup or backup failed"
    setup_app_profiles
    initialize_state
    
    print_success "UFW foundation installation completed"
    print_warning "Firewall is NOT active yet. Use 'alfred ufw stage open' to configure."
}

remove_ufw() { # {no args}
    print_header "Removing UFW Firewall"
    
    if ! confirm_action "Are you sure you want to completely remove UFW firewall?"; then
        print_info "Removal cancelled"
        return 0
    fi
    
    stop_services
    confirm_action "Do you want to remove the installed packages (ufw, fail2ban, knockd)?" && { remove_packages || return 1; }
    restore_configuration
    cleanup_state
    
    print_success "UFW removal completed"
}

# =============================================================================
# Main Execution
# =============================================================================

main() { # {$1 = <action>}
    local action="${1:-install}"
    
    case "$action" in
        "install")
            check_root
            install_ufw ;;
        "remove")
            check_root
            remove_ufw ;;
        *)
            print_error "Unknown action: $action"
            echo "Usage: $0 [install|remove]"
            return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
[file content end]