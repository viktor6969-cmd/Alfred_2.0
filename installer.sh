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
            sudo apt-get install -y -q jq
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

check_file_format() { # {$1 = <file_path>} - Check and fix file format if needed
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        print_debug "File not found: $file"
        return 0
    fi
    
    if grep -q $'\r' "$file"; then
        print_warning "Found Windows line endings in: $file"
        if confirm_action "Convert to Unix format?"; then
            if dos2unix "$file" 2>/dev/null || sed -i 's/\r$//' "$file"; then
                print_success "Converted to Unix format: $file"
            else
                print_error "Failed to convert: $file"
                return 1
            fi
        fi
    else
        print_debug "File format is correct: $file"
    fi
    return 0
}

check_all_config_files() { # {no args} - Check all config files in etc directory
    local etc_dir="$PROJECT_DIR/etc"
    
    if [[ ! -d "$etc_dir" ]]; then
        print_warning "etc directory not found: $etc_dir"
        return 0
    fi
    
    print_info "Checking config file formats..."
    
    for config_file in "$etc_dir"/*.conf "$etc_dir"/*.config; do
        [[ -f "$config_file" ]] || continue
        check_file_format "$config_file"
    done
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
    validate_directory "${PROJECT_DIR}" || ((errors++))
    
    # Check if system directories are accessible
    validate_directory "/var/lib/alfred/state" || ((errors++))    

    check_all_config_files || ((errors++))

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