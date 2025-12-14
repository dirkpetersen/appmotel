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
# Function: load_env
# Description: Loads configuration from .env file
# Location: Uses fixed path /home/appmotel/.config/appmotel/.env
#           This allows both root and user installations to access the same config
# -----------------------------------------------------------------------------
load_env() {
  local config_dir="${APPMOTEL_HOME}/.config/appmotel"
  local env_file="${config_dir}/.env"
  local env_default_local="${SCRIPT_DIR}/.env.default"
  local github_env_url="https://raw.githubusercontent.com/dirkpetersen/appmotel/main/.env.default"

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
# Function: create_traefik_service
# Description: Creates systemd service for Traefik
# -----------------------------------------------------------------------------
create_traefik_service() {
  log_msg "INFO" "Creating Traefik systemd service"

  local service_file="/etc/systemd/system/traefik-appmotel.service"

  # Build environment variables for DNS challenge
  local env_vars=""
  if [[ "${USE_LETSENCRYPT:-no}" == "yes" ]] && [[ "${LETSENCRYPT_MODE:-http}" == "dns" ]]; then
    env_vars="Environment=\"AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}\"
Environment=\"AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}\"
Environment=\"AWS_HOSTED_ZONE_ID=${AWS_HOSTED_ZONE_ID:-}\""
  fi

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
${env_vars}

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
# Function: configure_sudoers
# Description: Configures sudoers for appmotel user
# See DEV-SETUP.md for complete execution model documentation
# -----------------------------------------------------------------------------
configure_sudoers() {
  log_msg "INFO" "Configuring sudoers"

  local sudoers_file="/etc/sudoers.d/appmotel"

  cat > "${sudoers_file}" <<'EOF'
# Appmotel Sudoers Configuration
# See DEV-SETUP.md for complete execution model documentation

# TIER 1 -> TIER 2: Allow operator user to control appmotel user
# Interactive shell access
apps ALL=(ALL) NOPASSWD: /bin/su - appmotel
# Non-interactive command execution (required for automation tools like Claude Code)
apps ALL=(appmotel) NOPASSWD: ALL

# TIER 2 -> TIER 3: Allow appmotel to manage ONLY the Traefik system service
# This is needed because Traefik runs as a system service to bind ports 80/443
appmotel ALL=(ALL) NOPASSWD: /bin/systemctl restart traefik-appmotel, /bin/systemctl stop traefik-appmotel, /bin/systemctl start traefik-appmotel, /bin/systemctl status traefik-appmotel

# Allow appmotel to view ONLY traefik-appmotel logs with any journalctl options (for debugging)
appmotel ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u traefik-appmotel, /usr/bin/journalctl -u traefik-appmotel *

# Note: App services use systemctl --user (no sudo needed)
# Traefik config changes are auto-reloaded (no restart needed for config updates)
EOF

  chmod 0440 "${sudoers_file}"
  log_msg "INFO" "Sudoers configured"
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
  version=$(curl -sL https://api.github.com/repos/traefik/traefik/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
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
# Function: find_existing_wildcard_cert
# Description: Checks for existing wildcard certificate in /etc/letsencrypt
# Returns: Domain name if found, empty string otherwise
# -----------------------------------------------------------------------------
find_existing_wildcard_cert() {
  if [[ ! -d "/etc/letsencrypt/live" ]]; then
    return
  fi

  local cert_dir="/etc/letsencrypt/live"

  # First, try to find a wildcard cert matching *.BASE_DOMAIN
  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    local base_domain="${BASE_DOMAIN#*.}"  # Remove any leading subdomain
    for domain_dir in "${cert_dir}"/*; do
      if [[ ! -d "${domain_dir}" ]]; then
        continue
      fi
      local domain_name=$(basename "${domain_dir}")
      if [[ -f "${domain_dir}/fullchain.pem" ]]; then
        if openssl x509 -in "${domain_dir}/fullchain.pem" -text -noout 2>/dev/null | \
           grep -q "DNS:\*\.${base_domain}"; then
          echo "${domain_name}"
          return
        fi
      fi
    done
  fi

  # If no match with BASE_DOMAIN, find any wildcard certificate
  for domain_dir in "${cert_dir}"/*; do
    if [[ ! -d "${domain_dir}" ]]; then
      continue
    fi
    local domain_name=$(basename "${domain_dir}")
    if [[ -f "${domain_dir}/fullchain.pem" ]]; then
      # Look for any wildcard certificate
      if openssl x509 -in "${domain_dir}/fullchain.pem" -text -noout 2>/dev/null | \
         grep -q "DNS:\*\."; then
        echo "${domain_name}"
        return
      fi
    fi
  done
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
# Function: generate_traefik_config
# Description: Generates Traefik static configuration
# -----------------------------------------------------------------------------
generate_traefik_config() {
  log_msg "INFO" "Generating Traefik configuration"

  local config_file="${APPMOTEL_HOME}/.config/traefik/traefik.yaml"

  # Build certificate configuration
  local cert_config=""

  # First, check for existing wildcard certificate
  local existing_cert
  existing_cert=$(find_existing_wildcard_cert)

  if [[ -n "${existing_cert}" ]]; then
    log_msg "INFO" "Found existing wildcard certificate for: ${existing_cert}"
    ensure_cert_readable "${existing_cert}"
    cert_config="tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/letsencrypt/live/${existing_cert}/fullchain.pem
        keyFile: /etc/letsencrypt/live/${existing_cert}/privkey.pem"
  elif [[ "${USE_LETSENCRYPT:-no}" == "yes" ]]; then
    # Use ACME for new certificates
    if [[ "${LETSENCRYPT_MODE:-http}" == "dns" ]]; then
      # DNS-01 challenge with Route53
      cert_config="certificatesResolvers:
  myresolver:
    acme:
      email: \"${LETSENCRYPT_EMAIL}\"
      storage: \"${APPMOTEL_HOME}/.local/share/traefik/acme.json\"
      dnsChallenge:
        provider: route53
        delayBeforeCheck: 0"
    else
      # HTTP-01 challenge
      cert_config="certificatesResolvers:
  myresolver:
    acme:
      email: \"${LETSENCRYPT_EMAIL}\"
      storage: \"${APPMOTEL_HOME}/.local/share/traefik/acme.json\"
      httpChallenge:
        entryPoint: web"
    fi
  fi

  # Write configuration
  cat > "${config_file}" <<EOF
# STATIC CONFIGURATION

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  file:
    directory: "${APPMOTEL_HOME}/.config/traefik/dynamic"
    watch: true

${cert_config}

api:
  dashboard: true
EOF

  log_msg "INFO" "Traefik configuration written to ${config_file}"
}

# -----------------------------------------------------------------------------
# Function: install_appmo_cli
# Description: Installs appmo CLI tool
# -----------------------------------------------------------------------------
install_appmo_cli() {
  log_msg "INFO" "Installing appmo CLI tool"

  local appmo_source="${SCRIPT_DIR}/bin/appmo"
  local appmo_dest="${APPMOTEL_HOME}/.local/bin/appmo"

  if [[ ! -f "${appmo_source}" ]]; then
    log_msg "WARN" "appmo CLI not found at ${appmo_source}"
    return
  fi

  cp "${appmo_source}" "${appmo_dest}"
  chmod +x "${appmo_dest}"
  log_msg "INFO" "appmo CLI installed to ${appmo_dest}"

  # Install shell completion
  local completion_source="${SCRIPT_DIR}/bin/appmo-completion.bash"
  local completion_dest="${APPMOTEL_HOME}/.local/share/bash-completion/completions"

  if [[ -f "${completion_source}" ]]; then
    mkdir -p "${completion_dest}"
    cp "${completion_source}" "${completion_dest}/appmo"
    log_msg "INFO" "Shell completion installed"
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
    return
  fi

  # Add to .bashrc
  cat >> "${bashrc}" <<'EOF'

# Add ~/.local/bin to PATH
if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
EOF

  log_msg "INFO" "PATH configured in .bashrc"
}

# -----------------------------------------------------------------------------
# Function: install_autopull
# Description: Installs autopull script and systemd timer
# -----------------------------------------------------------------------------
install_autopull() {
  log_msg "INFO" "Installing autopull service"

  # Install autopull script
  local autopull_source="${SCRIPT_DIR}/bin/appmo-autopull"
  local autopull_dest="${APPMOTEL_HOME}/.local/bin/appmo-autopull"

  if [[ ! -f "${autopull_source}" ]]; then
    log_msg "WARN" "appmo-autopull script not found at ${autopull_source}"
    return
  fi

  cp "${autopull_source}" "${autopull_dest}"
  chmod +x "${autopull_dest}"
  log_msg "INFO" "autopull script installed to ${autopull_dest}"

  # Install systemd service and timer
  local systemd_user_dir="${APPMOTEL_HOME}/.config/systemd/user"
  mkdir -p "${systemd_user_dir}"

  local service_template="${SCRIPT_DIR}/templates/appmotel-autopull.service"
  local timer_template="${SCRIPT_DIR}/templates/appmotel-autopull.timer"

  if [[ -f "${service_template}" ]]; then
    cp "${service_template}" "${systemd_user_dir}/appmotel-autopull.service"
    log_msg "INFO" "autopull service unit installed"
  else
    log_msg "WARN" "autopull service template not found"
    return
  fi

  if [[ -f "${timer_template}" ]]; then
    cp "${timer_template}" "${systemd_user_dir}/appmotel-autopull.timer"
    log_msg "INFO" "autopull timer unit installed"
  else
    log_msg "WARN" "autopull timer template not found"
    return
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
# Function: enable_traefik_service
# Description: Enables and starts Traefik service (requires root)
# -----------------------------------------------------------------------------
enable_traefik_service() {
  log_msg "INFO" "Enabling Traefik service"

  systemctl enable traefik-appmotel
  systemctl restart traefik-appmotel

  sleep 2

  if systemctl is-active --quiet traefik-appmotel; then
    log_msg "INFO" "Traefik service is running"
  else
    log_msg "ERROR" "Traefik service failed to start"
    systemctl status traefik-appmotel --no-pager || true
    return 1
  fi
}

# =============================================================================
# MAIN INSTALLATION FLOW
# =============================================================================

# -----------------------------------------------------------------------------
# Function: verify_system_setup
# Description: Verifies system-level setup is complete
# -----------------------------------------------------------------------------
verify_system_setup() {
  log_msg "INFO" "Verifying system-level setup"

  local all_good=true

  # Check if traefik-appmotel service exists
  if ! systemctl list-unit-files | grep -q "traefik-appmotel.service"; then
    log_msg "ERROR" "Traefik systemd service not found"
    all_good=false
  else
    log_msg "INFO" "Traefik service exists"
  fi

  # Check if we can restart traefik service
  if ! sudo systemctl restart traefik-appmotel 2>/dev/null; then
    log_msg "ERROR" "Cannot restart Traefik service (check sudoers configuration)"
    all_good=false
  else
    log_msg "INFO" "Can manage Traefik service"
  fi

  # Check if service is running
  if ! systemctl is-active --quiet traefik-appmotel; then
    log_msg "WARN" "Traefik service is not running"
    all_good=false
  else
    log_msg "INFO" "Traefik service is running"
  fi

  if [[ "${all_good}" == "false" ]]; then
    log_msg "ERROR" "System-level setup is incomplete"
    log_msg "ERROR" "Please run this script as root: sudo bash install.sh"
    exit 1
  fi

  log_msg "INFO" "System-level setup verified successfully"
}

# -----------------------------------------------------------------------------
# Function: install_as_root
# Description: System-level installation only (requires root)
# -----------------------------------------------------------------------------
install_as_root() {
  log_msg "INFO" "Starting system-level installation (root privileges)"

  load_env

  # System-level operations only
  create_appmotel_user
  configure_sudoers
  enable_linger

  # Create systemd service (requires root, but Traefik binary doesn't exist yet)
  create_traefik_service

  # Check for and prepare existing certificates
  local existing_cert
  existing_cert=$(find_existing_wildcard_cert)
  if [[ -n "${existing_cert}" ]]; then
    log_msg "INFO" "Found existing wildcard certificate: ${existing_cert}"
    ensure_cert_readable "${existing_cert}"
  fi

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
  generate_traefik_config
  install_appmo_cli
  install_autopull
  setup_path

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

    log_msg "INFO" "Note: Traefik service must be started/managed by system administrator"
    log_msg "INFO" "The appmotel user does not have permissions to manage system services"
    log_msg "INFO" "Traefik automatically reloads configuration from ~/.config/traefik/dynamic/"

    log_msg "INFO" "======================================"
    log_msg "INFO" "Installation complete!"
    log_msg "INFO" "======================================"
    log_msg "INFO" "Traefik: https://localhost (dashboard may be available)"
    log_msg "INFO" "CLI tool: ~/.local/bin/appmo"
    log_msg "INFO" ""
    log_msg "INFO" "Add your first app:"
    log_msg "INFO" "  appmo add <app-name> <github-url> <branch>"
    log_msg "INFO" ""
    log_msg "INFO" "Example:"
    log_msg "INFO" "  appmo add myapp https://github.com/username/myrepo main"
    return 0
  fi

  # Not appmotel user, need to switch
  log_msg "INFO" "Switching to ${APPMOTEL_USER} user for installation"

  # Check if we can switch to appmotel user
  if ! sudo /bin/su - appmotel -c "echo test" &>/dev/null; then
    log_msg "ERROR" "Cannot switch to ${APPMOTEL_USER} user"
    log_msg "ERROR" "Make sure you have permission: sudo su - appmotel"
    log_msg "ERROR" ""
    log_msg "ERROR" "If system-level setup is not done, run as root first:"
    log_msg "ERROR" "  sudo bash install.sh"
    exit 1
  fi

  # Switch to appmotel user and run installation
  sudo -u appmotel bash -c "cd '${SCRIPT_DIR}' && bash install.sh"

  local exit_code=$?

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
