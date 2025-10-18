#!/usr/bin/env bash

# =============================================================================
# Alfred Utilities Library
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Print functions
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }
print_header() { echo -e "${MAGENTA}[ALFRED]${NC} $1"; }

# Display post-installation information
show_post_install_info() {
    echo
    print_success "╔══════════════════════════════════════╗"
    print_success "║          Alfred Installed!           ║"
    print_success "╚══════════════════════════════════════╝"
    echo
    echo "┌─ Commands ──────────────────────────────────┐"
    echo "│  install <module>    Install a module       │"
    echo "│  remove <module>     Remove a module        │"
    echo "│  list                Show available modules │"
    echo "│  status              Show installation      │"
    echo "└─────────────────────────────────────────────┘"
    echo
    echo "┌─ Important Paths ───────────────────────────┐"
    echo "│  Project:   ${PROJECT_DIR}│"
    echo "│  State:     /var/lib/alfred/state/          │"
    echo "│  Logs:      /var/log/alfred/                │"
    echo "└─────────────────────────────────────────────┘"
    echo
    print_warning "Note: Keep project directory intact"
}


# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This command must be run as root"
        exit 1
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate directory exists and is accessible
validate_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        print_error "Directory does not exist: $dir"
        return 1
    fi
    if [[ ! -r "$dir" || ! -w "$dir" ]]; then
        print_error "Directory not accessible: $dir"
        return 1
    fi
    return 0
}

# Create directory with proper permissions
create_directory() {
    local dir="$1"
    local permissions="${2:-755}"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$permissions" "$dir"
        print_debug "Created directory: $dir"
    else
        print_debug "Directory already exists: $dir"
    fi
}

# Get current timestamp
get_timestamp() {
    date -Iseconds
}




# Generate a random string
generate_id() {
    local length="${1:-8}"
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# Confirm action with user
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        read -rp "$message (Y/n): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] && return 1
    else
        read -rp "$message (y/N): " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && return 0
    fi
    return 1
}

# Wait for process to complete
wait_for_process() {
    local pid="$1"
    local timeout="${2:-30}"
    local count=0
    
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        ((count++))
        if [[ $count -gt $timeout ]]; then
            print_error "Process $pid timed out after $timeout seconds"
            return 1
        fi
    done
    return 0
}

# Source a file if it exists
safe_source() {
    local file="$1"
    if [[ -f "$file" && -r "$file" ]]; then
        source "$file"
        return 0
    else
        print_debug "File not found or not readable: $file"
        return 1
    fi
}

# Validate file exists and is readable
validate_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        print_error "File does not exist: $file"
        return 1
    fi
    if [[ ! -r "$file" ]]; then
        print_error "File not readable: $file"
        return 1
    fi
    return 0
}