# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Appmotel is a no-frills PaaS system using ubiquitous components such as Systemd and GitHub runner in combination with Traefik, a reverse proxy with advanced capabilities.

## Code Language and Style

**Primary Language:** Bash (version <= 4.4.20)

Use Bash for all installation and configuration tasks and most general coding tasks. Follow strict Bash 4.4 coding guidelines (detailed below). Use Go only for advanced features where Bash would be unmaintainable.

### Bash Coding Standards (Bash 4.4.20)

**Strict Mode Preamble (Required for all scripts):**
```bash
#!/usr/bin/env bash
set -o errexit   # Exit on most errors
set -o nounset   # Disallow expansion of unset variables
set -o pipefail  # Return value of a pipeline is the last non-zero status
IFS=$'\n\t'      # Set Internal Field Separator to newline and tab only
```

**Modern Bash Features to Use:**
- **Associative Arrays (Bash 4.0+):** Use `declare -A` for hashmaps instead of multiple arrays
- **Namerefs (Bash 4.3+):** Use `declare -n` to pass variables by reference to functions
- **Parameter Transformation (Bash 4.4):** Use `${var@Q}` for safe quoting when generating commands dynamically
- **Double Brackets:** Always use `[[ ... ]]` for conditionals (supports regex `=~` and pattern matching, safer than `[ ... ]`)
- **Integer Declaration:** Use `declare -i` for math counters to prevent string concatenation accidents
- **Constants:** Use `declare -r` or `readonly` for immutable values

**Command Line Parsing:**
Use manual `while` loop with `case` (not `getopt` or `getopts`):
```bash
while :; do
  case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) param_verbose=1 ;;
    -f | --file)
      if [[ -z "${2-}" ]]; then die "Option $1 requires an argument"; fi
      param_file="${2}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
  esac
  shift
done
```

**Performance Guidelines:**
- Avoid subshells when possible
- Use native Bash parameter expansion over `sed`/`awk` for simple operations
- Use `while IFS= read -r line; do ... done < file` instead of `cat file | while read line`
- Use `printf "[%(%Y-%m-%d %H:%M:%S)T]" -1` for timestamps (Bash 4.2+ native, no subshell)

**Variable Naming:**
- Use `snake_case` for function and variable names
- Uppercase for exported environment variables and constants
- Always use `local` for function variables to avoid global scope pollution

**Idempotency:**
All installation and configuration scripts must be strictly idempotent. You can use `sed` for editing config files but ensure actions can be run multiple times safely.

## Architecture

### Application Deployment Model

When a new application is configured in Appmotel:
1. The GitHub repository URL and branch are specified
2. Appmotel clones the repository
3. A systemd timer automatically polls the repository for updates every 2 minutes
4. Each application is accessible via a subdomain under `BASE_DOMAIN` (e.g., `myapp.apps.example.edu`)
5. DNS routing can be handled through subdomain delegation or cgroups

**Automatic Updates (Autopull):**
- A systemd timer (`appmotel-autopull.timer`) runs every 2 minutes
- The timer calls `appmo autopull` which checks all configured apps for updates
- For each app, it runs `git fetch` and compares local vs remote HEAD
- If updates are found, it automatically runs `appmo update <app-name>`
- This provides automatic deployment without requiring public server access
- Works on private networks (only outbound git connections needed)
- Logs available via `journalctl --user -u appmotel-autopull`
- Can be manually triggered: `appmo autopull`

### The `appmo` CLI Tool

**Implementation:** Try Bash first (following project standards). Fall back to Go if the code becomes too complex or difficult to maintain.

**Directory Structure:**
- App metadata: `/home/appmotel/.config/appmotel/apps/<app-name>/` (stores GitHub URL, branch, assigned port, last deployment timestamp)
- Git repositories: `/home/appmotel/.local/share/appmotel/<app-name>/repo/`
- Systemd user services: `/home/appmotel/.config/systemd/user/appmotel-<app-name>.service`
- Traefik dynamic configs: `/home/appmotel/.config/traefik/dynamic/<app-name>.yaml`
- CLI tool location: `/home/appmotel/.local/bin/appmo`

