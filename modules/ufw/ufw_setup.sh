#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# UFW MODULE - Firewall Management
# ==================================================================================

# ----------------------------------------------------------------------------------
# Paths & Configuration
# ----------------------------------------------------------------------------------
SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
MODULE_DIR="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
ROOT_DIR="$(cd "$MODULE_DIR/../.." && pwd)"
UTILS_DIR="$ROOT_DIR/utils"

UFW_CONFIG_DIR="$MODULE_DIR/ufw_config"
STATE_FILE="$MODULE_DIR/.state"
REGISTRY_FILE="$MODULE_DIR/.registry"
BACKUP_DIR="$MODULE_DIR/backups"

# ----------------------------------------------------------------------------------
# Core Functions
# ----------------------------------------------------------------------------------
init_module() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Please run as root (sudo)."; exit 1; }
    
    if [[ ! -f "$UTILS_DIR/utils.sh" ]]; then
        echo "utils.sh not found at $UTILS_DIR/utils.sh" >&2
        exit 1
    fi
    source "$UTILS_DIR/utils.sh"
    load_server_conf
    
    if [[ -z "${MASTER_IP:-}" ]]; then
        print_error "MASTER_IP not configured in server.conf"
        exit 1
    fi
    
    mkdir -p "$BACKUP_DIR"
}

configure_base_ufw() {
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow from "$MASTER_IP"
}

###############!!!!!!!!!! fix !!!!!!!!!!###############
write_ufw_profiles() {

    # Create custom UFW profiles from server.conf
    if command -v write_ufw_profiles >/dev/null 2>&1; then
        write_ufw_profiles
        print_success "UFW profiles written"
    else
        print_warning "write_ufw_profiles function not available in utils.sh"
    fi
}

check_ufw_state() {
    [[ -f "$STATE_FILE" ]] && [[ "$(< "$STATE_FILE")" =~ ^(open|close|ghost)$ ]] && return 0
    rm -f "$STATE_FILE" 2>/dev/null
    return 1
}

init_service_registry() {
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        if [[ -f "$UFW_CONFIG_DIR/service_registry.conf" ]]; then
            cp "$UFW_CONFIG_DIR/service_registry.conf" "$REGISTRY_FILE"
        else
            # Create minimal registry with simple echo
            echo "ssh:SSH-Custom:base:SSH access" > "$REGISTRY_FILE"
        fi
    fi
}

select_initial_mode() {
    echo "Select initial security mode:"
    echo "1) OPEN   - Public services with fail2ban"
    echo "2) CLOSE  - Hidden services with port knocking"  
    echo "3) GHOST  - Complete invisibility (stealth)"
    
    while true; do
        read -rp "Choose [1-3]: " choice
        case "$choice" in
            1) echo "open" > "$STATE_FILE"; apply_open_mode; break ;;
            2) echo "close" > "$STATE_FILE"; apply_close_mode; break ;;
            3) echo "ghost" > "$STATE_FILE"; apply_ghost_mode; break ;;
            *) echo "Invalid choice. Enter 1, 2, or 3." ;;
        esac
    done
}

apply_open_mode() {
    print_info "Applying OPEN mode configuration..."
    
    # Enable registered services using UFW profiles
    while IFS=: read -r service profile module description; do
        [[ -z "$service" || "$service" =~ ^# ]] && continue
        ufw allow "$profile"
        print_info "Enabled $service ($profile)"
    done < "$REGISTRY_FILE"
    
    ufw --force enable
    print_success "OPEN mode applied - services are publicly accessible"
}

apply_close_mode() {
    print_info "Applying CLOSE mode configuration..."
    # Only allow master IP, everything else requires knocking
    ufw --force enable
    print_success "CLOSE mode applied - ports hidden, knockd required"
}

apply_ghost_mode() {
    print_info "Applying GHOST mode configuration..."
    
    # Apply custom before.rules for ghost mode
    if [[ -f "$UFW_CONFIG_DIR/custom_before.rules" ]]; then
        cp "$UFW_CONFIG_DIR/custom_before.rules" /etc/ufw/before.rules
        # Replace placeholders
        sed -i "s/{{MASTER_IP}}/$MASTER_IP/g" /etc/ufw/before.rules
        sed -i "s/{{SSH_PORT}}/${SSH_PORT_FINAL:-42}/g" /etc/ufw/before.rules
    fi
    
    ufw --force enable
    print_success "GHOST mode applied - server is invisible"
}

# ----------------------------------------------------------------------------------
# Main Function
# ----------------------------------------------------------------------------------
main() {
    init_module
    init_service_registry
    
    if check_ufw_state; then
        configure_base_ufw
        write_ufw_profiles
        apply_selected_mode
        print_success "UFW configuration verified ($(cat "$STATE_FILE") mode active)"
    else
        configure_base_ufw
        write_ufw_profiles
        select_initial_mode
        apply_selected_mode
        print_success "UFW initial setup completed ($(cat "$STATE_FILE") mode active)"
    fi
}

# ----------------------------------------------------------------------------------
# Execution Guard
# ----------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi