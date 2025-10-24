#!/usr/bin/env bash

# =============================================================================
# Alfred Installer - Minimal System Setup
# =============================================================================

set -euo pipefail

# Configuration
readonly ALFRED_NAME="alfred"
readonly ALFRED_VERSION="1.0.0"
readonly INSTALL_PREFIX="/usr/local"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Ensure jq is installed
install_jq() {
    if ! command -v jq &> /dev/null; then
        print_info "Installing jq..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y jq
        elif command -v yum &> /dev/null; then
            sudo yum install -y jq
        else
            print_error "Package manager not found. Please install jq manually."
            exit 1
        fi
        print_success "jq installed successfully."
    else
        print_debug "jq is already installed."
    fi
}

# Initialize state for installer component
initialize_state(){
    local component="Installer"
    print_debug "Initializing state for component: $component"
    make_state "$component"
    update_state "$component" "state" "Installing system components"
}

# Create system directories for state and logs
create_system_directories() {

    print_info "Creating system directories for state and logs..."
    
    # Runtime directory (PID files)
    create_directory "/var/run/alfred"
    
    # State directory (JSON state files)
    create_directory "/var/lib/alfred/state"
    
    # Log directory
    create_directory "/var/log/alfred"
    
    print_success "System directories created"
}

# Install the main executable
install_main_executable() {

    print_info "Installing Alfred main executable..."
    update_state "Installer" "Installing main executable"
    # Copy the existing alfred.sh to /usr/local/bin/alfred
    ln -sf "${PROJECT_DIR}/bin/alfred.sh" "${INSTALL_PREFIX}/bin/alfred"
    chmod +x "${INSTALL_PREFIX}/bin/alfred"
    print_success "Main executable installed"
}

# Create initial log file
initialize_logging() {
    print_info "Setting up logging..."
    update_state "Installer" "Setting up logging system"
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
        update_state "Installer" "Installed"
        return 0
    else
        print_error "Installation verification failed with $errors error(s)"
        return 1
    fi
}

# Main installation function
main() {
    print_logo
    print_info "Starting Alfred v${ALFRED_VERSION} installation..."
    
    ######### ADD sudo apt install -y jq #########

    # Run installation steps
    check_root
    check_existing_installation
    install_jq
    print_debug "jq installation step completed"
    initialize_state
    create_system_directories
    install_main_executable
    initialize_logging
    
    if verify_installation; then
        print_success "Alfred v${ALFRED_VERSION} installed successfully!"
        exit 0
    else
        print_error "Installation completed with errors. Please check the output above."
        exit 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi