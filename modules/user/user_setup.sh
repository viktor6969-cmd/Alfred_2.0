#!/usr/bin/env bash

# =============================================================================
# Alfred User Setup - Standalone Manual Script
# =============================================================================

set -euo pipefail

readonly COMPONENT="user-setup"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source Alfred utilities
source "${PROJECT_DIR}/lib/utils.sh"

# Root password setup
setup_root_password() {
    local root_status
    root_status=$(passwd -S root 2>/dev/null | awk '{print $2}' || echo "unknown")
    
    if [[ "$root_status" == "P" ]]; then
        print_info "Root already has a password - skipping"
        state_update "$COMPONENT" "root_password_set" "true"
        return 0
    fi
    
    print_header "Root Password Setup"
    print_warning "Root account currently has no password or is locked"
    
    if [[ -n "${ROOT_PASSWORD:-}" ]]; then
        if confirm_action "Use default root password from Alfred config?" "n"; then
            if printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd; then
                print_success "Root password set from Alfred config"
                state_update "$COMPONENT" "root_password_set" "true"
                return 0
            else
                print_error "Failed to set root password from Alfred config"
                return 1
            fi
        fi
    fi
    
    # Interactive password setup
    print_info "Interactive password setup required"
    while true; do
        read -srp "Enter new root password: " _pw1
        echo
        read -srp "Confirm new root password: " _pw2
        echo
        
        if [[ -z "$_pw1" || -z "$_pw2" ]]; then
            print_error "Password cannot be empty"
            continue
        fi
        
        if [[ "$_pw1" != "$_pw2" ]]; then
            print_error "Passwords do not match"
            continue
        fi
        
        if printf 'root:%s\n' "$_pw1" | chpasswd; then
            print_success "Root password set successfully"
            state_update "$COMPONENT" "root_password_set" "true"
            unset _pw1 _pw2
            break
        else
            print_error "Failed to set password. Please try again."
        fi
    done
}

# Stage change-name script
stage_change_script() {
    local src_script="${PROJECT_DIR}/lib/change_name.sh"
    local dest_script="/root/change_name.sh"
    
    if [[ ! -f "$src_script" ]]; then
        print_error "change_name.sh not found at $src_script"
        return 1
    fi
    
    # Check if already correctly linked
    if [[ -L "$dest_script" ]] && [[ "$(readlink -f "$dest_script")" == "$(readlink -f "$src_script")" ]]; then
        print_info "Change script already correctly linked"
    else
        # Remove if exists (file or broken symlink)
        rm -f "$dest_script"
        # Create new symlink
        ln -s "$src_script" "$dest_script"
        print_success "Change script symlinked to $dest_script"
    fi
    
    # Ensure source script is executable
    chmod 700 "$src_script"
    
    state_update "$COMPONENT" "change_script_staged" "true"
}

# Validate SSH configuration
validate_ssh() {
    print_info "Validating current SSH configuration..."
    
    if ! command -v sshd >/dev/null 2>&1; then
        print_warning "SSH daemon not found, skipping SSH validation"
        return 0
    fi
    
    if ! sshd -t; then
        print_error "Current SSH configuration is invalid"
        print_warning "Please fix SSH configuration before continuing"
        return 1
    fi
    
    print_success "SSH configuration is valid"
    return 0
}

# Main execution flow
main() {
    print_header "Alfred User Setup - Phase 1"
    
    # Initialize state and PID
    check_root
    state_init "$COMPONENT"
    pid_acquire "$COMPONENT" || exit 1
    
    # Set initial state
    state_set_status "$COMPONENT" "in_progress"
    state_set_status "$COMPONENT" "awaiting_reconnect"
    
    # Setup steps
    setup_root_password
    validate_ssh
    stage_change_script
    
    # Final state update
    state_set_status "$COMPONENT" "awaiting_completion"
    state_update "$COMPONENT" "phase1_completed_at" "$(get_timestamp)"
    
    # Cleanup
    pid_release "$COMPONENT"
    
    echo
    print_success "Phase 1 completed successfully!"
    echo
    print_header "Next Steps:"
    echo "1. Reconnect as root (if needed)"
    echo "2. Run: /root/change_name.sh"
    echo "3. That script will complete the user rename process"
    echo
    print_info "State saved to: /var/lib/alfred/state/${COMPONENT}.json"
}

# Trap signals for cleanup
trap 'pid_release "$COMPONENT"' EXIT INT TERM

# Run main function
main "$@"