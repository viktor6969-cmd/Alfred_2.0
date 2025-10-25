#!/usr/bin/env bash

# =============================================================================
# UFW Management Functions
# =============================================================================
# This file contains functions for managing UFW profiles, status, and operations
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
ALFRED_ROOT="$(dirname "$MODULE_DIR")"
source "$ALFRED_ROOT/lib/utils.sh"

# =============================================================================
# Profile Management Functions
# =============================================================================

set_profile() { # {$1 = <profile: open|close|hide>} - Set UFW firewall profile
    local profile="$1"
    
    case "$profile" in
        "open") set_open_profile ;;
        "close")set_closed_profile ;;
        "hide") set_hidden_profile ;;
        *) print_error "Invalid profile: $profile. Use: open, close, or hide" ; return 1;;
    esac
}

set_open_profile() { # {no args} - Set open profile (allow common services)

    print_info "Setting UFW to OPEN profile..."
    
    # Check if Alfred profiles file exists
    if [[ ! -f "/etc/ufw/applications.d/alfred_profiles" ]]; then
        print_error "Alfred profiles file not found. Please run: alfred ufw reload-profiles"
        return 1
    fi
    
    # Reset UFW to defaults
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH-Open profile
    ufw allow "SSH-Open"
    print_debug "Allowed profile: SSH-Open"
    
    # Allow all installed apps from state
    local installed_apps=$(get_state_value "ufw" "installed_apps" "")
    if [[ -n "$installed_apps" ]]; then
        IFS=',' read -ra apps <<< "$installed_apps"
        for app in "${apps[@]}"; do
            ufw allow "$app"
            print_debug "Allowed installed app: $app"
        done
    fi
    
    # Enable UFW
    ufw --force enable
    
    # Update state
    update_state "ufw" "current_profile" "open"
    
    print_success "UFW OPEN profile activated"
}

set_closed_profile() { # {no args} - Set closed profile (deny all + knockd)
    print_info "Setting UFW to CLOSED profile..."
    
    # Check if Alfred profiles file exists
    if [[ ! -f "/etc/ufw/applications.d/alfred_profiles" ]]; then
        print_error "Alfred profiles file not found. Please run: alfred ufw reload-profiles"
        return 1
    fi
    
    # Reset UFW to defaults
    ufw --force reset
    
    # Set restrictive defaults - deny everything
    ufw default deny incoming
    ufw default deny outgoing
    
    # Enable knockd for closed profile
    setup_knockd "start"
    
    # Check UFW configuration before enabling
    if ! ufw --dry-run enable; then
        print_error "UFW configuration check failed. Please review settings."
        return 1
    fi
    
    # Enable UFW
    ufw --force enable
    
    # Update state
    update_state "ufw" "current_profile" "closed"
    update_state "ufw" "knockd_enabled" "true"
    
    print_success "UFW CLOSED profile activated (knockd required for access)"
}

set_hidden_profile() { # {no args} - Set hidden profile (placeholder)
    print_error "Working on it..."
    return 0
}

# ============================================================================
# Util finctions
# ============================================================================
load_ufw_profiles() { # {no args} - Create UFW applications.d file with Alfred profiles
    print_info "Loading UFW application profiles..."
    
    local ufw_conf="$ALFRED_ROOT/etc/ufw.conf"
    local ufw_apps_dir="/etc/ufw/applications.d"
    local output_file="$ufw_apps_dir/alfred_profiles"
    
    if [[ ! -f "$ufw_conf" ]]; then
        print_error "UFW configuration file not found: $ufw_conf"
        return 1
    fi
    
    # Create applications directory if it doesn't exist
    mkdir -p "$ufw_apps_dir"
    
    # Get UFW profiles using load_app_profiles
    local profiles_content
    profiles_content=$(load_app_profiles "ufw" "$ufw_conf")
    
    if [[ -z "$profiles_content" ]]; then
        print_warning "No UFW profiles found in configuration"
        # Create empty file to avoid errors
        touch "$output_file"
        return 0
    fi
    
    # Replace template variables
    local resolved_content="$profiles_content"
    if [[ "$resolved_content" == *"{{SSH_PORT_BOOTSTRAP}}"* ]]; then
        local ssh_port=$(get_config_value "server" "ssh_port" "22")
        resolved_content="${resolved_content//\{\{SSH_PORT_BOOTSTRAP\}\}/$ssh_port}"
        print_debug "Resolved SSH port to: $ssh_port in profiles"
    fi
    
    # Write all profiles to the single file
    echo "$resolved_content" > "$output_file"
    
    if [[ $? -eq 0 ]]; then
        local profile_count=$(grep -c "^\[.*\]$" "$output_file" 2>/dev/null || echo "0")
        print_success "Loaded $profile_count UFW profiles to: $output_file"
        return 0
    else
        print_error "Failed to create UFW profiles file: $output_file"
        return 1
    fi
}

