# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Appmotel is a no-frills PaaS system using Systemd, Traefik (reverse proxy), and GitHub for app deployment and management.

## Running from Operator Account (apps user)

**CRITICAL:** All appmotel commands must be prefixed with `sudo -u appmotel`:

```bash
sudo -u appmotel appmo add myapp user/repo main
sudo -u appmotel appmo list
sudo -u appmotel appmo status myapp
```

See `.claude/skills/appmotel.md` for the complete 24x7 automation guide.

## Quick Reference Commands

```bash
# Development testing
sudo -u appmotel bash bin/reset-home.sh --force  # Reset appmotel home
sudo bash install.sh                             # System-level setup (root)
sudo su - appmotel && bash install.sh            # User-level setup

# Validate Bash scripts before committing
bash -n script.sh

# Service management
sudo -u appmotel sudo systemctl status traefik-appmotel
sudo -u appmotel systemctl --user status appmotel-autopull.timer

# App testing
sudo -u appmotel appmo add flask-test https://github.com/dirkpetersen/appmotel main examples/flask-hello
sudo -u appmotel appmo status flask-test
```

## Code Language and Style

**Primary Language:** Bash (version <= 4.4.20). Use Go only where Bash would be unmaintainable.

**Required Strict Mode Preamble:**
```bash
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
IFS=$'\n\t'
```

**Key Rules:** `[[ ]]` for conditionals, `local` for function variables, `snake_case` for functions/variables, `UPPERCASE` for exported constants, manual `while`/`case` for arg parsing (not getopt). All scripts must be idempotent.

See `.claude/skills/bash.md` for full coding standards (associative arrays, namerefs, performance tips).

## Architecture

### Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Main installer (root + user-level setup) |
| `bin/appmo` | CLI tool for managing apps (~3300 lines) |
| `bin/appmo-completion.bash` | Shell completion for appmo |
| `templates/appmotel-autopull.*` | Systemd units for 2-minute git polling |
| `examples/flask-hello/`, `examples/express-hello/` | Reference apps for testing |

### Directory Structure (appmotel user)

```
/home/appmotel/
├── .config/appmotel/
│   ├── .env                    # Main config (BASE_DOMAIN, TLS, AWS creds)
│   └── <app>/                  # Per-app: metadata.conf, .env, .auto-debug-cooldown
├── .config/traefik/
│   ├── traefik.yaml            # Static config (entrypoints, ACME resolver)
│   └── dynamic/                # Per-app routing YAML (auto-watched by Traefik)
├── .config/systemd/user/       # User services (appmotel-<app>.service)
├── .local/bin/                 # traefik, appmo binaries
└── .local/share/
    ├── appmotel/<app>/repo/    # App git repos (.env symlinked to config dir)
    └── traefik/acme.json       # ACME certificates (mode 600)
```

### Key Safety Functions in bin/appmo

| Function | Purpose |
|----------|---------|
| `safe_rm_rf <path> <ctx>` | Delete only within allowed dirs; rejects symlinks, empty paths, critical dirs |
| `safe_source_env <file>` | Source `.env` after rejecting `$(...)`, backticks, semicolons, pipes |
| `safe_source_metadata <file>` | Source `metadata.conf` using a whitelist of allowed keys |

### appmo CLI Commands

```bash
appmo add <app> <url|user/repo> [branch]  # Deploy (supports GitHub tree URLs for subfolders)
appmo remove|rm <app>       # Remove app (backs up .env)
appmo list|ls               # List all apps
appmo status [app]          # Show status
appmo start|stop|restart    # Service control
appmo update <app>          # Pull and redeploy
appmo check [app]           # Check for updates (no deploy)
appmo autopull              # Check all apps + auto-debug error scan
appmo logs <app> [lines]    # View logs
appmo env <app>             # Edit app .env
appmo exec <app> <cmd>      # Run command in app env
appmo backup|restore|backups  # Backup management
appmo self-update           # Update CLI, Traefik binary, and configs
```

### Optional App `.env` Settings

- `MEMORY_LIMIT=512M`, `CPU_QUOTA=100%` — Resource limits
- `RATE_LIMIT_AVG=100`, `RATE_LIMIT_BURST=50` — Rate limiting
- `HEALTH_CHECK_PATH=/health` — Health check endpoint
- `AUTO_DEBUG=no` — Disable auto-debug error detection for this app

### Traefik & TLS

Per-app dynamic configs use `certResolver: myresolver` in the router TLS section to obtain Let's Encrypt certificates. Wildcard certs (`*.BASE_DOMAIN`) are supported via DNS-01 challenge with Route53.

**CRITICAL Traefik v3:** TLS stores MUST be in dynamic config, not static. Router TLS must use `tls:` with `certResolver`, NOT bare `tls:` (null).

See `.claude/skills/traefik.md` for configuration details.

## Systemd Architecture

| Tier | User | Capabilities |
|------|------|--------------|
| 1 | `apps` (operator) | Full control over appmotel user via sudoers |
| 2 | `appmotel` (service) | User services + limited sudo for Traefik only |
| 3 | Root | Traefik service management only |

```bash
sudo -u appmotel sudo systemctl restart traefik-appmotel  # Traefik (system service)
sudo -u appmotel systemctl --user restart appmotel-myapp   # Apps (user service)
```

## AWS Deployment

`install-aws.sh` automates EC2 deployment with Route53 DNS. On AWS, `install.sh` automatically configures **dnsmasq** for local DNS resolution (hairpin NAT workaround) so the server can reach its own apps via `*.BASE_DOMAIN`.

## Auto-Debug (Error Detection)

During each autopull cycle, appmotel scans app logs for errors. If `claude` (Claude Code CLI) and `gh` (GitHub CLI) are installed, it automatically analyzes errors and files GitHub issues. See **[docs/AUTO-DEBUG.md](docs/AUTO-DEBUG.md)** for full details, prerequisites, and configuration.

## Additional Documentation

- **[docs/AUTO-DEBUG.md](docs/AUTO-DEBUG.md)** — Automated error detection and GitHub issue filing
- **[docs/MULTI-COMPONENT.md](docs/MULTI-COMPONENT.md)** — Multi-component app deployment
- **[docs/ENV-MANAGEMENT.md](docs/ENV-MANAGEMENT.md)** — Environment variable and .env file management
- **[docs/DEV-SETUP.md](docs/DEV-SETUP.md)** — Development environment setup and permission model
- **[docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)** — Architecture and design decisions
- **[docs/TESTING.md](docs/TESTING.md)** — Comprehensive testing procedures
