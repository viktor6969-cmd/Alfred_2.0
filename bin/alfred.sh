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

# =============================================================================
# Resolve script directory and Alfred root (handles symlinks)
# =============================================================================

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE" # if $SOURCE was a relative symlink, resolve it relative to the path
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
ALFRED_ROOT="$(dirname "$SCRIPT_DIR")"

# Source utilities
if [[ -f "$ALFRED_ROOT/lib/utils.sh" ]]; then
    source "$ALFRED_ROOT/lib/utils.sh"
else
    echo "ERROR: Cannot find utils.sh at $ALFRED_ROOT/lib/utils.sh"
    echo "Make sure the Alfred installation directory structure is intact"
    exit 1
fi

if [[ -f "$ALFRED_ROOT/modules/ufw/ufw_functions.sh" ]]; then 
    source "$ALFRED_ROOT/modules/ufw/ufw_functions.sh"
else
    echo "ERROR: Missing dependency: $ALFRED_ROOT/modules/ufw/ufw_functions.sh"
    echo "Make sure the Alfred installation directory structure is intact"
    exit 1
fi

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
            if [[ ! -f "$MODULES_DIR/$module/${module}_install.sh" ]]; then
                status="${CYAN}[installation file missing!]${NC}"
            else
            status="${YELLOW}[available]${NC}"
            fi
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
        echo ""
    else
        print_warning "No info file found for module: $module"
        echo "Module directory: $module_dir"
    fi
}

manage_module() { # {$1 = <module_name>} {$2 = <action> (install,reinstall,remove) - Module installation/removal handler
    local module="$1"
    local action="$2"
    local module_dir="$MODULES_DIR/$module"
    local install_script="$module_dir/${module}_install.sh"
    
    if [[ ! -d "$module_dir" ]]; then
        print_error "Module not found: $module"
        return 1
    fi
    
    if [[ ! -f "$install_script" ]]; then
        print_error "Installation script not found: $install_script"
        return 1
    fi

    case "$action" in 
        install ) check_state "$module" "installed" && { print_warning "Module already installed: $module"; return 0; } ;;
        reinstall | remove ) check_state "$module" "installed" || { print_warning "Module not installed: $module"; return 0; } ;;
    esac

    # Run install script
    if bash "$install_script" "$action" ; then
        # Set appropriate status based on action
        case "$action" in
            install|reinstall) update_state "$module" "status" "installed" ;;
            remove) update_state "$module" "status" "not_installed" ;;
        esac
        print_success "Module ${action}ed successfully: $module"
    else
        update_state "$module" "status" "failed"
        print_error "Error occurred, $module wasn't ${action}ed successfully"
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

      --install)
            if [[ -z "$arg" ]]; then
                print_error "Please specify a module to install"
                echo "Usage: alfred --install <module> <module> ..."
                exit_code=1
            else
                if [[ "$arg" == "-y" ]]; then
                    local modules=()
                    while IFS= read -r module; do
                        modules+=("$module")
                    done < <(get_modules "not_installed")
                    
                    for module in "${modules[@]}"; do
                        manage_module "$module" "install" 
                        if [[ $? -ne 0 ]]; then
                            print_error "Failed to install module: $module"
                            confirm_action "Do you want to skip and continue with the next module? [y/N]" || break
                        fi
                    done
                    exit_code=0
                else
                    # Handle multiple modules or single module
                    shift # Remove --install
                    for module in "$@"; do
                        manage_module "$module" "install" 
                        local result=$?
                        if [[ $result -eq 0 ]]; then
                            print_success "Module installed: $module"
                        else
                            print_error "Failed to install module: $module"
                            exit_code=$result
                        fi
                    done
                fi
            fi
            ;;

    --remove | --reinstall)
            if [[ -z "$arg" ]]; then
                print_error "Please specify a module to ${command#--}"
                echo "Usage: alfred ${command} <module>"
                exit_code=1
            else
                confirm_action "Are you sure you want to ${command#--} "$arg" module ?" && manage_module "$arg" "${command#--}" 
                exit_code=$?
            fi
            ;;
 
    --reload-profiles)
            print_info "Reloading UFW application profiles..."
            if setup_app_profiles; then
                print_success "UFW application profiles reloaded successfully"
                return 0
            else
                print_error "Failed to reload UFW application profiles"
                return 1
            fi
            ;;

    --status) 
            local module="$arg"
            if [[ -z "$module" ]]; then
                print_error "Please specify a module to check status"
                echo "Usage: alfred --status <module>"
                exit_code=1
            fi

            [[ $module == "ufw" ]] && { get_ufw_status ; return 0 ;}

            if check_state "$module" "installed"; then
                print_success "Module is installed: $module"
            else
                print_info "Module is not installed: $module"
            fi
            exit_code=0
            ;;

    --ufw) 
            local mode="$arg"
            if [[ -z "$mode" ]]; then
                print_error "UFW profile is missing!"
                echo "Usage: alfred --ufw (open|close|hide)"
                exit_code=0
            fi
            check_state "$module" "installed" || {print_error "Ufw module is not installed, pleace run alfred --install ufw" ; return 0}
            set_profile "mode" && print_success "Curent rofile changed to $mod" || print_error "Failed to cahnge the profile" 
            ;;

    *)      print_error "Unknown option: $command"; print_help; exit_code=0;;
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