get_config_value() { # {$1 = <section>} {$2 = <key>} {$3 = <default>} - Get value from server config
    local section="$1"
    local key="$2"
    local default="$3"
    local config_file="$ALFRED_ROOT/etc/server.conf"
    
    if [[ ! -f "$config_file" ]]; then
        echo "$default"
        return 0
    fi
    
    # Use awk to extract the value
    local value
    value=$(awk -F= -v section="$section" -v key="$key" '
        /^\[.*\]$/ {
            current_section = substr($0, 2, length($0)-1)
        }
        current_section == section && $1 == key {
            print $2
            exit
        }
    ' "$config_file")
    
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

load_knockd_profiles() { # {no args} - Create knockd.conf file with Alfred profiles
    print_info "Loading knockd configuration..."
    
    local ufw_conf="$ALFRED_ROOT/etc/ufw.conf"
    local output_file="/etc/knockd.conf"
    
    if [[ ! -f "$ufw_conf" ]]; then
        print_error "UFW configuration file not found: $ufw_conf"
        return 1
    fi
    
    # Get knockd profiles using load_app_profiles
    local knockd_config
    knockd_config=$(load_app_profiles "knockd" "$ufw_conf")
    
    if [[ -z "$knockd_config" ]]; then
        print_warning "No knockd profiles found in configuration"
        # Remove existing file if no config found
        [[ -f "$output_file" ]] && rm -f "$output_file"
        return 0
    fi
    
    # Write knockd configuration to file
    echo "$knockd_config" > "$output_file"
    
    if [[ $? -eq 0 ]]; then
        local profile_count=$(grep -c "^\[knockd\..*\]$" "$output_file" 2>/dev/null || echo "0")
        print_success "Loaded $profile_count knockd profiles to: $output_file"
        return 0
    else
        print_error "Failed to create knockd configuration file: $output_file"
        return 1
    fi
}

setup_knockd() { # {$1 = <action: start|stop>} - Control knockd service
    local action="$1"
    
    case "$action" in
        "start")
            systemctl is-active --quiet knockd && { print_debug "Knockd is already runing" ; return 0; }
            print_info "Starting knockd service..."
            systemctl enable knockd
            systemctl start knockd
            
            if systemctl is-active --quiet knockd; then
                print_success "Knockd service started"
                return 0
            else
                print_error "Failed to start knockd service"
                return 1
            fi
            ;;
        "stop")
            print_info "Stopping knockd service..."
            systemctl stop knockd
            systemctl disable knockd
            
            if ! systemctl is-active --quiet knockd; then
                print_success "Knockd service stopped"
                return 0
            else
                print_error "Failed to stop knockd service"
                return 1
            fi
            ;;
        *)
            print_error "Invalid action: $action. Use: start or stop"
            return 1
            ;;
    esac
}

get_ufw_status() { # {no args} - Get comprehensive UFW status information
    print_header "  UFW Firewall Status"
    
    # Basic UFW status
    echo "=== UFW Status ==="
    if ufw status | grep -q "Status: active"; then
        print_info "UFW:${GREEN}[ACTIVE]$NC"
        ufw status verbose | grep -v "^\s*$"
    else
        print_info "UFW:${RED}[INACTIVE]$NC"
    fi
    echo
    
    # Current profile from state
    local current_profile=$(get_state_value "ufw" "current_profile" "not set")
    echo "=== Current Profile ==="
    if [[ $current_profile == "not set" ]]; then
        print_info "Profile is ${RED}UNSET$NC"
    else
        print_info "Profile: $current_profile"
    fi
    echo
    
    # Installed applications
    echo "=== Installed Applications ==="
    local installed_apps=$(get_state_value "ufw" "installed_apps" "")
    if [[ -n "$installed_apps" && ! "$installed_apps"=="[]" ]]; then
        print_info "$installed_apps" | tr ',' '\n' | while read app; do
            print_info "• $app"
        done
    else
        echo "No applications configured"
    fi
    echo
    
    # Knockd status
    echo "=== Knockd Status ==="
    if systemctl is-active --quiet knockd 2>/dev/null; then
        print_info "Knockd:${GREEN}[ACTIVE]${NC}"
        systemctl status knockd --no-pager -l | head -10
    else
        print_info "Knockd:${RED}[INACTIVE]${NC}"
    fi
    echo
    
    # Module state
    echo "=== Module State ==="
    local module_state=$(get_state_value "ufw" "status" "unknown")
    [[ $module_state == "installed" ]] && print_info "${GREEN}[Installed]${NC}" || print_info "${RED}[$module_state]${NC}"
}

get_state_value() { # {$1 = <component>} {$2 = <key>} {$3 = <default>} - Get value from state
    local component="$1"
    local key="$2"
    local default="$3"
    local state_file="/var/lib/alfred/state/${component}.json"
    
    if [[ -f "$state_file" ]] && command -v jq &> /dev/null; then
        local value
        value=$(jq -r ".${key} // \"$default\"" "$state_file" 2>/dev/null)
        echo "$value"
    else
        echo "$default"
    fi
}