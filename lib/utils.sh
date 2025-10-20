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

# Yes regex for confirmation prompts
readonly YES_REGEX='^(yes|y|Y)$'
# Debug mode
readonly debug=0

# =============================================================================
# Print Functions
# =============================================================================
print_info() { echo -e "$1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_debug() { [[ $debug -eq 1 ]] && echo -e "${CYAN}[-]${NC} $1"; } # Only print if debug mode is enabled
print_header() {
    echo -e "${BLUE}==============================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==============================${NC}"
}
print_help() {
    peint_logo
    echo
    priont_info "Alfred - Minimal System Setup"
    echo
}
print_logo(){
    echo -e "
  ___  _  __              _   _____  _____ 
 / _ \| |/ _|            | | / __  \|  _  |
/ /_\ \ | |_ _ __ ___  __| | `' / /'| |/' |
|  _  | |  _| '__/ _ \/ _` |   / /  |  /| |
| | | | | | | | |  __/ (_| | ./ /___\ |_/ /
\_| |_/_|_| |_|  \___|\__,_| \_____(_)___/ 
    "
}

# =============================================================================
# Input Validation Functions
# =============================================================================

# Validate component name (safe for filenames)
validate_component_name() {
    local component="$1"
    [[ -n "$component" && "$component" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Validate port number
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

# =============================================================================
# Action Functions
# =============================================================================

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

# Create directory if it doesn't exist
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

# Safely source a file if it exists
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
# Get current timestamp
get_timestamp() {
    date -Iseconds
}

# Confirm action with user
confirm_action() {
    local message="$1"   
    read -rp "$message (y/N): " ans; echo
    [[ $ans =~ ^[Yy]$ ]] && return 0 || return 1
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


# =============================================================================
# PID Management Functions
# =============================================================================

# Create PID file and check for existing process
make_pid() {
    local component="$1"
    local pid_dir="/var/run/alfred"
    local pid_file="${pid_dir}/${component}.pid"
    
    create_directory "$pid_dir" "755"
    
    if is_running_pid "$component"; then
        print_error "$component is already running"
        return 1
    fi
    
    # Create PID file
    echo $$ > "$pid_file"
    print_debug "Created PID file: $pid_file"
    return 0
}

# Remove PID file
relise_pid() {
    local component="$1"
    local pid_file="/var/run/alfred/${component}.pid"
    
    if [[ -f "$pid_file" ]]; then
        rm -f "$pid_file"
        print_debug "PID file removed: $pid_file"
    fi
}

# Check if component is running
is_running_pid() {
    local component="$1"
    local pid_file="/var/run/alfred/${component}.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # Process is dead, clean up stale PID file
            rm -f "$pid_file"
        fi
    fi
    return 1
}


# =============================================================================
# JSON State Management Functions
# =============================================================================

# Initialize state file for a component
make_state() {
    local component="$1"
    local state_dir="/var/lib/alfred/state"
    local state_file="${state_dir}/${component}.json"
    
    create_directory "$state_dir" "700"
    
    if [[ ! -f "$state_file" ]]; then
        cat > "$state_file" << EOF
{
    "component": "$component",
    "status": "not_started",
    "created_at": "$(get_timestamp)",
    "last_updated": "$(get_timestamp)"
}
EOF
        chmod 600 "$state_file"
        print_debug "Initialized state file: $state_file"
    fi
}

# Update state file with new status
update_state() { # {$1 component} {$2 status}
    local component="$1"
    local status="$2"
    local state_file="/var/lib/alfred/state/${component}.json"
    
    if command_exists jq && [[ -f "$state_file" ]]; then
        jq ".status = \"$status\" | .last_updated = \"$(get_timestamp)\"" "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
        print_debug "Updated state for $component: $status"
    fi
}

# Read value from state file
read_state() {
    local component="$1"
    local key="$2"
    local state_file="/var/lib/alfred/state/${component}.json"
    
    if command_exists jq && [[ -f "$state_file" ]]; then
        jq -r ".${key}" "$state_file" 2>/dev/null
    fi
}

# Check if component is in specific state
check_state() {
    local component="$1"
    local expected_status="$2"
    
    local current_status
    current_status=$(read_state "$component" "status")
    [[ "$current_status" == "$expected_status" ]]
}