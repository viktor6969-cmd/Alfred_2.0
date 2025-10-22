#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# SERVER_AUTO — main entrypoint for modular server setup automation
# ==================================================================================
# Usage:
#   -y            Install all modules (no questions). UFW runs first if missing.
#   -u            Run only the user module
#   -r <module>   Install/reinstall a specific module (prompts if already installed)
#   -l            List all modules with descriptions
#   -i <module>   Show module description + installed status
#   -h            print help and exit
#   (no args)     Interactive mode; UFW runs first if missing, then prompts per module
#
# Notes:
#   • Run as root (sudo).
#   • Install stamps live in /var/lib/serverctl/modules/<module>.stamp
#   • Modules are discovered under ./modules/<name>/setup.sh
#   • Config: ./config/server.conf (INI-style), parsed by utils.sh
# ==================================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALFRED_ROOT="$(dirname "$SCRIPT_DIR")"

# Source utilities
source "$ALFRED_ROOT/lib/utils.sh"

# =============================================================================
# Configuration
# =============================================================================

readonly MODULES_DIR="$ALFRED_ROOT/modules"
readonly REPO_FILE="/var/lib/alfred/repo.json"

# =================================================================================
# Module management functions
# =================================================================================

list_modules() { # {no args} - List available modules
    print_header "Available Modules"
    
    local modules=()
    while IFS= read -r module; do
        modules+=("$module")
    done < <(get_modules "all")
    
    if [[ ${#modules[@]} -eq 0 ]]; then
        print_warning "No modules found"
        return 0
    fi
    
    for module in "${modules[@]}"; do
        local status
        if check_state "$module" "installed"; then
            status="${GREEN}[installed]${NC}"
        else 
            if [[ -f "$MODULES_DIR/$module/${module}_install.sh" ]]; then
                status="${CYAN}[installation file missing!]${NC}"
            else
            status="${YELLOW}[available]${NC}"
        fi
        echo -e "  • $module - $status"
    done
}

module_info() { # {$1 = <module_name>} - Show module information
    local module="$1"
    local module_dir="$MODULES_DIR/$module"
    local info_file="$module_dir/${module}.info"
    
    if [[ ! -d "$module_dir" ]]; then
        print_error "Module not found: $module"
        return 1
    fi
    
    print_header "Module Info: $module"
    
    if [[ -f "$info_file" ]]; then
        cat "$info_file"
    else
        print_warning "No info file found for module: $module"
        echo "Module directory: $module_dir"
    fi
}

install_module() { # {$1 = <module_name>} - Install a module
    local module="$1"
    local module_dir="$MODULES_DIR/$module"
    local install_script="$module_dir/${module}_install.sh"
    
    if [[ ! -d "$module_dir" ]]; then
        print_error "Module not found: $module"
        return 1
    fi
    
    if check_state "$module" "installed"; then
        print_warning "Module already installed: $module"
        return 0
    fi
    
    if [[ ! -f "$install_script" ]]; then
        print_error "Install script not found: $install_script"
        return 1
    fi
    
    print_header "Installing Module: $module"
    
    # Create module state
    make_state "$module"
    update_state "$module" "installation_in_progress"

    # Run install script
    if bash "$install_script"; then
        update_state "$module" "installed"
        print_success "Module installed successfully: $module"
    else
        update_state "$module" "failed"
        print_error "Module installation failed: $module"
        return 1
    fi
}

remove_module() { # {$1 = <module_name>} - Remove a module
    local module="$1"
    local module_dir="$MODULES_DIR/$module"
    local remove_script="$module_dir/${module}_remove.sh"
    
    if [[ ! -d "$module_dir" ]]; then
        print_error "Module not found: $module"
        return 1
    fi
    
    if ! check_state "$module" "installed"; then
        print_warning "Module not installed: $module"
        return 0
    fi
    
    if [[ ! -f "$remove_script" ]]; then
        print_error "Remove script not found: $remove_script"
        return 1
    fi
    
    print_header "Removing Module: $module"
    
    if ! confirm_action "Are you sure you want to remove $module?"; then
        print_info "Removal cancelled"
        return 0
    fi
    
    # Run remove script
    if bash "$remove_script"; then
        update_state "$module" "not_installed"
        print_success "Module removed successfully: $module"
    else
        update_state "$module" "remove_failed"
        print_error "Module removal failed: $module"
        return 1
    fi
}

get_modules() { # {$1 = <filter> (optional: installed|not_installed|all)>} - Get list of modules with optional filter
    local filter="${1:-all}"
    
    if [[ ! -d "$MODULES_DIR" ]]; then
        return 1
    fi
    
    for module_dir in "$MODULES_DIR"/*; do
        if [[ -d "$module_dir" ]]; then
            local module_name
            module_name=$(basename "$module_dir")
            
            case "$filter" in
                "installed") check_state "$module_name" "installed" && echo "$module_name" ;;
                "not_installed") check_state "$module_name" "installed" || echo "$module_name" ;;
                "all") echo "$module_name" ;;
            esac
        fi
    done
}

handle_unexpected_error() {
    local exit_code=$?
    print_error "Unexpected error occurred (line: ${BASH_LINENO[0]}). Exiting."
    exit $exit_code
}
# =================================================================================
# Main function
# =================================================================================

main() { # {$@ = <command> <args>} - Main command handler

    check_root

    local command="${1:-}"
    local arg="${2:-}"
    local exit_code=0
     
    case "$command" in
    -h)     print_help; exit_code=0 ;;
    "")     get_modules; exit_code=0 ;;
    -u)     exit_code=0 ;;

    -i|--info)
            if [[ -z "$arg" ]]; then
                print_error "Please specify a module to show info"
                echo "Usage: alfred -i <module>"
                exit_code=1
            else
                module_info "$arg"
                exit_code=0
            fi
            ;;

    -l|--list)  
            if [[ "$arg" == "-i" ]]; then
                # List only installed modules
                while IFS= read -r module; do
                    echo "$module"
                done < <(get_modules "installed")
            else
                # List all modules
                list_modules
            fi
            exit_code=0 
            ;;

    "--install" | "--remove")
            local state_action
            [[ "$command" == "--install" ]] && state_action="installed" || state_action="not_installed"

            if [[ -z "$arg" ]]; then
                print_error "Please specify a module to install"
                echo "Usage: alfred -install <module>"
                return 1
            fi

            if [[ "$arg" == "-y" ]]; then
                local modules=()
                while IFS= read -r module; do
                    modules+=("$module")
                done < <(get_modules "$state_action")

                for module in "${modules[@]}"; do
                    [[ "$command" == "--install" ]] && install_module "$module" || remove_module "$module"
                done
                return 0
            fi
            [[ "$command" == "--install" ]] && install_module "$arg" || remove_module "$arg"
            ;;

    "--reinstall")
            if [[ -z "$arg" ]]; then
                print_error "Please specify a module to reinstall"
                echo "Usage: alfred --reinstall <module>"
                return 0
            fi
            remove_module "$arg" && install_module "$arg"
            exit_code=$?
            ;;
 

    *)      print_error "Unknown option: $command"; print_help; exit_code=1;;
  esac 
  return $exit_code
}

# ==================================================================================
# EXECUTION GUARD & CLEANUP
# ==================================================================================

# Only run main if script is executed, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Set up error trapping
    trap 'handle_unexpected_error' ERR
    
    # Execute main with all arguments
    main "$@"
    exit_code=$?
    
    # Final exit with proper code
    exit $exit_code
fi