**Supported Commands:**
- `appmo add <app-name> <github-url> [branch]` - Add and deploy a new app (default: main)
- `appmo remove <app-name>` - Remove app (stop service, remove Traefik config, delete all app files)
- `appmo list` - List all configured apps
- `appmo status [app-name]` - Show running state, port, URL, last deployment time (checks both systemd status and actual port response)
- `appmo start <app-name>` - Start app (systemctl wrapper)
- `appmo stop <app-name>` - Stop app (systemctl wrapper)
- `appmo restart <app-name>` - Restart app
- `appmo update <app-name>` - Manually trigger pull + reinstall (with automatic backup and rollback on failure)
- `appmo autopull` - Check all apps for git updates and automatically deploy (used by systemd timer)
- `appmo logs <app-name>` - View logs (journalctl wrapper)
- `appmo exec <app-name> <command>` - Run command in app's environment
- `appmo backup <app-name>` - Create a backup of an app
- `appmo restore <app-name> [backup-id]` - Restore an app from backup
- `appmo backups <app-name>` - List available backups for an app

**App Naming Rules:**
- No spaces allowed in app names
- App names must be valid DNS subdomain labels (alphanumeric and hyphens)

**Conflict Handling:**
- If an app name already exists: error and exit
- If a subdomain conflicts with existing app: error and exit
- If an assigned port is already in use: error and exit

**Application Requirements:**

Each app repository must contain:
1. `.env` file - Environment variables and configuration
2. `install.sh` - Installation/setup script (run on initial deploy and every update)

**Port Assignment Logic:**
1. Check for `PORT` variable in `.env`
2. If not found, check for other variables containing "PORT" in the name (e.g., `APP_PORT`, `HTTP_PORT`)
3. If found, use that: `PORT=$OTHERPORT`
4. If not found, assign a random unused port between 10001-59999
5. Configure Traefik dynamic config with the assigned port

**Supported Application Types:**

*Python Apps:*
- Detect `requirements.txt` → create `.venv` in repo dir → `pip install -r requirements.txt`
- Run command priority: `app.py`, single `.py` file, or single executable in `bin/` folder
- Use `python3` explicitly for all Python commands

*Node.js Apps:*
- Detect `package.json` → `npm install`
- Run command using `npm start` (reads from `package.json` → `scripts.start`)

*Multiple Process Apps (Procfile support):*
- Apps requiring multiple processes (e.g., web server + worker) are supported through Procfile
- Each process gets its own service: `appmotel-<app-name>-<process-name>`
- Procfile format:
  ```
  web: python app.py
  worker: python worker.py
  ```
- The `web` process receives the main port, other processes get incrementing ports

**Resource Limits:**
Apps can configure resource limits in their `.env` file:
- `MEMORY_LIMIT=512M` - Maximum memory (default: 512M)
- `CPU_QUOTA=100%` - CPU quota percentage (default: 100%)

**Rate Limiting:**
Traefik rate limiting is enabled by default:
- `RATE_LIMIT_AVG=100` - Average requests per second (default: 100)
- `RATE_LIMIT_BURST=50` - Burst requests allowed (default: 50)
- `DISABLE_RATE_LIMIT=true` - Disable rate limiting for this app

**Health Checks:**
Traefik health checks are configured automatically:
- `HEALTH_CHECK_PATH=/health` - Health check endpoint (default: /health)
- Health checks run every 30 seconds with 5 second timeout

**SSL/TLS:**
All apps automatically get HTTPS through Traefik's Let's Encrypt integration.

**System Dependencies:**
If an app's `install.sh` requires system packages (e.g., `apt install`), the script should print what is required. System packages must be installed manually by the administrator.

**App Execution:**
- All apps run as the `appmotel` user (no per-app user isolation)
- Managed as systemd user services: `appmotel-<app-name>`
- Services located in `/home/appmotel/.config/systemd/user/`
- Managed with `systemctl --user` commands (no sudo required for app services)
- The app's `.env` file is automatically sourced into the systemd service environment
- Logs accessible via `journalctl --user -u appmotel-<app-name>`

**Error Handling:**
- If `install.sh` fails during `appmo add`, the operation fails and rolls back
- If `install.sh` fails during an update (triggered by GitHub runner), keep the old version running
- Traefik configuration is automatically generated/updated when apps are added or removed

**Automatic Updates:**
When the GitHub runner detects a new commit:
1. Pull the latest code
2. Run `install.sh` in the app's repo directory
3. Restart the systemd service

