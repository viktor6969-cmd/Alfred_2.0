#!/usr/bin/env bash

# =================================================================================
# Printing & help
# =================================================================================
INFO="\e[33m[!]\e[0m "
ERROR="\e[31m[-]\e[0m "
SUCCESS="\e[32m[+]\e[0m "
YES_REGEX="^([yY]|yes|YES|Yes|yep)$" 

print_info()    { printf "%b%s\n" "$INFO"    "$*"; }
print_error()   { printf "%b%s\n" "$ERROR"   "$*"; }
print_success() { printf "%b%s\n" "$SUCCESS" "$*"; }
print_msg()     { printf " - %s\n"   "$*"; }

print_help() {
  cat <<'EOF'
Usage: server_auto.sh [OPTION]

Options:
  -u               Run only the "user" module and exit
  -y               Install all modules non-interactively (no prompts)
  -r <module>      Install/reinstall only the specified module
  -l               List available modules
  -i <module>      Show module description and whether it's installed
  -h               Show this help

Behavior:
  • Default (no flags): iterate modules, ASK before installing each.
  • Module entrypoint files must be: modules/<name>/<name>_setup.sh
  • Installed marker (stamp): modules/<name>/.installed
  • Dependencies listed in: modules/<name>/requirements.txt

Examples:
  ./server_auto.sh -u
  ./server_auto.sh -y
  ./server_auto.sh -r ufw
  ./server_auto.sh -i user
EOF
}

# =================================================================================
# Paths & config
# =================================================================================
UTILS_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
UTILS_DIR="$(cd "$(dirname "$UTILS_REAL")" && pwd)"
ROOT_DIR="$(cd "$UTILS_DIR/.." && pwd)"

CONFIG_DIR="$ROOT_DIR/config"
ENV_FILE="$CONFIG_DIR/.env"
CONF_FILE="$CONFIG_DIR/server.conf"

MODULES_DIR="$ROOT_DIR/modules"

BACKUP_DIR="$ROOT_DIR/.bkp"
mkdir -p "$BACKUP_DIR"

# =================================================================================
# Env file (.env)
# =================================================================================
ensure_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  if [[ -e "$ENV_FILE" ]] && [[ $(id -u) -eq 0 ]]; then
    chown root:root "$ENV_FILE" 2>/dev/null || true
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi
}

load_env() {
  ensure_env
  [[ -f "$ENV_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

# =================================================================================
# INI-style config (server.conf)
# =================================================================================

# Get scalar: section + key -> value (no quotes)
get_conf_value() {
  local section="$1" key="$2"
  [[ -f "$CONF_FILE" ]] || { print_error "Missing $CONF_FILE"; exit 1; }
  awk -v sec="$section" -v k="$key" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN{ INSIDE=0 }
    # normalize [ section ]  → [section]
    /^\[[[:space:]]*[^]]+\][[:space:]]*$/ {
      line=$0
      gsub(/[[:space:]]+/, "", line)
      if (line=="[" sec "]") { INSIDE=1 } else { INSIDE=0 }
      next
    }
    INSIDE {
      # skip blank / comment
      if ($0 ~ /^[[:space:]]*($|[#;])/) next

      # split ONLY on first =
      pos = index($0, "=")
      if (!pos) next
      key = trim(substr($0, 1, pos-1))
      val = trim(substr($0, pos+1))

      # strip inline comments (only if not quoted at end)
      if (val ~ /[[:space:]]*[#;][^"'"'"']*$/ && val !~ /^".*"[[:space:]]*[#;]/ && val !~ /^'\''.*'\''[[:space:]]*[#;]/)
        sub(/[[:space:]]*[#;].*$/, "", val)

      # unquote "..." or '...'
      if (val ~ /^".*"$/) { sub(/^"/,"",val); sub(/"$/,"",val) }
      else if (val ~ /^'\''.*'\''$/) { sub(/^'\''/,"",val); sub(/'\''$/,"",val) }

      if (key==k) { print val; exit }
    }
  ' "$CONF_FILE"
}

# Get whole section (raw text)
get_conf_section() {
  local section="$1"
  [[ -f "$CONF_FILE" ]] || { print_error "Missing $CONF_FILE"; exit 1; }
  awk -v sec="$section" '
    # match [ section ] with arbitrary spaces
    /^\[[[:space:]]*[^]]+\][[:space:]]*$/ {
      line=$0; gsub(/[[:space:]]+/, "", line)
      if (line=="[" sec "]") { INSIDE=1; next } else if (INSIDE) { exit }
    }
    INSIDE { print }
  ' "$CONF_FILE"
}

# Load required global scalars into env
load_server_conf() {
  SSH_PORT_BOOTSTRAP="$(get_conf_value global SSH_PORT_BOOTSTRAP)"
  SSH_PORT_FINAL="$(get_conf_value global SSH_PORT_FINAL)"
  MASTER_IP="$(get_conf_value global MASTER_IP)"
  [[ -n "$SSH_PORT_BOOTSTRAP" && -n "$SSH_PORT_FINAL" && -n "$MASTER_IP" ]] \
    || { print_error "server.conf: missing SSH_PORT_* or MASTER_IP in [global]"; exit 1; }
}

# Token renderer for common placeholders
render_vars() {
  local s="${1:-}"
  s="${s//\{\{SSH_PORT_BOOTSTRAP\}\}/$SSH_PORT_BOOTSTRAP}"
  s="${s//\{\{SSH_PORT_FINAL\}\}/$SSH_PORT_FINAL}"
  s="${s//\{\{MASTER_IP\}\}/$MASTER_IP}"
  printf '%s' "$s"
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

# Concat all [ufw.profile.*] sections -> applications.d/custom-profiles.conf
write_ufw_profiles() {
  local apps_dir="/etc/ufw/applications.d"
  mkdir -p "$apps_dir"
  
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

# #=============== Backups ===============================#
backup_file() {
  local src="$1"
  if [[ -z "${src:-}" || ! -r "$src" ]]; then
    print_error "Cannot read source file: $src"
    return 1
  fi
  local stamp base
  stamp="$(date +%Y%m%d-%H%M%S)"
  base="$(basename "$src")"
  cp "$src" "$BACKUP_DIR/$base.$stamp"
  print_success "Backed up $src -> $BACKUP_DIR/$base.$stamp"
}
