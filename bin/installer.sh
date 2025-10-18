#!/usr/bin/env bash

# =============================================================================
# Alfred Installer - Minimal System Setup
# =============================================================================

set -euo pipefail

# Configuration
readonly ALFRED_NAME="alfred"
readonly ALFRED_VERSION="1.0.0"
readonly INSTALL_PREFIX="/usr/local"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source utilities
source "${PROJECT_DIR}/lib/utils.sh"

# Check if Alfred is already installed
check_existing_installation() {
    if [[ -f "${INSTALL_PREFIX}/bin/${ALFRED_NAME}" ]]; then
        print_warning "Alfred appears to be already installed"
        if ! confirm_action "Do you want to reinstall?" "n"; then
            print_info "Installation cancelled"
            exit 0
        fi
        # Remove existing installation
        rm -f "${INSTALL_PREFIX}/bin/${ALFRED_NAME}"
    fi
}

# Create system directories for state and logs
create_system_directories() {
    print_info "Creating system directories for state and logs..."
    
    # Runtime directory (PID files)
    create_directory "/var/run/alfred"
    
    # State directory (JSON state files)
    create_directory "/var/lib/alfred/state/modules"
    
    # Log directory
    create_directory "/var/log/alfred"
    
    print_success "System directories created"
}

# Install the main executable
install_main_executable() {
    print_info "Installing Alfred main executable..."
    
    # Copy the existing alfred.sh to /usr/local/bin/alfred
    ln -sf "${PROJECT_DIR}/bin/alfred.sh" "${INSTALL_PREFIX}/bin/alfred"
    
    print_success "Main executable installed"
}

# Create initial state files
initialize_state() {
    print_info "Initializing Alfred state..."
    
    local initial_state="/var/lib/alfred/state/installation.json"
    local timestamp=$(get_timestamp)
    local install_id=$(generate_id 16)
    
    printf '{
        "alfred_version": "%s",
        "installed_at": "%s",
        "status": "installed",
        "installation_id": "%s",
        "project_directory": "%s",
        "modules_installed": []
    }' "$ALFRED_VERSION" "$timestamp" "$install_id" "$PROJECT_DIR" > "$initial_state"
    
    chmod 644 "$initial_state"
    print_success "Initial state created"
}

# Create initial log file
initialize_logging() {
    print_info "Setting up logging..."
    
    touch /var/log/alfred/alfred.log
    chmod 644 /var/log/alfred/alfred.log
    
    # Log the installation
    echo "$(get_timestamp) [INSTALLER] Alfred v${ALFRED_VERSION} installed successfully" >> /var/log/alfred/alfred.log
    echo "$(get_timestamp) [INSTALLER] Project directory: ${PROJECT_DIR}" >> /var/log/alfred/alfred.log
    
    print_success "Logging system initialized"
}

# Verify installation
verify_installation() {
    print_info "Verifying installation..."
    
    local errors=0
    
    # Check if main executable exists and is executable
    if ! validate_file "${INSTALL_PREFIX}/bin/alfred"; then
        ((errors++))
    elif [[ ! -x "${INSTALL_PREFIX}/bin/alfred" ]]; then
        print_error "Main executable not executable"
        ((errors++))
    fi
    
    # Check if project directory is accessible
    if ! validate_directory "${PROJECT_DIR}"; then
        ((errors++))
    fi
    
    # Check if system directories are accessible
    if ! validate_directory "/var/lib/alfred/state"; then
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        print_success "Installation verified successfully"
        return 0
    else
        print_error "Installation verification failed with $errors error(s)"
        return 1
    fi
}

# Main installation function
main() {
    print_header "=========================================="
    print_header "    Alfred Installer v${ALFRED_VERSION}"
    print_header "=========================================="
    
    # Run installation steps
    check_root
    check_existing_installation
    create_system_directories
    install_main_executable
    initialize_state
    initialize_logging
    
    if verify_installation; then
        show_post_install_info
    else
        print_error "Installation completed with errors. Please check the output above."
        exit 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi