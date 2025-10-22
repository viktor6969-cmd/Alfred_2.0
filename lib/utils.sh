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
    echo -e "=============================="
    echo -e "$1"
    echo -e "=============================="
}

print_help() { # {no args} - Print usage information
    cat << EOF
$(print_header "Alfred - Server Setup Automation")

Usage: alfred [OPTION] [MODULE]

Options:
  -h, --help          Show this help message and exit
  -l, --list          List all available modules
      --list -i       List only installed modules
  -i, --info MODULE   Show module description and installation status
  -u, --user          Run only the user module
  --install MODULE    Install a specific module
  --remove MODULE     Remove a specific module
  --reinstall MODULE  Reinstall a specific module

Examples:
  alfred --list                    # List all modules
  alfred --list -i                 # List only installed modules  
  alfred --info nginx              # Show nginx module info
  alfred --install docker          # Install docker module
  alfred --remove mysql            # Remove mysql module
  alfred --user                    # Run user module only

Note: Run with sudo for full functionality
EOF
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
get_timestamp() { # {no args} - Get current timestamp
    date '+%Y-%m-%d %H:%M:%S %Z'
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

install_pkgs() {
    local pkges=("$@")
    for pkg in "${pkges[@]}"; do
        if command_exists "$pkg"; then  # Fixed: command -exists → command_exists
            print_debug "$pkg already installed"
            continue
        fi
        sudo apt-get update
        if sudo apt-get install -y -q "$pkg"; then
            print_success "$pkg installed successfully"
            continue
        else
            print_info "Failed to install $pkg, please install it manually and try again."
            return 1
        fi
    done
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
    local state_dir="/var/lib/alfred/state/"
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

# Initialize module-specific state data
init_module_state() { # {$1 = <component>} {$2 = <json_data>}
    local component="$1"
    local json_data="$2"
    local state_file="/var/lib/alfred/state/${component}.json"
    
    if [[ ! -f "$state_file" ]]; then
        print_error "State file does not exist: $state_file. Run make_state first."
        return 1
    fi
    if command_exists jq; then
        # Merge the existing state with the new module data
        jq --argjson new_data "$json_data" '. + $new_data' "$state_file" > "${state_file}.tmp" && \
        mv "${state_file}.tmp" "$state_file"
        
        print_debug "Initialized module state for: $component"
    else
        print_error "jq not available - cannot initialize module state"
        return 1
    fi
}

# Update state file with new status
update_state() { # {$1 = <component>} {$2 = <key>} {$3 = <value>} - Update specific key in state file
    local component="$1"
    local key="$2"
    local value="$3"
    local state_file="/var/lib/alfred/state/${component}.json"
    
    if command_exists jq && [[ -f "$state_file" ]]; then
        # Handle different value types (string, number, boolean, array, object)
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            # Number
            jq --arg key "$key" --argjson val "$value" --arg timestamp "$(get_timestamp)" \
               '.[$key] = $val | .last_updated = $timestamp' \
               "$state_file" > "${state_file}.tmp"
        elif [[ "$value" =~ ^(true|false)$ ]]; then
            # Boolean
            jq --arg key "$key" --argjson val "$value" --arg timestamp "$(get_timestamp)" \
               '.[$key] = $val | .last_updated = $timestamp' \
               "$state_file" > "${state_file}.tmp"
        elif [[ "$value" =~ ^\[.*\]$ || "$value" =~ ^\{.*\}$ ]]; then
            # Array or Object
            jq --arg key "$key" --argjson val "$value" --arg timestamp "$(get_timestamp)" \
               '.[$key] = $val | .last_updated = $timestamp' \
               "$state_file" > "${state_file}.tmp"
        else
            # String (default)
            jq --arg key "$key" --arg val "$value" --arg timestamp "$(get_timestamp)" \
               '.[$key] = $val | .last_updated = $timestamp' \
               "$state_file" > "${state_file}.tmp"
        fi
        
        if mv "${state_file}.tmp" "$state_file"; then
            print_debug "Updated state: $component.$key = $value"
        else
            print_error "Failed to update state: $component.$key"
            return 1
        fi
    else
        
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


# =============================================================================
# Backup Functions  
# =============================================================================

create_backup() { # {$1 = <component>} {$2 = <file_path>} - Create backup of file with timestamp
    local component="$1"
    local file_path="$2"
    local backup_dir="/var/lib/alfred/backups/$component"
    
    if [[ ! -f "$file_path" ]]; then
        print_debug "File not found, skipping backup: $file_path"
        return 1
    fi
    
    create_directory "$backup_dir" "700"
    
    local filename
    filename=$(basename "$file_path")
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/${filename}.${timestamp}.bak"
    
    if cp "$file_path" "$backup_file"; then
        print_debug "Backup created: $backup_file"
        return 0
    else
        print_error "Failed to create backup: $file_path"
        return 1
    fi
}

restore_backup() { # {$1 = <component>} {$2 = <file_path>} {$3 = <backup_timestamp> (optional)} - Restore file from backup
    local component="$1"
    local file_path="$2"
    local timestamp="$3"
    local backup_dir="/var/lib/alfred/backups/$component"
    
    if [[ ! -d "$backup_dir" ]]; then
        print_error "No backups found for component: $component"
        return 1
    fi
    
    local filename
    filename=$(basename "$file_path")
    local backup_file
    
    if [[ -n "$timestamp" ]]; then
        # Restore specific backup
        backup_file="$backup_dir/${filename}.${timestamp}.bak"
        if [[ ! -f "$backup_file" ]]; then
            print_error "Specific backup not found: $backup_file"
            return 1
        fi
    else
        # Restore latest backup
        backup_file=$(find "$backup_dir" -name "${filename}.*.bak" | sort -r | head -1)
        if [[ -z "$backup_file" ]]; then
            print_error "No backups found for file: $filename"
            return 1
        fi
    fi
    
    # Create directory for target file if it doesn't exist
    local target_dir
    target_dir=$(dirname "$file_path")
    create_directory "$target_dir" "755"
    
    if cp "$backup_file" "$file_path"; then
        print_success "Backup restored: $file_path"
        return 0
    else
        print_error "Failed to restore backup: $file_path"
        return 1
    fi
}

list_backups() { # {$1 = <component>} - List available backups for component
    local component="$1"
    local backup_dir="/var/lib/alfred/backups/$component"
    
    if [[ ! -d "$backup_dir" ]]; then
        print_error "No backups found for component: $component"
        return 1
    fi
    
    print_header "Backups for: $component"
    find "$backup_dir" -name "*.bak" | sort -r | while read -r backup; do
        local size
        size=$(du -h "$backup" | cut -f1)
        local date
        date=$(stat -c %y "$backup" | cut -d' ' -f1)
        local time
        time=$(stat -c %y "$backup" | cut -d' ' -f2 | cut -d'.' -f1)
        echo -e "  • $(basename "$backup") - ${size} - ${date} ${time}"
    done
}

clean_old_backups() { # {$1 = <component>} {$2 = <days_to_keep>} - Remove backups older than specified days
    local component="$1"
    local days_to_keep="${2:-30}"
    local backup_dir="/var/lib/alfred/backups/$component"
    
    if [[ ! -d "$backup_dir" ]]; then
        print_debug "No backups found for component: $component"
        return 0
    fi
    
    local deleted_count
    deleted_count=$(find "$backup_dir" -name "*.bak" -mtime "+$days_to_keep" -delete -print | wc -l)
    
    if [[ $deleted_count -gt 0 ]]; then
        print_info "Removed $deleted_count backups older than $days_to_keep days for: $component"
    else
        print_debug "No old backups found for: $component"
    fi
}