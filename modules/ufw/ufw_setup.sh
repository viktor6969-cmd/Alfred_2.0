#!/usr/bin/env bash
set -euo pipefail

# ==================================================================================
# UFW MODULE — baseline firewall configuration
# ==================================================================================
# Expectations:
# - Called by server_auto.sh (interactive or force mode)
# - Loads SSH/ports/master IP and profiles from config/server.conf via utils.sh
# - Secrets stay in config/.env (not used here)
# ==================================================================================

# ----------------------------------------------------------------------------------
# Global declarations
# ----------------------------------------------------------------------------------
SCRIPT_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
MODULE_DIR="$(cd "$(dirname "$SCRIPT_REAL")" && pwd)"
ROOT_DIR="$(cd "$MODULE_DIR/../.." && pwd)"
UTILS_DIR="$ROOT_DIR/utils"

# ----------------------------------------------------------------------------------
# Function definitions
# ----------------------------------------------------------------------------------

# Validate environment and dependencies
validate_environment() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || { 
        echo "Please run as root (sudo)."
        return 1
    }
    
    if [[ ! -f "$UTILS_DIR/utils.sh" ]]; then
        echo "utils.sh not found at $UTILS_DIR/utils.sh"
        return 1
    fi
    
    # shellcheck disable=SC1090
    source "$UTILS_DIR/utils.sh"
    load_server_conf
    
    # Validate critical configuration
    if [[ -z "${MASTER_IP:-}" ]]; then
        print_error "MASTER_IP not configured in server.conf"
        return 1
    fi
}

# Configure UFW base policies and master IP whitelist
configure_ufw_base() {
    local ufw_default_incoming ufw_default_outgoing
    
    print_msg "Reading UFW configuration..."
    ufw_default_incoming="$(get_conf_value ufw DEFAULT_INCOMING || true)"
    ufw_default_incoming="${ufw_default_incoming:-drop}"
    ufw_default_outgoing="$(get_conf_value ufw DEFAULT_OUTGOING || true)" 
    ufw_default_outgoing="${ufw_default_outgoing:-allow}"

    ufw --force reset >/dev/null 2>&1 || true

    print_info "Setting UFW default policies: incoming=$ufw_default_incoming, outgoing=$ufw_default_outgoing"
    ufw default "$ufw_default_incoming" incoming
    ufw default "$ufw_default_outgoing" outgoing

    print_info "Whitelisting management IP: $MASTER_IP"
    ufw allow from "$MASTER_IP"
    
    print_success "Base UFW configuration applied"
}

# Configure SSH access with safety checks
configure_ssh_access() {
    local current_ssh_port
    
    # Detect current SSH port
    current_ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1)
    
    print_warning "Current SSH is running on port: ${current_ssh_port:-22}"
    print_warning "MASTER_IP ($MASTER_IP) is already whitelisted for all ports"
    
    read -rp "Allow SSH access from any IP (using SSH-Custom profile)? (y/N): " ans
    echo
    if [[ $ans =~ $YES_REGEX ]]; then
        print_info "Enabling SSH-Custom profile for all IPs..."
        ufw allow SSH-Custom
    else
        print_info "SSH access restricted to MASTER_IP only"
        print_warning "Ensure you have console access in case of connection issues!"
    fi
}

# Concat all [ufw.profile.*] sections -> applications.d/custom-profiles.conf
write_ufw_profiles() {
  local apps_dir="/etc/ufw/applications.d"
  mkdir -p "$apps_dir"
  
  print_msg "Writing UFW application profiles from [ufw.profile.*]..."

  # Get template values from config
  local ssh_port_bootstrap ssh_port_final
  ssh_port_bootstrap=$(get_conf_value global SSH_PORT_BOOTSTRAP 2>/dev/null || echo "22")
  ssh_port_final=$(get_conf_value global SSH_PORT_FINAL 2>/dev/null || echo "22")
  
  awk -v ssh_bootstrap="$ssh_port_bootstrap" -v ssh_final="$ssh_port_final" '
    # Track when we are inside a ufw.profile section
    /^\[ufw\.profile\.[^]]+\][[:space:]]*$/ {
      profile_name = $0
      sub(/^\[ufw\.profile\./, "", profile_name)
      sub(/\][[:space:]]*$/, "", profile_name)
      in_ufw_section = 1
      print "[" profile_name "]"
      next
    }
    
    # If we encounter any other section header, stop processing ufw.profile section
    /^\[[^]]+\][[:space:]]*$/ && !/^\[ufw\.profile\./ {
      in_ufw_section = 0
      next
    }
    
    # Only print lines when we are inside a ufw.profile section
    in_ufw_section && NF {
      line = $0
      
      # Substitute template variables
      gsub(/{{SSH_PORT_BOOTSTRAP}}/, ssh_bootstrap, line)
      gsub(/{{SSH_PORT_FINAL}}/, ssh_final, line)
      
      print line
    }
  ' "$CONF_FILE" > "$apps_dir/custom-profiles.conf"
  
  print_success "Wrote UFW profiles -> $apps_dir/custom-profiles.conf"
}

