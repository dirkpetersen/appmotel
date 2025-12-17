# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Appmotel is a no-frills PaaS system using ubiquitous components such as Systemd and GitHub runner in combination with Traefik, a reverse proxy with advanced capabilities.

## Quick Reference Commands

```bash
# Development testing (from apps user)
sudo -u appmotel bash reset-home.sh --force  # Reset appmotel home for clean install
sudo bash install.sh                          # System-level setup (as root)
sudo su - appmotel && bash install.sh         # User-level setup (as appmotel)

# Validate Bash scripts before committing
bash -n script.sh

# Service management
sudo -u appmotel sudo systemctl status traefik-appmotel
sudo -u appmotel systemctl --user status appmotel-autopull.timer

# App testing
sudo -u appmotel appmo add flask-test https://github.com/dirkpetersen/appmotel main examples/flask-hello
sudo -u appmotel appmo status
sudo -u appmotel appmo logs flask-test
```

## Code Language and Style

**Primary Language:** Bash (version <= 4.4.20)

Use Bash for all installation and configuration tasks. Use Go only for advanced features where Bash would be unmaintainable.

### Bash Coding Standards

**Required Strict Mode Preamble:**
```bash
#!/usr/bin/env bash
set -o errexit   # Exit on most errors
set -o nounset   # Disallow expansion of unset variables
set -o pipefail  # Return value of a pipeline is the last non-zero status
IFS=$'\n\t'      # Set Internal Field Separator to newline and tab only
```

**Modern Bash Features to Use:**
- **Associative Arrays (4.0+):** `declare -A` for hashmaps
- **Namerefs (4.3+):** `declare -n` to pass variables by reference
- **Parameter Transformation (4.4):** `${var@Q}` for safe quoting
- **Double Brackets:** Always use `[[ ... ]]` for conditionals
- **Integer Declaration:** `declare -i` for math counters
- **Constants:** `declare -r` or `readonly` for immutable values

**Command Line Parsing:** Use manual `while` loop with `case` (not `getopt` or `getopts`). See `bin/appmo` for reference implementation.

**Performance:**
- Avoid subshells; use native Bash parameter expansion over `sed`/`awk` for simple operations
- Use `while IFS= read -r line; do ... done < file` instead of `cat file | while read line`
- Use `printf "[%(%Y-%m-%d %H:%M:%S)T]" -1` for timestamps (native, no subshell)

**Variable Naming:**
- `snake_case` for functions and variables
- `UPPERCASE` for exported environment variables and constants
- Always use `local` for function variables

**Idempotency:** All scripts must be safe to run multiple times.

## Architecture

### Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Main installation script (handles both root and user-level setup) |
| `bin/appmo` | CLI tool for managing apps |
| `bin/appmo-completion.bash` | Shell completion for appmo |
| `templates/appmotel-autopull.*` | Systemd units for automatic git polling |
| `.claude/skills/` | Reference docs for bash, traefik, troubleshooting, DNS |

### Directory Structure (appmotel user)

```
/home/appmotel/
├── .config/
│   ├── appmotel/
│   │   ├── .env              # Main appmotel configuration
│   │   └── <app>/            # Per-app config (metadata.conf, physical .env)
│   ├── traefik/
│   │   ├── traefik.yaml      # Static config
│   │   └── dynamic/          # Per-app routing (auto-watched)
│   └── systemd/user/         # User services
├── .local/
│   ├── bin/                  # traefik, appmo binaries
│   └── share/
│       ├── appmotel/<app>/   # App git repos (repo/.env is symlink to config/.env)
│       └── traefik/acme.json # ACME certificates (mode 600)
```

**Note:** Each app's physical `.env` file lives in `~/.config/appmotel/<app>/.env`. The repository has a symlink at `~/.local/share/appmotel/<app>/repo/.env` pointing to the config directory.

### Application Deployment Flow

1. `appmo add <name> <github-url> [branch]` clones repo
2. Detects app type (Go/Python/Node.js), installs dependencies or builds binary
3. Runs app's `install.sh`
4. Assigns port (from `.env` or auto-assigned 10001-59999)
5. Creates systemd user service and Traefik dynamic config
6. Autopull timer checks for git updates every 2 minutes

**App Type Detection Priority:** Go (`go.mod`) > Python (`requirements.txt`) > Node.js (`package.json`)

### appmo CLI Commands

```bash
appmo add <app> <url|user/repo> [branch]  # Deploy new app (short form auto-expands)
appmo remove <app>              # Remove app completely (backs up .env)
appmo rm <app>                  # Alias for remove
appmo list                      # List all apps
appmo status [app]              # Show status
appmo start|stop|restart <app>  # Service control
appmo update <app>              # Pull and redeploy
appmo autopull                  # Check all apps for updates
appmo logs <app> [lines]        # View logs
appmo env <app>                 # Edit app's .env file in default editor
appmo exec <app> <cmd>          # Run command in app env
appmo backup|restore|backups    # Backup management
```

**Note on `remove`/`rm`:** When removing an app, the `.env` file is backed up to `.env.backup`. If the same app is re-added, the user is prompted to restore it.

### App Requirements

Each deployed app needs:
1. `.env` file with `PORT` (or auto-assigned)
2. `install.sh` script (runs on deploy and update)
3. Entry point: `go.mod`, `app.py`, `package.json` with start script, or `Procfile`

