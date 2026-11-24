#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script Name: install.sh
# Description: Main installation script for Appmotel PaaS system
# Can be run as root (full installation) or as appmotel user (user-level only)
# -----------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# Constants
# Handle both direct execution and piped execution (curl | bash)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  readonly SCRIPT_DIR="$(pwd)"
fi
readonly APPMOTEL_USER="appmotel"
readonly APPMOTEL_HOME="/home/${APPMOTEL_USER}"

# -----------------------------------------------------------------------------
# Function: detect_os
# Description: Detects the operating system type
# Returns: "debian", "rhel", or "unknown"
# -----------------------------------------------------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID}" in
      debian|ubuntu|linuxmint|pop)
        echo "debian"
        return
        ;;
      rhel|centos|fedora|rocky|almalinux)
        echo "rhel"
        return
        ;;
    esac
  fi

  # Fallback detection
  if command -v apt-get >/dev/null 2>&1; then
    echo "debian"
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    echo "rhel"
  else
    echo "unknown"
  fi
}

# -----------------------------------------------------------------------------
# Function: install_required_packages
# Description: Installs required system packages (git)
# Note: Must be run as root
# Note: curl-minimal is pre-installed on Amazon Linux 2023 and conflicts with curl
# -----------------------------------------------------------------------------
install_required_packages() {
  local os_family
  os_family=$(detect_os)

  # Build list of missing packages
  # python3-venv / python3-pip are required for Python/Flask app deployments
  local packages_needed=()

  command -v git >/dev/null 2>&1 \
    || packages_needed+=(git)
  python3 -c "import ensurepip" >/dev/null 2>&1 \
    || packages_needed+=(python3-venv)
  command -v pip3 >/dev/null 2>&1 \
    || packages_needed+=(python3-pip)
  # nft: app ports may only be reached from this host (install_app_port_firewall)
  command -v nft >/dev/null 2>&1 \
    || packages_needed+=(nftables)

  if [[ ${#packages_needed[@]} -eq 0 ]]; then
    return 0
  fi

  log_msg "INFO" "Installing required packages: ${packages_needed[*]}"

  case "${os_family}" in
    debian)
      apt-get update -qq
      apt-get install -y -qq "${packages_needed[@]}"
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${packages_needed[@]}"
      else
        yum install -y -q "${packages_needed[@]}"
      fi
      ;;
    *)
      log_msg "WARN" "Cannot install packages automatically on this OS."
      log_msg "WARN" "Please install manually: ${packages_needed[*]}"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Function: log_msg
# Description: Prints messages with timestamp
# -----------------------------------------------------------------------------
log_msg() {
  local level="$1"
  local msg="$2"
  printf "[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n" -1 "${level}" "${msg}" >&2
}

# -----------------------------------------------------------------------------
# Function: die
# Description: Prints error message and exits
# -----------------------------------------------------------------------------
die() {
  log_msg "ERROR" "$1"
  exit 1
}

# -----------------------------------------------------------------------------
# Function: port80_usable
# Description: Best local guess that Let's Encrypt HTTP-01 can reach Traefik:
#   nothing else listens on port 80, and an active ufw/firewalld allows it.
#   It cannot see outside firewalls (for example an AWS security group); if
#   those block port 80, Traefik only logs failed ACME attempts.
# -----------------------------------------------------------------------------
port80_usable() {
  local listeners
  listeners=$(ss -Hltnp 'sport = :80' 2>/dev/null | grep -v '"traefik"' || true)
  if [[ -n "${listeners}" ]]; then
    log_msg "INFO" "Port 80 is used by another program: ${listeners}"
    return 1
  fi
  local ufw_out
  ufw_out=$(ufw status verbose 2>/dev/null || true)
  if grep -q '^Status: active' <<< "${ufw_out}" && ! grep -q 'Default: allow (incoming)' <<< "${ufw_out}"; then
    if ! grep -qE '^(80|80,443|443,80)(/tcp)?[[:space:]].*ALLOW|^(WWW|WWW Full|Nginx HTTP|Nginx Full|Apache|Apache Full)[[:space:]].*ALLOW' <<< "${ufw_out}"; then
      log_msg "INFO" "ufw is active and does not allow port 80"
      return 1
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    if ! firewall-cmd --list-services 2>/dev/null | grep -qw http && \
       ! firewall-cmd --list-ports 2>/dev/null | grep -qw '80/tcp'; then
      log_msg "INFO" "firewalld is active and does not allow port 80"
      return 1
    fi
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Function: load_env
# Description: Loads configuration from .env file
# Location: Uses fixed path /home/appmotel/.config/appmotel/.env
#           This allows both root and user installations to access the same config
# -----------------------------------------------------------------------------
load_env() {
  local config_dir="${APPMOTEL_HOME}/.config/appmotel"
  local env_file="${config_dir}/.env"
  local env_default_local="${SCRIPT_DIR}/.env.default"
  local github_env_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/.env.default?$(date +%s)"

  # Create config directory if it doesn't exist
  mkdir -p "${config_dir}"

  # Load .env file if it exists
  if [[ -f "${env_file}" ]]; then
    set -o allexport
    source "${env_file}"
    set +o allexport
    log_msg "INFO" "Loaded configuration from ${env_file}"
    return
  fi

  # Try to use local .env.default first (from repo)
  local env_default_source=""
  if [[ -f "${env_default_local}" ]]; then
    env_default_source="${env_default_local}"
    log_msg "INFO" "Using local .env.default from repository"
  else
    # Download .env.default from GitHub
    log_msg "INFO" "Downloading .env.default from GitHub"
    local temp_env_default="/tmp/.env.default.$$"
    if curl -fsSL "${github_env_url}" -o "${temp_env_default}"; then
      env_default_source="${temp_env_default}"
      log_msg "INFO" "Downloaded .env.default successfully"
    else
      die "Failed to download .env.default from GitHub"
    fi
  fi

  # Copy .env.default to .env
  log_msg "WARN" "No .env file found at ${env_file}"
  log_msg "INFO" "Creating .env from .env.default"
  cp "${env_default_source}" "${env_file}"

  # Clean up temp file if we downloaded it
  if [[ "${env_default_source}" == /tmp/* ]]; then
    rm -f "${env_default_source}"
  fi

  # Source the .env file
  set -o allexport
  source "${env_file}"
  set +o allexport

  # New install: turn on Let's Encrypt (HTTP-01) when no wildcard cert for
  # BASE_DOMAIN exists and port 80 looks usable; a matching cert added later
  # still wins (see generate_traefik_config)
  if [[ "${USE_LETSENCRYPT:-no}" != "yes" ]] && [[ -z "$(find_existing_wildcard_cert)" ]]; then
    if port80_usable; then
      sed -i 's|^USE_LETSENCRYPT=.*|USE_LETSENCRYPT=yes      # set by install.sh: no wildcard cert found, port 80 usable|' "${env_file}"
      USE_LETSENCRYPT="yes"
      log_msg "INFO" "No wildcard certificate found and port 80 is usable: USE_LETSENCRYPT=yes"
    else
      log_msg "WARN" "Let's Encrypt not turned on (port 80 not usable); set USE_LETSENCRYPT=yes in ${env_file} when it is"
    fi
  fi

  # Auto-detect timezone from IP geolocation if TZ is not set
  if ! grep -q "^TZ=" "${env_file}" 2>/dev/null; then
    local detected_tz=""
    # Try ip-api.com first (free, no API key needed)
    detected_tz=$(curl -fsSL --max-time 5 "http://ip-api.com/line/?fields=timezone" 2>/dev/null)
    if [[ -z "${detected_tz}" ]] || [[ "${detected_tz}" == "fail" ]]; then
      # Fallback to ipinfo.io
      detected_tz=$(curl -fsSL --max-time 5 "https://ipinfo.io/timezone" 2>/dev/null)
    fi
    if [[ -n "${detected_tz}" ]] && [[ "${detected_tz}" =~ ^[A-Za-z_]+/[A-Za-z_]+$ ]]; then
      echo "" >> "${env_file}"
      echo "# Timezone (auto-detected from IP geolocation)" >> "${env_file}"
      echo "TZ=\"${detected_tz}\"" >> "${env_file}"
      log_msg "INFO" "Auto-detected timezone: ${detected_tz}"
    else
      log_msg "WARN" "Could not auto-detect timezone, using UTC"
      echo "" >> "${env_file}"
      echo "# Timezone (set manually or leave as UTC)" >> "${env_file}"
      echo "TZ=\"UTC\"" >> "${env_file}"
    fi
  fi

  log_msg "WARN" "Please edit ${env_file} with your settings"
  log_msg "INFO" "Configuration file created at ${env_file}"
}

# =============================================================================
# SYSTEM-LEVEL INSTALLATION (requires root)
# =============================================================================

# -----------------------------------------------------------------------------
# Function: create_appmotel_user
# Description: Creates appmotel user if it doesn't exist
# -----------------------------------------------------------------------------
create_appmotel_user() {
  if id "${APPMOTEL_USER}" &>/dev/null; then
    log_msg "INFO" "User ${APPMOTEL_USER} already exists"
  else
    log_msg "INFO" "Creating user ${APPMOTEL_USER}"
    useradd --system --create-home --shell /bin/bash "${APPMOTEL_USER}"
  fi
}

# -----------------------------------------------------------------------------
# Function: detect_aws
# Description: Returns 0 if running on AWS EC2, 1 otherwise
# Checks IMDS reachability (works without an IAM role)
# -----------------------------------------------------------------------------
detect_aws() {
  curl -sf --connect-timeout 2 "http://169.254.169.254/latest/meta-data/instance-id" \
    -o /dev/null 2>/dev/null
}

# -----------------------------------------------------------------------------
# Function: setup_local_dns
# Description: Configures dnsmasq to resolve *.BASE_DOMAIN to the private IP
# Workaround for AWS hairpin NAT: the server cannot reach its own Elastic IP,
# so we intercept *.BASE_DOMAIN queries locally and return the private IP.
# Only runs on AWS when BASE_DOMAIN is set to a real domain.
# Safe to re-run (idempotent).
# -----------------------------------------------------------------------------
setup_local_dns() {
  if ! detect_aws; then
    return 0
  fi

  # Skip if BASE_DOMAIN is unset or still a placeholder
  if [[ -z "${BASE_DOMAIN:-}" ]] || \
     [[ "${BASE_DOMAIN}" == *"example"* ]] || \
     [[ "${BASE_DOMAIN}" == *"yourdomain"* ]]; then
    log_msg "INFO" "AWS detected but BASE_DOMAIN not configured yet - skipping local DNS setup"
    log_msg "INFO" "Re-run 'sudo bash install.sh' after setting BASE_DOMAIN in ${APPMOTEL_HOME}/.config/appmotel/.env"
    return 0
  fi

  log_msg "INFO" "AWS detected: configuring local DNS for *.${BASE_DOMAIN}"

  # Get private IP of this instance
  local private_ip
  private_ip=$(hostname -I | awk '{print $1}')
  if [[ -z "${private_ip}" ]]; then
    log_msg "WARN" "Could not determine private IP - skipping local DNS setup"
    return 0
  fi

  # Capture current upstream DNS before we touch anything
  local upstream_dns
  upstream_dns=$(resolvectl status 2>/dev/null | awk '/Current DNS Server:/{print $NF; exit}' || true)
  if [[ -z "${upstream_dns}" ]]; then
    upstream_dns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
  fi
  # Final fallback: AWS VPC DNS is always at .2 of the VPC CIDR
  [[ -z "${upstream_dns}" ]] && upstream_dns="169.254.169.253"

  # Install dnsmasq
  local os_family
  os_family=$(detect_os)
  case "${os_family}" in
    debian) apt-get install -y -qq dnsmasq >/dev/null 2>&1 || true ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y -q dnsmasq >/dev/null 2>&1 || true
      else
        yum install -y -q dnsmasq >/dev/null 2>&1 || true
      fi
      ;;
  esac

  if ! command -v dnsmasq >/dev/null 2>&1; then
    log_msg "WARN" "Could not install dnsmasq - skipping local DNS setup"
    return 0
  fi

  # Write dnsmasq config: listen only on 127.0.0.1 to avoid conflict with
  # systemd-resolved stub on 127.0.0.53
  mkdir -p /etc/dnsmasq.d
  cat > /etc/dnsmasq.d/appmotel-local.conf <<EOF
# Appmotel: resolve *.${BASE_DOMAIN} to private IP (AWS hairpin NAT workaround)
listen-address=127.0.0.1
bind-interfaces
no-resolv
server=${upstream_dns}
address=/.${BASE_DOMAIN}/${private_ip}
EOF

  # Tell systemd-resolved to forward only this domain to dnsmasq on 127.0.0.1
  # All other DNS queries continue through systemd-resolved as normal
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/appmotel-local.conf <<EOF
# Appmotel: forward *.${BASE_DOMAIN} queries to local dnsmasq
[Resolve]
DNS=127.0.0.1
Domains=~${BASE_DOMAIN}
EOF

  systemctl enable dnsmasq >/dev/null 2>&1 || true
  systemctl restart dnsmasq \
    && log_msg "INFO" "dnsmasq started" \
    || log_msg "WARN" "dnsmasq failed to start - check 'systemctl status dnsmasq'"
  systemctl restart systemd-resolved \
    && log_msg "INFO" "systemd-resolved reloaded" \
    || log_msg "WARN" "systemd-resolved failed to restart"

  log_msg "INFO" "Local DNS ready: *.${BASE_DOMAIN} -> ${private_ip} (via 127.0.0.1)"
}

# -----------------------------------------------------------------------------
# Function: create_traefik_service
# Description: Creates systemd service for Traefik
# -----------------------------------------------------------------------------
create_traefik_service() {
  log_msg "INFO" "Creating Traefik systemd service"

  local service_file="/etc/systemd/system/traefik-appmotel.service"

  cat > "${service_file}" <<EOF
[Unit]
Description=Traefik Proxy (AppMotel)
Documentation=https://doc.traefik.io/traefik/
After=network-online.target
Wants=network-online.target

[Service]
User=${APPMOTEL_USER}
Group=${APPMOTEL_USER}

Environment="XDG_CONFIG_HOME=${APPMOTEL_HOME}/.config"
Environment="XDG_DATA_HOME=${APPMOTEL_HOME}/.local/share"
EnvironmentFile=-${APPMOTEL_HOME}/.config/appmotel/.env

# Allow binding to privileged ports (80, 443)
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateUsers=no

ExecStart=${APPMOTEL_HOME}/.local/bin/traefik --configFile=${APPMOTEL_HOME}/.config/traefik/traefik.yaml

# Logging
StandardOutput=journal
StandardError=journal

Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log_msg "INFO" "Traefik systemd service created"
}

# -----------------------------------------------------------------------------
# Function: resolve_operator_users
# Description: Decide who may control the appmotel user (sudoers TIER 1) and
#   print it as a sudoers user list.
#   OPERATOR_USERS in .env takes comma/space separated user names, %groups,
#   or ALL (every user on the machine):
#     unset -> keep ALL if the existing sudoers file already grants it to
#              everyone (reinstalling must never silently revoke access),
#              otherwise "apps"
#   The group %appmotel-ops is always added (unless the result is ALL).
# Parameters: $1 = existing sudoers file (consulted only when unset)
# -----------------------------------------------------------------------------
resolve_operator_users() {
  local existing_file="$1"
  local raw="${OPERATOR_USERS:-}"

  if [[ -z "${raw}" ]]; then
    if [[ -f "${existing_file}" ]] && \
       grep -qE '^ALL(,[[:space:]]*!%appmotel-apps)?[[:space:]]+ALL=\(appmotel\)' "${existing_file}" 2>/dev/null; then
      echo "ALL"
    else
      echo "apps,%appmotel-ops"
    fi
    return 0
  fi

  # Entries end up verbatim in a sudoers file: accept nothing but plain
  # names, %groups and ALL
  local -a users=()
  local entry
  local saved_ifs="${IFS}"
  IFS=$', \t\n'
  for entry in ${raw}; do
    if [[ ! "${entry}" =~ ^(ALL|%?[A-Za-z_][A-Za-z0-9_.-]*)$ ]]; then
      IFS="${saved_ifs}"
      die "Invalid entry in OPERATOR_USERS: '${entry}' (use user names, %groups, or ALL)"
    fi
    if [[ "${entry}" == "ALL" ]]; then
      IFS="${saved_ifs}"
      echo "ALL"
      return 0
    fi
    users+=("${entry}")
  done
  IFS="${saved_ifs}"

  if [[ ${#users[@]} -eq 0 ]]; then
    die "OPERATOR_USERS is set but contains no users"
  fi
  # The group appmotel-ops (made by configure_sudoers) is always an operator
  [[ " ${users[*]} " == *" %appmotel-ops "* ]] || users+=("%appmotel-ops")

  local joined
  joined=$(IFS=,; echo "${users[*]}")
  echo "${joined}"
}

# -----------------------------------------------------------------------------
# Function: render_sudoers
# Description: Print the appmotel sudoers file for the given operator list
# Parameters: $1 = sudoers user list from resolve_operator_users
# -----------------------------------------------------------------------------
render_sudoers() {
  local operators="$1"

  # Isolated app users (group appmotel-apps) must never reach appmotel, even
  # when OPERATOR_USERS=ALL
  sed -e "s|__OPERATOR_USERS__|${operators}, !%appmotel-apps|g" \
      -e "s|__APPMO_BIN__|${APPMOTEL_HOME}/.local/bin/appmo|g" <<'EOF'
# Appmotel Sudoers Configuration
# See DEV-SETUP.md for complete execution model documentation

# TIER 1 -> TIER 2: Allow operator user(s) to control appmotel user
# Who is set by OPERATOR_USERS in ~/.config/appmotel/.env (default: apps; ALL = every user)
# Interactive shell access
__OPERATOR_USERS__ ALL=(ALL) NOPASSWD: /bin/su - appmotel
# Non-interactive command execution (required for automation tools like Claude Code)
__OPERATOR_USERS__ ALL=(appmotel) NOPASSWD: ALL

# appmo users: members of the group appmotel-users may run the appmo command
# (and nothing else) as appmotel. appmo re-runs itself through this rule, so
# they just type `appmo ...`. sudo and appmo both log the real user to syslog.
# Note: `appmo exec` runs any command in an app, so this is still full
# control over all apps; add only people you trust with every app.
%appmotel-users, !%appmotel-apps ALL=(appmotel) NOPASSWD: __APPMO_BIN__

# TIER 2 -> TIER 3: Allow appmotel to manage ONLY the Traefik system service
# This is needed because Traefik runs as a system service to bind ports 80/443
# Both paths are listed: `sudo systemctl` resolves via secure_path to
# /usr/bin/systemctl, which sudo does not match against a /bin rule.
appmotel ALL=(ALL) NOPASSWD: /bin/systemctl restart traefik-appmotel, /bin/systemctl stop traefik-appmotel, /bin/systemctl start traefik-appmotel, /bin/systemctl status traefik-appmotel
appmotel ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart traefik-appmotel, /usr/bin/systemctl stop traefik-appmotel, /usr/bin/systemctl start traefik-appmotel, /usr/bin/systemctl status traefik-appmotel

# Allow appmotel to view ONLY traefik-appmotel logs with any journalctl options (for debugging)
appmotel ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u traefik-appmotel, /usr/bin/journalctl -u traefik-appmotel *

# Allow appmotel to fix TLS certificate permissions (needed by self-update)
appmotel ALL=(ALL) NOPASSWD: /usr/local/bin/appmotel-fix-certs

# Allow appmotel to create and delete isolated app users a-<app> (appmo add --isolated)
appmotel ALL=(ALL) NOPASSWD: /usr/local/bin/appmotel-user

# Note: App services use systemctl --user (no sudo needed)
# Traefik config changes are auto-reloaded (no restart needed for config updates)
EOF
}

# -----------------------------------------------------------------------------
# Function: configure_sudoers
# Description: Configures sudoers for appmotel user
# See DEV-SETUP.md for complete execution model documentation
# -----------------------------------------------------------------------------
configure_sudoers() {
  log_msg "INFO" "Configuring sudoers"

  local sudoers_file="/etc/sudoers.d/appmotel"

  # Group of isolated app users; the sudoers rules below exclude it
  getent group appmotel-apps >/dev/null || groupadd --system appmotel-apps
  # Groups of people: appmotel-users may run appmo, appmotel-ops may run
  # anything as appmotel (sudoers rules in render_sudoers)
  getent group appmotel-users >/dev/null || groupadd --system appmotel-users
  getent group appmotel-ops >/dev/null || groupadd --system appmotel-ops

  local operators
  operators=$(resolve_operator_users "${sudoers_file}")
  if [[ "${operators}" == "ALL" ]]; then
    log_msg "INFO" "Sudoers: ALL users may control the ${APPMOTEL_USER} user"
  else
    log_msg "INFO" "Sudoers: operator user(s): ${operators}"
  fi

  # Render to a temp file and validate first: a syntax error in /etc/sudoers.d
  # breaks sudo for everyone, so the live file is only replaced by a good one
  local sudoers_tmp
  sudoers_tmp=$(mktemp)
  render_sudoers "${operators}" > "${sudoers_tmp}"

  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "${sudoers_tmp}" >/dev/null; then
      rm -f "${sudoers_tmp}"
      die "Generated sudoers failed validation; ${sudoers_file} left unchanged"
    fi
  else
    log_msg "WARN" "visudo not found, installing sudoers without validation"
  fi

  install -m 0440 -o root -g root "${sudoers_tmp}" "${sudoers_file}"
  rm -f "${sudoers_tmp}"
  log_msg "INFO" "Sudoers configured"

  # Install helper script for cert permission fixing (callable via sudo by appmotel)
  local fix_certs_src="${SCRIPT_DIR}/bin/appmotel-fix-certs"
  local fix_certs_dest="/usr/local/bin/appmotel-fix-certs"
  if [[ -f "${fix_certs_src}" ]]; then
    cp "${fix_certs_src}" "${fix_certs_dest}"
  else
    # Download from GitHub if not available locally
    local fix_certs_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/bin/appmotel-fix-certs?$(date +%s)"
    curl -fsSL "${fix_certs_url}" -o "${fix_certs_dest}" || log_msg "WARN" "Could not download appmotel-fix-certs"
  fi
  if [[ -f "${fix_certs_dest}" ]]; then
    chmod 755 "${fix_certs_dest}"
  fi

  # Install helper that creates/deletes isolated app users (via sudo by appmotel)
  local app_user_src="${SCRIPT_DIR}/bin/appmotel-user"
  local app_user_dest="/usr/local/bin/appmotel-user"
  if [[ -f "${app_user_src}" ]]; then
    install -m 0755 -o root -g root "${app_user_src}" "${app_user_dest}"
  else
    local app_user_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/bin/appmotel-user?$(date +%s)"
    if curl -fsSL "${app_user_url}" -o "${app_user_dest}"; then
      chmod 755 "${app_user_dest}"
    else
      log_msg "WARN" "Could not download appmotel-user (appmo add --isolated will not work)"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Function: install_app_port_firewall
# Description: Apps listen on ports 10001-59999 and often on all addresses
#   (e.g. Flask host='0.0.0.0'), so on a server with a second NIC they are
#   reachable past Traefik. This nft table drops NEW connections to those
#   ports from any interface except loopback; Traefik uses localhost, and
#   replies to outgoing connections (ephemeral ports overlap this range) are
#   not NEW, so they pass. A systemd unit loads it at boot. If an admin has
#   disabled the unit, it stays disabled.
# -----------------------------------------------------------------------------
install_app_port_firewall() {
  local nft_bin
  if ! nft_bin=$(command -v nft); then
    log_msg "WARN" "nft not found: app ports stay reachable from the network (install nftables, re-run)"
    return 0
  fi

  mkdir -p /etc/appmotel
  cat > /etc/appmotel/app-ports.nft <<'EOF'
# Installed by Appmotel install.sh - overwritten on reinstall.
# App ports (10001-59999) only from this host; Traefik on 80/443 is the way in.
table inet appmotel
delete table inet appmotel
table inet appmotel {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "lo" accept
    tcp dport 10001-59999 ct state new drop
  }
}
EOF

  local unit=/etc/systemd/system/appmotel-firewall.service
  local first_time=false
  [[ -f "${unit}" ]] || first_time=true
  cat > "${unit}" <<EOF
[Unit]
Description=Appmotel: app ports only from localhost
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nft_bin} -f /etc/appmotel/app-ports.nft
ExecStop=${nft_bin} delete table inet appmotel

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload

  if [[ "${first_time}" == "true" ]]; then
    systemctl enable appmotel-firewall.service
  fi
  if systemctl is-enabled --quiet appmotel-firewall.service; then
    systemctl restart appmotel-firewall.service
    log_msg "INFO" "App ports 10001-59999 accept new connections only from localhost (appmotel-firewall.service)"
  else
    log_msg "WARN" "appmotel-firewall.service is disabled: app ports are reachable from the network"
  fi
}

# -----------------------------------------------------------------------------
# Function: install_journal_access
# Description: Members of appmotel-ops may read the whole system journal
#   (journalctl) through a read ACL on /var/log/journal, the same way systemd
#   does it for adm and wheel. A group cannot be put inside systemd-journal,
#   so an ACL is what makes later group members work without more steps.
#   Needs a persistent journal; with a volatile one the ACL is skipped.
# -----------------------------------------------------------------------------
install_journal_access() {
  if [[ ! -d /var/log/journal ]]; then
    log_msg "WARN" "/var/log/journal missing (volatile journal): appmotel-ops cannot read the journal. Run 'mkdir /var/log/journal; systemctl restart systemd-journald', then re-run install.sh"
    return 0
  fi
  cat > /etc/tmpfiles.d/appmotel-journal.conf <<'EOF'
# Installed by Appmotel install.sh - overwritten on reinstall.
# appmotel-ops may read the system journal (journalctl).
A+ /var/log/journal - - - - d:group:appmotel-ops:r-X,group:appmotel-ops:r-X
EOF
  systemd-tmpfiles --create /etc/tmpfiles.d/appmotel-journal.conf
  log_msg "INFO" "Group appmotel-ops may read the system journal (/etc/tmpfiles.d/appmotel-journal.conf)"
}

# -----------------------------------------------------------------------------
# Function: enable_linger
# Description: Enables systemd linger for appmotel user
# -----------------------------------------------------------------------------
enable_linger() {
  log_msg "INFO" "Enabling systemd linger for ${APPMOTEL_USER}"
  loginctl enable-linger "${APPMOTEL_USER}" || log_msg "WARN" "Could not enable linger (may require manual setup)"
}

# =============================================================================
# USER-LEVEL INSTALLATION (can run as appmotel user)
# =============================================================================

# -----------------------------------------------------------------------------
# Function: secure_appmotel_files
# Description: The appmotel home is world-traversable (751) for the appmo
# symlink, and app paths are well known, so app .env files, AWS keys,
# certs and tool state must be closed by mode, not only by obscurity. Isolated app
# users depend on this. Same code in install.sh and bin/appmo.
# -----------------------------------------------------------------------------
secure_appmotel_files() {
  # Close everything in the home except ~/.local/bin (needed by the appmo
  # symlink); tools such as Claude Code (auto-debug) create 644 files in 755
  # dirs, so naming single dirs is not enough. Also run by autopull.
  find "${APPMOTEL_HOME}" -mindepth 1 -maxdepth 1 ! -name .local -exec chmod go-rwx {} + 2>/dev/null || true
  if [[ -d "${APPMOTEL_HOME}/.local" ]]; then
    chmod 755 "${APPMOTEL_HOME}/.local"
    find "${APPMOTEL_HOME}/.local" -mindepth 1 -maxdepth 1 ! -name bin -exec chmod go-rwx {} + 2>/dev/null || true
  fi
  if [[ -d "${APPMOTEL_HOME}/.config/appmotel" ]]; then
    find "${APPMOTEL_HOME}/.config/appmotel" -type f \( -name '.env' -o -name '.env.*' \) -exec chmod 600 {} +
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Function: create_directory_structure
# Description: Creates required directories for appmotel user
# -----------------------------------------------------------------------------
create_directory_structure() {
  log_msg "INFO" "Creating directory structure"

  local -a dirs=(
    "${APPMOTEL_HOME}/.local/bin"
    "${APPMOTEL_HOME}/.local/share/traefik"
    "${APPMOTEL_HOME}/.local/share/appmotel"
    "${APPMOTEL_HOME}/.config/traefik/dynamic"
    "${APPMOTEL_HOME}/.config/appmotel/apps"
    "${APPMOTEL_HOME}/.config/systemd/user"
  )

  for dir in "${dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}"
    fi
  done

  # Create and secure ACME file
  local acme_file="${APPMOTEL_HOME}/.local/share/traefik/acme.json"
  if [[ ! -f "${acme_file}" ]]; then
    touch "${acme_file}"
    chmod 600 "${acme_file}"
  fi

  secure_appmotel_files
  log_msg "INFO" "Directory structure created"
}

# -----------------------------------------------------------------------------
# Function: download_traefik
# Description: Downloads latest Traefik binary from GitHub releases
# -----------------------------------------------------------------------------
download_traefik() {
  local traefik_bin="${APPMOTEL_HOME}/.local/bin/traefik"

  log_msg "INFO" "Downloading Traefik binary"

  # Detect architecture
  local arch
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l) arch="armv7" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  # Get latest version
  local version
  version=$(curl -sL https://api.github.com/repos/traefik/traefik/releases/latest | grep '"tag_name"' | cut -d'"' -f4 || true)
  if [[ -z "${version}" ]]; then
    die "Failed to determine latest Traefik version"
  fi

  log_msg "INFO" "Latest Traefik version: ${version}"

  local os="linux"
  local tarball="traefik_${version}_${os}_${arch}.tar.gz"
  local download_url="https://github.com/traefik/traefik/releases/download/${version}/${tarball}"

  # Download to temp location
  local temp_dir
  temp_dir=$(mktemp -d)

  log_msg "INFO" "Downloading from: ${download_url}"
  if ! curl -L -o "${temp_dir}/${tarball}" "${download_url}"; then
    rm -rf "${temp_dir}"
    die "Failed to download Traefik"
  fi

  # Extract
  if ! tar -xzf "${temp_dir}/${tarball}" -C "${temp_dir}"; then
    rm -rf "${temp_dir}"
    die "Failed to extract Traefik"
  fi

  # Move to final location
  mv "${temp_dir}/traefik" "${traefik_bin}"
  chmod +x "${traefik_bin}"
  rm -rf "${temp_dir}"

  log_msg "INFO" "Traefik binary installed to ${traefik_bin}"
}

# -----------------------------------------------------------------------------
# Function: download_uv
# Description: Installs the uv binary. appmo uses it only for Python apps that
#   ask for a Python version (PYTHON_VERSION, .python-version, requires-python);
#   uv then installs that Python into the home of the user that runs the app.
#   Not fatal: without uv, such apps fail to deploy with a clear error.
# -----------------------------------------------------------------------------
download_uv() {
  local uv_bin="${APPMOTEL_HOME}/.local/bin/uv"

  local target
  case "$(uname -m)" in
    x86_64) target="x86_64-unknown-linux-gnu" ;;
    aarch64) target="aarch64-unknown-linux-gnu" ;;
    *) log_msg "WARN" "No uv build for $(uname -m), skipping uv"; return 0 ;;
  esac

  local temp_dir
  temp_dir=$(mktemp -d)
  local url="https://github.com/astral-sh/uv/releases/latest/download/uv-${target}.tar.gz"
  log_msg "INFO" "Downloading uv from: ${url}"
  if curl -fsSL -o "${temp_dir}/uv.tar.gz" "${url}" && \
     tar -xzf "${temp_dir}/uv.tar.gz" -C "${temp_dir}"; then
    install -m 0755 "${temp_dir}/uv-${target}/uv" "${uv_bin}"
    log_msg "INFO" "uv installed to ${uv_bin}"
  else
    log_msg "WARN" "Could not install uv; Python apps that need a specific Python version will not deploy"
  fi
  rm -rf "${temp_dir}"
}

# -----------------------------------------------------------------------------
# Function: find_existing_wildcard_cert
# Description: Checks for existing wildcard certificate in /etc/letsencrypt
# Returns: Domain name if found, empty string otherwise
# -----------------------------------------------------------------------------
find_existing_wildcard_cert() {
  if [[ ! -d "/etc/letsencrypt/live" ]]; then
    return
  fi

  local cert_dir="/etc/letsencrypt/live"

  # First, try to find a wildcard cert matching *.BASE_DOMAIN exactly.
  # Apps live at <app>.BASE_DOMAIN, so the SAN must be *.BASE_DOMAIN itself —
  # stripping a label here (e.g. matching *.example.edu for
  # BASE_DOMAIN=apps.example.edu) would select a cert that cannot cover the
  # apps, since wildcards only match one level.
  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    for domain_dir in "${cert_dir}"/*; do
      if [[ ! -d "${domain_dir}" ]]; then
        continue
      fi
      local domain_name=$(basename "${domain_dir}")
      if [[ -f "${domain_dir}/fullchain.pem" ]]; then
        if openssl x509 -in "${domain_dir}/fullchain.pem" -text -noout 2>/dev/null | \
           grep -qE "DNS:\*\.${BASE_DOMAIN//./\\.}(,|\$| )"; then
          echo "${domain_name}"
          return
        fi
      fi
    done
  fi

  # No fallback to other wildcard certs: a cert for *.other.example.edu does
  # not cover <app>.BASE_DOMAIN, and using it would also turn off Let's
  # Encrypt, so every app would show a certificate error.
}

# -----------------------------------------------------------------------------
# Function: ensure_cert_readable
# Description: Ensures appmotel user can read the certificate files securely
# Parameters: $1 = domain name
# Note: Must be run as root
# Uses ssl-cert group for secure access (following Debian/Ubuntu convention)
# -----------------------------------------------------------------------------
ensure_cert_readable() {
  local domain="${1}"

  if [[ ! -d "/etc/letsencrypt/live/${domain}" ]]; then
    return
  fi

  # This function needs root (groupadd/usermod/chgrp). It is also reachable
  # from the user-level path via generate_traefik_config; there, either the
  # cert is already readable (root pass set it up) or we can only warn —
  # an unguarded groupadd would abort the whole user-level install.
  if [[ ${EUID} -ne 0 ]]; then
    if [[ -x /usr/local/bin/appmotel-fix-certs ]] && sudo -n /usr/local/bin/appmotel-fix-certs 2>/dev/null; then
      log_msg "INFO" "Certificate permissions fixed via sudo helper"
    elif [[ -r "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      log_msg "INFO" "Certificate for ${domain} is readable"
    else
      log_msg "WARN" "Certificate for ${domain} is not readable by this user."
      log_msg "WARN" "Run as root to fix: sudo bash install.sh"
    fi
    return 0
  fi

  local os_type
  os_type=$(detect_os)

  # Ensure ssl-cert group exists (Debian/Ubuntu convention)
  if ! getent group ssl-cert >/dev/null 2>&1; then
    if [[ "${os_type}" == "debian" ]]; then
      # On Debian/Ubuntu, install the ssl-cert package which provides the group
      log_msg "INFO" "Installing ssl-cert package (Debian/Ubuntu convention)"
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y ssl-cert >/dev/null 2>&1 || {
          log_msg "WARN" "Failed to install ssl-cert package, creating group manually"
          groupadd ssl-cert
        }
      else
        groupadd ssl-cert
      fi
      log_msg "INFO" "ssl-cert group is now available"
    else
      # On RHEL/CentOS/Fedora, manually create the group
      log_msg "INFO" "Creating ssl-cert group manually (RHEL/CentOS convention)"
      groupadd ssl-cert
      log_msg "INFO" "Created ssl-cert group"
    fi
  fi

  # Add appmotel user to ssl-cert group
  if ! groups appmotel 2>/dev/null | grep -q ssl-cert; then
    usermod -aG ssl-cert appmotel
    log_msg "INFO" "Added appmotel user to ssl-cert group"
  fi

  # Set group ownership to ssl-cert
  chgrp -R ssl-cert /etc/letsencrypt/archive 2>/dev/null || true
  chgrp -R ssl-cert /etc/letsencrypt/live 2>/dev/null || true

  # Set secure directory permissions (750: owner full, group read/execute, world none)
  chmod 750 /etc/letsencrypt/live 2>/dev/null || true
  chmod 750 "/etc/letsencrypt/live/${domain}" 2>/dev/null || true
  chmod 750 /etc/letsencrypt/archive 2>/dev/null || true
  chmod 750 "/etc/letsencrypt/archive/${domain}" 2>/dev/null || true

  # Set secure file permissions
  # Private keys: 640 (owner read/write, group read, world none)
  # Public certs: 644 (owner read/write, group/world read - these are public anyway)
  find "/etc/letsencrypt/archive/${domain}" -name "privkey*.pem" -exec chmod 640 {} \; 2>/dev/null || true
  find "/etc/letsencrypt/archive/${domain}" -name "*.pem" ! -name "privkey*.pem" -exec chmod 644 {} \; 2>/dev/null || true

  log_msg "INFO" "Set secure certificate permissions using ssl-cert group"
}

# -----------------------------------------------------------------------------
# Function: install_cert_renewal_hook
# Description: Installs a certbot deploy hook that restarts Traefik after a
#   renewal. Traefik reads certFile/keyFile once and does not watch them, so
#   without this a renewed certificate stays on disk while Traefik keeps
#   serving the old (eventually expired) one from memory.
#   The hook runs as root, only when certbot actually renewed something, and
#   only restarts Traefik if the renewed lineage is the one tls-config.yaml
#   points at. It re-applies ssl-cert permissions first, since the renewed
#   files are new and must stay readable by the appmotel user.
# Note: Must be run as root. Idempotent (overwrites the hook each run).
# -----------------------------------------------------------------------------
install_cert_renewal_hook() {
  if [[ ! -d /etc/letsencrypt ]] && ! command -v certbot >/dev/null 2>&1; then
    log_msg "INFO" "No certbot/letsencrypt found, skipping certificate renewal hook"
    return 0
  fi

  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  local hook_file="${hook_dir}/appmotel-restart-traefik"
  local tls_config="${APPMOTEL_HOME}/.config/traefik/dynamic/tls-config.yaml"

  mkdir -p "${hook_dir}"
  cat > "${hook_file}" <<HOOKEOF
#!/bin/sh
# Installed by Appmotel install.sh - do not edit (overwritten on reinstall).
# certbot runs this as root after a successful renewal. RENEWED_LINEAGE is the
# renewed certificate's /etc/letsencrypt/live/<name> directory.
set -eu

TLS_CONFIG="${tls_config}"

lineage="\${RENEWED_LINEAGE:-}"
[ -n "\$lineage" ] || exit 0

# Only act if Traefik is configured to use this certificate
grep -qsF "\$lineage/" "\$TLS_CONFIG" || exit 0

# Renewed files are new: make sure appmotel (ssl-cert group) can read them
if [ -x /usr/local/bin/appmotel-fix-certs ]; then
  /usr/local/bin/appmotel-fix-certs
fi

# Traefik does not watch cert files; restart to load the renewed certificate
systemctl restart traefik-appmotel
HOOKEOF
  chmod 755 "${hook_file}"

  log_msg "INFO" "Certbot deploy hook installed: ${hook_file}"
}

# -----------------------------------------------------------------------------
# Function: resolve_bind_ip
# Description: Print the IP that Traefik listens on for ports 80 and 443, or
#   nothing for all addresses. APPMOTEL_BIND_IP in .env wins (an empty value
#   means all addresses). If .env has no such line, an IP that traefik.yaml
#   already binds to (for example a hand edit on a server with a second NIC)
#   is kept, so a reinstall never widens it. On a first install the IP can
#   come from the environment: APPMOTEL_BIND_IP=192.0.2.5 bash install.sh
#   Not named TRAEFIK_*: Traefik reads such env vars as its own config.
# Parameters: $1 = existing traefik.yaml, $2 = appmotel .env
# -----------------------------------------------------------------------------
resolve_bind_ip() {
  local yaml="$1" env_file="$2" ip=""
  if grep -q '^APPMOTEL_BIND_IP=' "${env_file}" 2>/dev/null; then
    ip="${APPMOTEL_BIND_IP:-}"          # set in .env (empty = all addresses)
  elif [[ -n "${APPMOTEL_BIND_IP:-}" ]]; then
    ip="${APPMOTEL_BIND_IP}"            # first install: APPMOTEL_BIND_IP=... bash install.sh
  elif [[ -f "${yaml}" ]]; then
    ip=$(grep -oE '^[[:space:]]*address:[[:space:]]*"?(\[[0-9A-Fa-f:.]+\]|[0-9.]+):80"?' "${yaml}" | head -1 \
      | sed -E 's/^[[:space:]]*address:[[:space:]]*"?//; s/:80"?$//')
  fi
  [[ -z "${ip}" ]] && return 0
  # The value goes into traefik.yaml: accept only an IPv4 or [IPv6] address
  if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local octet
    for octet in "${BASH_REMATCH[@]:1}"; do
      [[ ${octet} -le 255 ]] || die "Invalid APPMOTEL_BIND_IP: ${ip}"
    done
  elif [[ ! "${ip}" =~ ^\[[0-9A-Fa-f:.]+\]$ ]]; then
    die "Invalid APPMOTEL_BIND_IP: '${ip}' (use an IPv4 address, or an IPv6 address in [ ])"
  fi
  echo "${ip}"
}

# -----------------------------------------------------------------------------
# Function: generate_traefik_config
# Description: Generates Traefik static and dynamic configuration
# Note: In Traefik v3, TLS stores MUST be in dynamic configuration, not static
# -----------------------------------------------------------------------------
generate_traefik_config() {
  log_msg "INFO" "Generating Traefik configuration"

  local static_config_file="${APPMOTEL_HOME}/.config/traefik/traefik.yaml"
  local dynamic_config_dir="${APPMOTEL_HOME}/.config/traefik/dynamic"
  local tls_config_file="${dynamic_config_dir}/tls-config.yaml"

  # Listen address for ports 80/443 (one NIC only, if set or already bound)
  local bind_ip env_file="${APPMOTEL_HOME}/.config/appmotel/.env"
  bind_ip=$(resolve_bind_ip "${static_config_file}" "${env_file}") || exit 1
  if [[ -n "${bind_ip}" ]]; then
    if ! grep -q "^APPMOTEL_BIND_IP=" "${env_file}" 2>/dev/null; then
      printf '# Set by install.sh: Traefik listens only on this IP (ports 80, 443)\nAPPMOTEL_BIND_IP="%s"\n' "${bind_ip}" >> "${env_file}"
      log_msg "INFO" "Saved Traefik bind address ${bind_ip} as APPMOTEL_BIND_IP in ${env_file}"
    fi
    log_msg "INFO" "Traefik listens on ${bind_ip}:80 and ${bind_ip}:443"
  else
    # No guess: the "right" NIC is a site decision. Warn if there is a choice.
    local addrs
    addrs=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ' || true)
    if [[ $(wc -w <<< "${addrs}") -gt 1 ]]; then
      log_msg "WARN" "Traefik listens on ALL addresses (${addrs% }) for ports 80 and 443"
      log_msg "WARN" "To use one NIC only: set APPMOTEL_BIND_IP=\"<ip>\" in ${env_file}, then run: appmo self-update"
    fi
  fi

  # Build certificate configuration for ACME (goes in static config)
  local acme_config=""

  # First, check for existing wildcard certificate
  local existing_cert
  existing_cert=$(find_existing_wildcard_cert)

  if [[ -n "${existing_cert}" ]]; then
    log_msg "INFO" "Found existing wildcard certificate for: ${existing_cert}"
    ensure_cert_readable "${existing_cert}"
    # CRITICAL: TLS stores must be in DYNAMIC config for Traefik v3
    cat > "${tls_config_file}" <<EOF
# TLS Configuration (MUST be in dynamic config for Traefik v3)
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/letsencrypt/live/${existing_cert}/fullchain.pem
        keyFile: /etc/letsencrypt/live/${existing_cert}/privkey.pem
EOF
    log_msg "INFO" "TLS configuration written to ${tls_config_file}"
  elif [[ -f "${tls_config_file}" ]]; then
    # An older install.sh also picked wildcard certs for other domains. Drop
    # such a config, but only when its cert is readable and provably wrong
    # (an unreadable cert says nothing about the domain).
    local old_cert
    old_cert=$(awk '/certFile:/ {print $2; exit}' "${tls_config_file}")
    if [[ -n "${old_cert}" ]] && [[ -r "${old_cert}" ]] && [[ -n "${BASE_DOMAIN:-}" ]] && \
       ! openssl x509 -in "${old_cert}" -text -noout 2>/dev/null | grep -qE "DNS:\*\.${BASE_DOMAIN//./\\.}(,|\$| )"; then
      rm -f "${tls_config_file}"
      log_msg "WARN" "Removed ${tls_config_file}: ${old_cert} does not cover *.${BASE_DOMAIN}"
    fi
  fi

  # Let's Encrypt rejects example.com addresses; no email is allowed
  if [[ "${LETSENCRYPT_EMAIL:-}" == *@example.com ]]; then
    LETSENCRYPT_EMAIL=""
  fi

  if [[ -z "${existing_cert}" ]] && [[ "${USE_LETSENCRYPT:-no}" == "yes" ]]; then
    # Use ACME for new certificates (ACME config stays in static config)
    if [[ "${LETSENCRYPT_MODE:-http}" == "dns" ]]; then
      # DNS-01 challenge with Route53
      # Route53 is global, but the AWS SDK in Traefik refuses to work without
      # a region ("Missing Region"); Traefik reads it from this .env
      if [[ -z "${AWS_REGION:-}" ]]; then
        sed -i '/^AWS_REGION=/d' "${env_file}"
        # No comment after the value: systemd's EnvironmentFile keeps it
        printf '# Set by install.sh for Route53 (any region works)\nAWS_REGION="us-east-1"\n' >> "${env_file}"
        AWS_REGION="us-east-1"
        log_msg "INFO" "Set AWS_REGION=us-east-1 in ${env_file} for Route53"
      fi
      acme_config="certificatesResolvers:
  myresolver:
    acme:
      email: \"${LETSENCRYPT_EMAIL}\"
      storage: \"${APPMOTEL_HOME}/.local/share/traefik/acme.json\"
      dnsChallenge:
        provider: route53
        delayBeforeCheck: 0"
    else
      # HTTP-01 challenge
      acme_config="certificatesResolvers:
  myresolver:
    acme:
      email: \"${LETSENCRYPT_EMAIL}\"
      storage: \"${APPMOTEL_HOME}/.local/share/traefik/acme.json\"
      httpChallenge:
        entryPoint: web"
    fi
  fi

  # Backend transport timeouts (dynamic config). Complements the entrypoint
  # respondingTimeouts below: these govern the Traefik->app connection, while
  # respondingTimeouts govern the client->Traefik side. Named "default" so it
  # applies to all services without per-app configuration.
  cat > "${dynamic_config_dir}/default-transport.yaml" <<EOF
# Default transport configuration for long-running requests
# Managed by: install.sh (generate_traefik_config), rewritten on self-update
http:
  serversTransports:
    default:
      forwardingTimeouts:
        dialTimeout: 30s
        responseHeaderTimeout: 600s
        idleConnTimeout: 600s
EOF
  log_msg "INFO" "Default transport configuration written to ${dynamic_config_dir}/default-transport.yaml"

  # Write static configuration
  cat > "${static_config_file}" <<EOF
# STATIC CONFIGURATION

entryPoints:
  web:
    address: "${bind_ip}:80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: "${bind_ip}:443"
    transport:
      respondingTimeouts:
        # Long timeouts for streaming/SSE apps (e.g. codecheck runs multi-minute
        # LLM analyses). writeTimeout caps total response duration, so it must
        # exceed the slowest stream; idleTimeout caps silence between writes.
        writeTimeout: 1800s
        idleTimeout: 1800s

providers:
  file:
    directory: "${APPMOTEL_HOME}/.config/traefik/dynamic"
    watch: true

${acme_config}

api:
  dashboard: true
EOF

  log_msg "INFO" "Traefik static configuration written to ${static_config_file}"
}

# -----------------------------------------------------------------------------
# Function: install_appmo_cli
# Description: Installs appmo CLI tool
# Downloads from GitHub if not found locally
# -----------------------------------------------------------------------------
install_appmo_cli() {
  log_msg "INFO" "Installing appmo CLI tool"

  local appmo_source_local="${SCRIPT_DIR}/bin/appmo"
  local appmo_dest="${APPMOTEL_HOME}/.local/bin/appmo"
  local github_appmo_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/bin/appmo?$(date +%s)"

  # Use atomic replacement (mv) to avoid corrupting a running appmo process.
  # cp overwrites in-place which shifts bytes under bash's open file descriptor;
  # mv creates a new inode so the old process keeps reading the old file.
  local appmo_tmp="${appmo_dest}.tmp.$$"

  # Try local file first, download if not found
  if [[ -f "${appmo_source_local}" ]]; then
    log_msg "INFO" "Using local appmo CLI from repository"
    cp "${appmo_source_local}" "${appmo_tmp}"
  else
    log_msg "INFO" "Downloading appmo CLI from GitHub"
    if curl -fsSL "${github_appmo_url}" -o "${appmo_tmp}"; then
      log_msg "INFO" "Downloaded appmo CLI successfully"
    else
      rm -f "${appmo_tmp}"
      die "Failed to download appmo CLI from GitHub"
    fi
  fi

  chmod +x "${appmo_tmp}"
  mv -f "${appmo_tmp}" "${appmo_dest}"
  log_msg "INFO" "appmo CLI installed to ${appmo_dest}"

  # Install shell completion
  local completion_source_local="${SCRIPT_DIR}/bin/appmo-completion.bash"
  local completion_dest="${APPMOTEL_HOME}/.local/share/bash-completion/completions"
  local github_completion_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/bin/appmo-completion.bash?$(date +%s)"

  mkdir -p "${completion_dest}"

  # Try local file first, download if not found
  if [[ -f "${completion_source_local}" ]]; then
    cp "${completion_source_local}" "${completion_dest}/appmo"
    log_msg "INFO" "Shell completion installed"
  else
    log_msg "INFO" "Downloading shell completion from GitHub"
    if curl -fsSL "${github_completion_url}" -o "${completion_dest}/appmo"; then
      log_msg "INFO" "Shell completion installed"
    fi
  fi

  # bash-completion lazy-loads by command name, so the appmotel alias needs
  # the same file under its own name to get completion on first <Tab>
  if [[ -f "${completion_dest}/appmo" ]]; then
    ln -sf appmo "${completion_dest}/appmotel"
  fi
}

# -----------------------------------------------------------------------------
# Function: setup_path
# Description: Ensures ~/.local/bin is in PATH
# -----------------------------------------------------------------------------
setup_path() {
  log_msg "INFO" "Setting up PATH"

  local bashrc="${APPMOTEL_HOME}/.bashrc"

  # Check if PATH setup already exists
  if grep -q '.local/bin' "${bashrc}" 2>/dev/null; then
    log_msg "INFO" "PATH already configured"
  else
    # Add to .bashrc
    cat >> "${bashrc}" <<'EOF'

# Add ~/.local/bin to PATH
if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
EOF
    log_msg "INFO" "PATH configured in .bashrc"
  fi

  # Convenience alias; completion for it is registered in appmo-completion.bash
  if ! grep -q "alias appmotel=" "${bashrc}" 2>/dev/null; then
    cat >> "${bashrc}" <<'EOF'

# appmotel is an alias for the appmo CLI
alias appmotel='appmo'
EOF
    log_msg "INFO" "appmotel alias added to .bashrc"
  fi
}

# -----------------------------------------------------------------------------
# Function: install_autopull
# Description: Installs autopull systemd timer (calls 'appmo autopull')
# Note: appmo-autopull is now integrated as 'appmo autopull' subcommand
# -----------------------------------------------------------------------------
install_autopull() {
  log_msg "INFO" "Installing autopull service"

  # Install systemd service and timer
  local systemd_user_dir="${APPMOTEL_HOME}/.config/systemd/user"
  mkdir -p "${systemd_user_dir}"

  local service_template_local="${SCRIPT_DIR}/templates/appmotel-autopull.service"
  local timer_template_local="${SCRIPT_DIR}/templates/appmotel-autopull.timer"
  local github_service_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/templates/appmotel-autopull.service?$(date +%s)"
  local github_timer_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/templates/appmotel-autopull.timer?$(date +%s)"

  # Install service unit
  if [[ -f "${service_template_local}" ]]; then
    cp "${service_template_local}" "${systemd_user_dir}/appmotel-autopull.service"
    log_msg "INFO" "autopull service unit installed"
  else
    log_msg "INFO" "Downloading autopull service template from GitHub"
    if curl -fsSL "${github_service_url}" -o "${systemd_user_dir}/appmotel-autopull.service"; then
      log_msg "INFO" "autopull service unit installed"
    else
      log_msg "WARN" "Failed to download autopull service template"
      return
    fi
  fi

  # Install timer unit
  if [[ -f "${timer_template_local}" ]]; then
    cp "${timer_template_local}" "${systemd_user_dir}/appmotel-autopull.timer"
    log_msg "INFO" "autopull timer unit installed"
  else
    log_msg "INFO" "Downloading autopull timer template from GitHub"
    if curl -fsSL "${github_timer_url}" -o "${systemd_user_dir}/appmotel-autopull.timer"; then
      log_msg "INFO" "autopull timer unit installed"
    else
      log_msg "WARN" "Failed to download autopull timer template"
      return
    fi
  fi

  # Set up environment for systemd user services
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

  # Reload systemd and enable timer
  systemctl --user daemon-reload

  if systemctl --user enable appmotel-autopull.timer; then
    log_msg "INFO" "autopull timer enabled"
  else
    log_msg "WARN" "Failed to enable autopull timer"
    return
  fi

  if systemctl --user start appmotel-autopull.timer; then
    log_msg "INFO" "autopull timer started"
  else
    log_msg "WARN" "Failed to start autopull timer"
    return
  fi

  log_msg "INFO" "Autopull service configured to check for updates every 2 minutes"
}

# -----------------------------------------------------------------------------
# Function: start_traefik_service
# Description: Start Traefik if it is not running. Runs at the end of the
#   user-level install, because only that part installs the Traefik binary
#   and config; the root part only enables the service. A running Traefik is
#   left alone (self-update restarts it itself).
# -----------------------------------------------------------------------------
start_traefik_service() {
  if systemctl is-active --quiet traefik-appmotel; then
    return 0
  fi

  log_msg "INFO" "Starting Traefik service"
  if ! sudo -n systemctl start traefik-appmotel; then
    log_msg "ERROR" "Could not start Traefik; run: sudo systemctl start traefik-appmotel"
    return 1
  fi

  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet traefik-appmotel; then
      log_msg "INFO" "Traefik service is running"
      return 0
    fi
    sleep 1
  done

  log_msg "ERROR" "Traefik service failed to start within 10 seconds"
  systemctl status traefik-appmotel --no-pager || true
  return 1
}

# =============================================================================
# MAIN INSTALLATION FLOW
# =============================================================================

# -----------------------------------------------------------------------------
# Function: install_as_root
# Description: System-level installation only (requires root)
# -----------------------------------------------------------------------------
install_as_root() {
  log_msg "INFO" "Starting system-level installation (root privileges)"

  # Install required packages (git, curl, etc.)
  log_msg "INFO" "Checking and installing required packages..."
  install_required_packages

  # Create user FIRST before creating any directories
  create_appmotel_user

  # Load env (may create directories as root)
  load_env

  # Fix ownership of home directory and all contents
  chown -R "${APPMOTEL_USER}:${APPMOTEL_USER}" "${APPMOTEL_HOME}"
  log_msg "INFO" "Fixed ownership of ${APPMOTEL_HOME}"

  # Allow all users to traverse into the appmotel home so the system-wide
  # /usr/local/bin/appmo symlink is usable by everyone (751 = owner:rwx,
  # group:r-x, others:--x — traverse only, no directory listing).
  chmod 751 "${APPMOTEL_HOME}"
  log_msg "INFO" "Set ${APPMOTEL_HOME} permissions to 751 (world-traversable)"

  # Create system-wide symlink so any user can run 'appmo' or 'appmo skill'
  # directly without needing sudo -u appmotel.
  # 'appmotel' is the same command under a longer name
  ln -sf "${APPMOTEL_HOME}/.local/bin/appmo" "/usr/local/bin/appmo"
  ln -sf "${APPMOTEL_HOME}/.local/bin/appmo" "/usr/local/bin/appmotel"
  log_msg "INFO" "System-wide symlinks created: /usr/local/bin/appmo, /usr/local/bin/appmotel"

  # AWS hairpin NAT workaround: resolve *.BASE_DOMAIN locally via dnsmasq
  setup_local_dns

  # System-level operations
  configure_sudoers
  enable_linger
  install_app_port_firewall
  install_journal_access

  # Create systemd service (requires root, but Traefik binary doesn't exist yet)
  create_traefik_service

  # Enable boot-start now: enabling works without the binary, and the
  # user-level sudoers grant only covers start/stop/restart/status, so this
  # is the only phase that can do it. Without this the service stays
  # disabled and Traefik is down after the first reboot.
  systemctl enable traefik-appmotel
  log_msg "INFO" "Traefik service enabled for boot"

  # Check for and prepare existing certificates
  local existing_cert
  existing_cert=$(find_existing_wildcard_cert)
  if [[ -n "${existing_cert}" ]]; then
    log_msg "INFO" "Found existing wildcard certificate: ${existing_cert}"
    ensure_cert_readable "${existing_cert}"
  fi

  # Restart Traefik automatically when certbot renews (it never reloads certs itself)
  install_cert_renewal_hook

  log_msg "INFO" "System-level installation complete!"
  log_msg "INFO" "======================================"
  log_msg "INFO" ""
  log_msg "INFO" "Next step: Switch to appmotel user and run installation"
  log_msg "INFO" ""
  log_msg "INFO" "  sudo su - appmotel"
  log_msg "INFO" "  curl -fsSL \"https://raw.githubusercontent.com/dirkpetersen/appmotel/main/install.sh?\$(date +%s)\" | bash"
  log_msg "INFO" ""
  log_msg "INFO" "Or if you have the repository locally:"
  log_msg "INFO" ""
  log_msg "INFO" "  sudo su - appmotel"
  log_msg "INFO" "  cd /path/to/appmotel"
  log_msg "INFO" "  bash install.sh"
}

# -----------------------------------------------------------------------------
# Function: run_as_appmotel_user
# Description: Runs user-level installation as appmotel user
# -----------------------------------------------------------------------------
run_as_appmotel_user() {
  log_msg "INFO" "Starting user-level installation as ${APPMOTEL_USER}"

  load_env
  create_directory_structure
  download_traefik
  download_uv
  generate_traefik_config
  install_appmo_cli
  install_autopull
  setup_path
  start_traefik_service

  log_msg "INFO" "User-level installation complete"
}

# -----------------------------------------------------------------------------
# Function: install_as_user
# Description: User-level installation (switches to appmotel user)
# -----------------------------------------------------------------------------
install_as_user() {
  local current_user
  current_user="$(whoami)"

  log_msg "INFO" "Running as user: ${current_user}"

  # Check if already running as appmotel user
  if [[ "${current_user}" == "${APPMOTEL_USER}" ]]; then
    # Already appmotel user, run installation directly
    run_as_appmotel_user

    log_msg "INFO" "Note: Traefik service can be managed with:"
    log_msg "INFO" "  sudo systemctl start traefik-appmotel"
    log_msg "INFO" "  sudo systemctl restart traefik-appmotel"
    log_msg "INFO" "  sudo systemctl status traefik-appmotel"
    log_msg "INFO" ""
    log_msg "INFO" "Traefik automatically reloads configuration from ~/.config/traefik/dynamic/"

    log_msg "INFO" "======================================"
    log_msg "INFO" "Installation complete!"
    log_msg "INFO" "======================================"
    log_msg "INFO" "Traefik: https://localhost (dashboard may be available)"
    log_msg "INFO" "CLI tool: ~/.local/bin/appmo"
    log_msg "INFO" ""

    # Only show domain configuration warning if BASE_DOMAIN is still set to default
    if [[ "${BASE_DOMAIN:-}" == "apps.example.edu" ]] || \
       [[ "${BASE_DOMAIN:-}" == "apps.yourdomain.edu" ]] || \
       [[ -z "${BASE_DOMAIN:-}" ]]; then
      log_msg "WARN" "⚠️  IMPORTANT: Configure your domain before adding apps"
      log_msg "INFO" ""
      log_msg "INFO" "1. Edit the configuration file:"
      log_msg "INFO" "   nano ~/.config/appmotel/.env"
      log_msg "INFO" ""
      log_msg "INFO" "2. Update BASE_DOMAIN to your actual domain:"
      log_msg "INFO" "   BASE_DOMAIN=\"apps.yourdomain.edu\""
      log_msg "INFO" ""
      log_msg "INFO" "3. Restart Traefik to apply changes:"
      log_msg "INFO" "   sudo systemctl restart traefik-appmotel"
      log_msg "INFO" ""
    else
      log_msg "INFO" "Domain configured: ${BASE_DOMAIN}"
      log_msg "INFO" ""
    fi

    log_msg "INFO" "Add your first app:"
    log_msg "INFO" "  appmo add <app-name> <github-url> [branch]"
    log_msg "INFO" ""
    log_msg "INFO" "Example:"
    log_msg "INFO" "  appmo add myapp https://github.com/username/myrepo main"
    return 0
  fi

  # Not appmotel user, need to switch
  log_msg "INFO" "Switching to ${APPMOTEL_USER} user for installation"

  # Check if we can switch to appmotel user. Probe with the same command
  # form used below: the sudoers rule this installer writes only covers
  # `(appmotel) NOPASSWD: ALL`, and an exact-match rule like
  # `/bin/su - appmotel` would not authorize `su ... -c "echo test"`, so a
  # su-based probe can falsely abort. -n avoids hanging on a password prompt.
  if ! sudo -n -u appmotel true 2>/dev/null; then
    log_msg "ERROR" "Cannot switch to ${APPMOTEL_USER} user"
    log_msg "ERROR" "Make sure you have permission: sudo -u appmotel true"
    log_msg "ERROR" ""
    log_msg "ERROR" "If system-level setup is not done, run as root first:"
    log_msg "ERROR" "  sudo bash install.sh"
    exit 1
  fi

  # Switch to appmotel user and run installation. The if-guard keeps errexit
  # from exiting before we can report the failure (a bare $? capture after
  # the command is dead code under errexit).
  local exit_code=0
  if ! sudo -u appmotel bash -c "cd '${SCRIPT_DIR}' && bash install.sh"; then
    exit_code=$?
  fi

  if [[ ${exit_code} -eq 0 ]]; then
    log_msg "INFO" "======================================"
    log_msg "INFO" "Installation completed successfully!"
    log_msg "INFO" "======================================"
    log_msg "INFO" ""
    log_msg "INFO" "To use appmo CLI:"
    log_msg "INFO" "  sudo su - appmotel"
    log_msg "INFO" "  appmo add <app-name> <github-url> <branch>"
  else
    log_msg "ERROR" "Installation failed with exit code ${exit_code}"
    exit ${exit_code}
  fi
}

# -----------------------------------------------------------------------------
# Function: main
# Description: Main installation flow
# -----------------------------------------------------------------------------
main() {
  log_msg "INFO" "Appmotel Installation Script"
  log_msg "INFO" "=============================="

  if [[ "${EUID}" -eq 0 ]]; then
    install_as_root
  else
    install_as_user
  fi
}

main "$@"
