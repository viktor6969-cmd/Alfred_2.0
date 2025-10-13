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

print_help() {
  cat <<'EOF'
Usage: ./server_auto.sh [-y|-u|-r <module>|-l|-i <module>|-h]
  -y            install all modules (no prompts); UFW first if missing
  -u            run only the user module
  -r <module>   reinstall a specific module (prompts if already installed)
  -l            list available modules
  -i <module>   show module description and installed status
  -h            show this help
  (no args)     interactive mode; UFW first if missing, then ask per module
EOF
}

# =================================================================================
# Paths & config
# =================================================================================
UTILS_REAL="$(readlink -f "${BASH_SOURCE[0]}")"
UTILS_DIR="$(cd "$(dirname "$UTILS_REAL")" && pwd)"
ROOT_DIR="$(cd "$UTILS_DIR/.." && pwd)"
MODULES_DIR="$(cd "$(dirname "$ROOT_DIR/modules")" && pwd)"

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
  local s="$1"
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
  : > "$apps_dir/custom-profiles.conf"
  awk '
    /^\[[[:space:]]*ufw\.profile\.[^]]+\][[:space:]]*$/ { INSIDE=1; next }
    /^\[/ && INSIDE { print ""; INSIDE=0 }
    INSIDE { print }
  ' "$CONF_FILE" | render_vars >> "$apps_dir/custom-profiles.conf"
  print_success "Wrote UFW profiles -> $apps_dir/custom-profiles.conf"
}

# Write knockd.conf from [knockd.profile.*] (keeps %IP% intact)
write_knockd_config() {
  local out="/etc/knockd.conf"
  : > "$out.tmp"
  awk '
    /^\[[[:space:]]*knockd\.profile\.[^]]+\][[:space:]]*$/ { INSIDE=1; next }
    /^\[/ && INSIDE { print ""; INSIDE=0 }
    INSIDE { print }
  ' "$CONF_FILE" > "$out.tmp"
  mv -f "$out.tmp" "$out"
  chmod 640 "$out"
  chown root:root "$out" 2>/dev/null || true
  print_success "Wrote knockd config -> $out"
}

# =================================================================================
# Module management
# =================================================================================

is_installed() { [[ -f "$MODULES_DIR/$1/.stamp" ]]; }

valid_module() { [[ "$1" =~ ^[a-z0-9_-]+$ ]]; }

mark_installed() { touch "$MODULES_DIR/$1/.installed"; }

clear_installed() { rm -f "$STAMP_DIR/$1.stamp"; }

module_exists() { [[ -f "$MODULES_DIR/$1/"$1"_setup.sh" ]]; }

discover_modules() { find "$MODULES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort ;}

module_desc() {
  [[ -f "$MODULES_DIR/$1/description.txt" ]] && cat "$MODULES_DIR/$1/description.txt" || echo "$1 module"
}

module_reqs() {
  local f="$MODULES_DIR/$1/requirements.txt"
  [[ -f "$f" ]] || return 0
  tr ' ' '\n' < "$f" | sed '/^$/d'
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