**Optional `.env` settings:**
- `MEMORY_LIMIT=512M`, `CPU_QUOTA=100%` - Resource limits
- `RATE_LIMIT_AVG=100`, `RATE_LIMIT_BURST=50` - Rate limiting
- `HEALTH_CHECK_PATH=/health` - Health check endpoint

### .env File Management

**Storage:** Physical `.env` files are stored in `~/.config/appmotel/<app>/.env` (not in the repo). This enables:
- **Persistent configuration** across app reinstalls/updates
- **Backup/restore workflow**: When removing an app, `.env` is backed up to `.env.backup`
- **Restore prompt**: When re-adding an app with an existing backup, user is asked whether to restore it

**Workflow:**
1. `appmo add myapp ...` → Creates `.env` from template or backup
2. `appmo env myapp` → Edit `.env` in $EDITOR (physical in config dir)
3. `appmo remove myapp` → Backs up `.env` to `.env.backup`
4. `appmo add myapp ...` again → Prompts to restore previous `.env` or start fresh

### Traefik Configuration

**Locations:**
- Binary: `~/.local/bin/traefik`
- Static config: `~/.config/traefik/traefik.yaml`
- Dynamic configs: `~/.config/traefik/dynamic/` (auto-watched)
- ACME storage: `~/.local/share/traefik/acme.json` (mode 600)

**Entry Points:** Port 80 (web, redirects to HTTPS) and 443 (websecure)

**CRITICAL Traefik v3 Notes:**
1. TLS certificate stores MUST be in dynamic configuration, not static
2. Router TLS sections must use `tls: {}` (empty object), NOT `tls:` (null)
3. Certificate access uses `ssl-cert` group with mode 640 for private keys

See `.claude/skills/traefik.md` for detailed configuration examples.

## Environment Configuration

**Location:** `/home/appmotel/.config/appmotel/.env` (shared between root and user installations)

**Key Variables:**
- `BASE_DOMAIN` - Base domain for apps (e.g., `apps.example.edu`)
- `USE_LETSENCRYPT` - "yes" or "no"
- `LETSENCRYPT_EMAIL` - Email for Let's Encrypt
- `LETSENCRYPT_MODE` - "http" (HTTP-01) or "dns" (DNS-01 via Route53)
- `AWS_HOSTED_ZONE_ID`, `AWS_REGION` - For DNS-01 mode (credentials via IAM role preferred)

## Systemd Architecture

**Three-Tier Permission Model:**

| Tier | User | Capabilities |
|------|------|--------------|
| 1 | `apps` (operator) | Full control over appmotel user via sudoers |
| 2 | `appmotel` (service) | User services + LIMITED sudo for Traefik only |
| 3 | Root | Only Traefik service management |

**Service Types:**
- **System service:** `traefik-appmotel.service` (binds 80/443, requires `sudo systemctl`)
- **User services:** `appmotel-<app>.service` (high ports, uses `systemctl --user`)

**Correct Command Format:**
```bash
# Traefik (from operator user)
sudo -u appmotel sudo systemctl restart traefik-appmotel

# App services (no sudo needed)
sudo -u appmotel systemctl --user restart appmotel-myapp
```

See `DEV-SETUP.md` for complete execution model documentation.

## Development Environment

**Users:**
- `apps` (operator) - Development user with full control over appmotel via sudoers, authenticated to GitHub
- `appmotel` (service) - Target deployment user, limited sudo for Traefik only

**Clean Install Testing:**
```bash
sudo -u appmotel bash reset-home.sh --force  # Reset home directory
sudo bash install.sh                          # System-level (creates user, services, sudoers)
sudo su - appmotel && bash install.sh         # User-level (Traefik, appmo, configs)
```

## Installation

The `install.sh` script handles both root and user-level installation:

1. **As root:** Creates appmotel user, Traefik systemd service, sudoers config, enables linger
2. **As appmotel:** Downloads Traefik, generates configs, installs appmo CLI, sets up autopull timer

```bash
# Step 1: System setup
sudo bash install.sh

# Step 2: User setup (follow prompts, or run manually)
sudo su - appmotel
bash install.sh
```

## AWS Deployment

`install-aws.sh` provides automated EC2 deployment with Route53 DNS integration:

```bash
bash install-aws.sh [instance-type] [region]  # Default: t4g.micro us-west-2
```

- Creates EC2 instance with IAM role for Route53 (no AWS keys needed)
- Auto-detects hosted zone, creates wildcard DNS records
- Configures DNS-01 challenge for wildcard certificates
- Connection: `ssh -i ~/.ssh/appmotel-key.pem ec2-user@<ip>`

## Testing

See `TESTING.md` for complete test procedures.

**Quick Validation:**
```bash
bash -n script.sh                                    # Syntax check
sudo -u appmotel appmo status                        # Check all apps
sudo -u appmotel sudo systemctl status traefik-appmotel  # Traefik status
sudo -u appmotel journalctl --user -u appmotel-autopull  # Autopull logs
```

**Test App Deployment:**
```bash
sudo -u appmotel appmo add flask-test https://github.com/dirkpetersen/appmotel main examples/flask-hello
sudo -u appmotel appmo status flask-test
sudo -u appmotel appmo logs flask-test
```