### Traefik Configuration

**User:** `appmotel`
**Binary Location:** `~/.local/bin/traefik`
**Static Config:** `~/.config/traefik/traefik.yaml` (auto-discovered via XDG_CONFIG_HOME)
**Dynamic Config Directory:** `~/.config/traefik/dynamic/` (monitored for routers/services)
**ACME Storage:** `~/.local/share/traefik/acme.json` (mode 600)

**Systemd Service:** `/etc/systemd/system/traefik-appmotel.service`
- System-level service (requires root to create/modify)
- Runs Traefik process as user `appmotel`
- Uses `AmbientCapabilities=CAP_NET_BIND_SERVICE` to bind ports 80/443
- Environment variables: `XDG_CONFIG_HOME=/home/appmotel/.config` and `XDG_DATA_HOME=/home/appmotel/.local/share`
- No `--configFile` argument needed (uses XDG auto-discovery)

**Service Management:**
The `appmotel` user can manage Traefik via sudoers configuration at `/etc/sudoers.d/appmotel`:
```bash
sudo systemctl restart traefik-appmotel
sudo systemctl status traefik-appmotel
```

**Entry Points:**
- `web`: Port 80 (auto-redirects to HTTPS)
- `websecure`: Port 443

**Dynamic Configuration:**
Add YAML files to `~/.config/traefik/dynamic/` for application routing. Traefik watches this directory and auto-reloads changes.

**CRITICAL TLS Configuration Notes (Traefik v3):**
1. **TLS certificate stores MUST be in dynamic configuration, NOT static configuration**
   - Create a separate file (e.g., `tls-config.yaml`) in the dynamic directory
   - Example:
     ```yaml
     tls:
       stores:
         default:
           defaultCertificate:
             certFile: /etc/letsencrypt/live/domain.edu/fullchain.pem
             keyFile: /etc/letsencrypt/live/domain.edu/privkey.pem
     ```
2. **Router TLS sections must use `tls: {}` (empty object), NOT `tls:` (null/empty)**
   - Correct: `tls: {}`
   - Incorrect: `tls:` or `tls: null`
   - The empty object syntax properly enables TLS termination
3. **Certificate Access**: The `appmotel` user must have secure read access to certificate files
   - Uses `ssl-cert` group (Debian/Ubuntu convention)
   - Private keys: mode 640 (NOT world-readable!)
   - Directories: mode 750
   - On Debian/Ubuntu: `apt-get install ssl-cert` provides the group
   - On RHEL/CentOS: Group must be created manually with `groupadd ssl-cert`

## Environment Configuration

Configuration is managed via `.env` file located at `/home/appmotel/.config/appmotel/.env`:

**Location:** `/home/appmotel/.config/appmotel/.env`

This fixed location allows both root and user installations to access the same configuration. The file is created automatically from `.env.default` (downloaded from GitHub if needed) during the first installation.

**Configuration Variables:**
- `USE_LETSENCRYPT`: "yes" or "no"
- `LETSENCRYPT_EMAIL`: Email for Let's Encrypt notifications
- `LETSENCRYPT_MODE`: "http" (HTTP-01 challenge) or "dns" (DNS-01 via Route53)
- `BASE_DOMAIN`: Base domain for applications
- AWS credentials (only for DNS-01 challenge mode)

**Note:** The `.env` file is shared between system-level (root) and user-level (appmotel) installations.

## Systemd Architecture

Appmotel uses a mixed systemd model:

**System-Level Service (requires root):**
- `traefik-appmotel.service` - Located in `/etc/systemd/system/`
- Managed with `systemctl` (requires sudo for appmotel user)
- Runs Traefik process as `appmotel` user but binds to privileged ports (80/443)
- Uses `AmbientCapabilities=CAP_NET_BIND_SERVICE`

**User-Level Services (no root required):**
- Application services: `appmotel-<app-name>.service`
- Located in `/home/appmotel/.config/systemd/user/`
- Managed with `systemctl --user` by the `appmotel` user
- No sudo required for app service management
- All apps run as `appmotel` user on high ports (>1024)

