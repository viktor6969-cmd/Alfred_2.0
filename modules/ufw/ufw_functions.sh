restore_configuration() { # {no args} - Restore original configuration
    if [[ -d "/etc/ufw/backup" ]]; then
        print_info "Restoring original configuration..."
        
        if cp -r /etc/ufw/backup/* /etc/ufw/ 2>/dev/null; then
            print_success "Configuration restored"
        else
            print_warning "Failed to restore configuration"
        fi
    fi
}