# Write knockd.conf from [knockd.profile.*] (keeps %IP% intact)
write_knockd_config() {
  local out="/etc/knockd.conf"
  local tmp outtmp
  tmp="$(mktemp)" || { print_error "mktemp failed"; return 1; }
  outtmp="${tmp}.out"

  awk '
    # [knockd.profile.NAME] -> print as [NAME]
    /^\[[[:space:]]*knockd\.profile\.[^]]+\][[:space:]]*$/ {
      name=$0
      sub(/^\[[[:space:]]*knockd\.profile\./,"",name)
      sub(/\][[:space:]]*$/,"",name)
      if (printed) print ""
      print "[" name "]"
      printed=1; INSIDE=1; next
    }
    # new [section] closes current
    /^\[[[:space:]]*[^]]+\][[:space:]]*$/ { INSIDE=0; next }
    # copy body while inside a profile
    INSIDE { print }
  ' "$CONF_FILE" > "$tmp"

  render_vars "$(cat "$tmp")" > "$outtmp" || { rm -f "$tmp" "$outtmp"; print_error "render_vars failed"; return 1; }
  mv -f "$outtmp" "$out"
  rm -f "$tmp"
  chmod 640 "$out"
  chown root:root "$out" 2>/dev/null || true
  print_success "Wrote knockd config -> $out"
}

# Write SSH drop-ins from server.conf
write_ssh_bootstrap() {
  local boot
  boot="$(render_vars "$(get_conf_section ssh.bootstrap)")"
  [[ -n "$boot" ]] || { print_error "server.conf: [ssh.bootstrap] is empty"; exit 1; }
  printf '%s\n' "$boot" | tee /etc/ssh/sshd_config.d/99-bootstrap.conf >/dev/null
}

# Write SSH secure config from server.conf
write_ssh_secure() {
  local secure
  secure="$(render_vars "$(get_conf_section ssh.secure)")"
  [[ -n "$secure" ]] || { print_error "server.conf: [ssh.secure] is empty"; exit 1; }
  printf '%s\n' "$secure" | tee /etc/ssh/sshd_config.d/99-secure.conf >/dev/null
}

# Display final configuration summary
show_configuration_summary() {
    print_success "UFW configuration complete!"
    echo
    print_info "=== Configuration Summary ==="
    ufw status verbose
    echo
    print_info "SSH Access:"
    if ufw status | grep -q "SSH-Custom.*ALLOW"; then
        print_msg "✓ SSH allowed from any IP (port 42)"
    else
        print_msg "✓ SSH restricted to MASTER_IP only"
    fi
    
    if systemctl is-active --quiet knockd 2>/dev/null; then
        print_info "Port Knocking: ACTIVE"
        print_msg "Use knock sequences to open services temporarily"
    fi
    
    print_warning "Always test SSH access before closing your current session!"
}


# ----------------------------------------------------------------------------------
# Main function
# ----------------------------------------------------------------------------------
main() {
    local exit_code=0
    
    print_msg "Starting UFW firewall configuration..."
    
    # Phase 1: Environment validation
    validate_environment          || { print_error "Environment validation failed"; exit_code=1; }
    
    # Phase 2: Core UFW configuration
    configure_ufw_base            || { print_error "UFW base configuration failed"; exit_code=1; }

    # Phase 3: Service-specific configurations
    configure_ssh_access          || { print_error "SSH configuration failed"; exit_code=1; }
    
    # Phase 4: Enable UFW with profiles
    write_ufw_profiles            || { print_error "UFW profile setup failed"; exit_code=1; }
    
    # Phase 5: Knockd configuration (optional)
    write_knockd_config           || { print_error "knockd configuration failed"; exit_code=1; }

    # Phase 5.1: Automatic updates (optional)
    configure_automatic_updates   || { print_error "Automatic updates configuration failed"; exit_code=1; }
    
    # Phase 6: Final summary
    show_configuration_summary
    
    return $exit_code
}

# ----------------------------------------------------------------------------------
# Execution guard
# ----------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit_code=$?
    exit $exit_code
fi