**Sudoers Configuration:**
Located in `/etc/sudoers.d/appmotel`:
```bash
# Allow operator user to switch to appmotel interactively
apps ALL=(ALL) NOPASSWD: /bin/su - appmotel

# Allow operator user to run any command as appmotel (for automation)
apps ALL=(appmotel) NOPASSWD: ALL

# Allow appmotel to manage ONLY the Traefik system service
appmotel ALL=(ALL) NOPASSWD: /bin/systemctl restart traefik-appmotel, /bin/systemctl stop traefik-appmotel, /bin/systemctl start traefik-appmotel, /bin/systemctl status traefik-appmotel
```

**Execution Model (Three-Tier Delegation):**
1. **Operator user (apps)** → Has full control over appmotel user
2. **Service user (appmotel)** → Has LIMITED sudo for Traefik systemctl commands only
3. **Root** → Strictly limited to Traefik service management

**Managing Traefik Service (correct command format):**
```bash
# From operator user, execute as appmotel, then use sudo
sudo -u appmotel sudo systemctl start traefik-appmotel
sudo -u appmotel sudo systemctl restart traefik-appmotel
sudo -u appmotel sudo systemctl status traefik-appmotel
```

**Note:** App services do NOT need root - they use `systemctl --user`. Traefik config changes are auto-reloaded (no restart needed).

See `DEV-SETUP.md` for complete execution model documentation.

## Development Environment

**Target Deployment User:** `appmotel` (home directory: `/home/appmotel`)
**Development User:** `apps` (current user)

**Access Model:**
- The `apps` user has full control over the `appmotel` user via sudoers
- The `apps` user does NOT have general sudo/root access
- The `appmotel` user has limited sudo for Traefik service management only
- System-level operations (Traefik systemd service, sudoers) are pre-configured by system administrator
- App deployment and management does not require root access (except Traefik service restarts)

**GitHub Access:** The `apps` user is fully authenticated to GitHub and can run `gh` CLI commands for repository operations, issues, pull requests, and releases.

### Testing and Re-deployment

Before testing a fresh deployment:
1. Switch to `appmotel` user: `sudo su - appmotel`
2. Clean the entire home directory if needed: `rm -rf /home/appmotel/*` and `rm -rf /home/appmotel/.[^.]*` (preserves `.` and `..`)
3. Return to `apps` user: `exit`
4. Run deployment scripts from the repository

This allows testing clean installations and ensures deployment scripts handle first-time setup correctly.

## Installation

The `install.sh` script intelligently handles both system and user-level installation:

### Installation Process

**Step 1: System-Level Setup (run as root):**
```bash
sudo bash install.sh
```

This performs:
1. Creates the `appmotel` user
2. Creates `/etc/systemd/system/traefik-appmotel.service`
3. Configures `/etc/sudoers.d/appmotel`
4. Enables systemd linger for appmotel user

After completion, it instructs you to switch to the appmotel user and run the installation.

**Step 2: User-Level Setup (run as appmotel user):**

Switch to the appmotel user and run the installation:

```bash
sudo su - appmotel
curl -fsSL "https://raw.githubusercontent.com/dirkpetersen/appmotel/main/install.sh?$(date +%s)" | bash
```

Or if you have the repository locally:

```bash
sudo su - appmotel
cd /path/to/appmotel
bash install.sh
```

The script performs:
1. Downloads Traefik binary to `/home/appmotel/.local/bin/`
2. Creates required directory structure
3. Generates Traefik configuration files (including Let's Encrypt setup based on `.env`)
4. Installs the `appmo` CLI tool to `/home/appmotel/.local/bin/`
5. Adds `~/.local/bin` to PATH in `.bashrc`
6. Sets up autopull service for automatic updates

The installation script is idempotent and handles both fresh installations and updates.

## Development Workflow

**Documentation Location:** All requirements and coding instructions are in the `reqs/` folder.

**Key Files:**
- `reqs/README.md`: Application requirements and installation overview
- `reqs/howto-bash.md`: Detailed Bash coding guidelines (golden master template)
- `reqs/traefik-config.md`: Complete Traefik installation and configuration guide

## Testing and Validation

When writing Bash scripts:
1. Always test with `bash -n script.sh` (syntax check) before execution
2. Ensure scripts are idempotent (can be run multiple times safely)
3. Test with strict mode enabled
4. Verify proper error handling with `set -o errexit` and `set -o pipefail`
