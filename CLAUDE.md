# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Appmotel is a no-frills PaaS system using Systemd, Traefik (reverse proxy), and GitHub for app deployment and management.

## Running from Operator Account (apps user)

`appmo` auto-elevates: it re-execs itself as `sudo -u appmotel /home/appmotel/.local/bin/appmo` (exact path, no `env` in front), since app files and `systemctl --user` services are owned by `appmotel`. Allowed are members of the group `appmotel-users` (a sudoers rule for exactly that file, created by `sudo bash install.sh`), operators (group `appmotel-ops` plus `OPERATOR_USERS`, any command as appmotel), and root. After the switch, `appmo` logs `user=<SUDO_USER> cmd=...` to syslog (`journalctl -t appmo`). Do not prefix `sudo -u appmotel`:

```bash
appmo add myapp user/repo main
appmo list
appmo status myapp
```

A few user-specific commands (e.g. `appmo skill`) are exempt and always run as the invoking user rather than elevating. See `bin/appmo`'s `APPMO_LOCAL_COMMANDS` for the exempt list.

See `.claude/skills/appmotel/SKILL.md` for the complete 24x7 automation guide.

## Quick Reference Commands

```bash
# Development testing
sudo -u appmotel bash bin/reset-home.sh --force  # Reset appmotel home
sudo bash install.sh                             # System-level setup (root)
sudo -u appmotel bash install.sh                 # User-level setup

# Validate Bash scripts before committing
bash -n bin/appmo
bash -n install.sh

# Service management
sudo -u appmotel sudo systemctl status traefik-appmotel
sudo -u appmotel systemctl --user status appmotel-autopull.timer

# App testing
appmo add flask-test https://github.com/dirkpetersen/appmotel main examples/flask-hello
appmo status flask-test
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

See `.claude/skills/bash/SKILL.md` for full coding standards (associative arrays, namerefs, performance tips).

## Architecture

### Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Main installer (root + user-level setup) |
| `install-aws.sh` | EC2 deployment with Route53 DNS (wraps install.sh) |
| `bin/appmo` | CLI tool for managing apps (~4200 lines); commands are `cmd_<name>` functions, dispatched by the `case` block at the end of the file |
| `bin/appmo-completion.bash` | Shell completion for appmo (static command list) |
| `bin/appmotel-fix-certs` | Root helper, installed to `/usr/local/bin`, that makes `/etc/letsencrypt` readable via the `ssl-cert` group; `appmotel` may run it via sudoers |
| `templates/appmotel-autopull.*` | Systemd units for 2-minute git polling |
| `templates/github-workflow.yml` | Example SSH deploy workflow for app repos (not used by this repo) |
| `.github/workflows/issue-auto-fix.yml` | Runs Claude Code (Bedrock) on each new issue and opens a `fix/issue-N` PR |
| `examples/flask-hello/`, `examples/express-hello/`, `examples/zensical-wiki/` | Reference apps for testing |

To add a CLI command: write `cmd_<name>`, add it to the dispatch `case` in `bin/appmo`, add it to `commands=` in `bin/appmo-completion.bash`, and add it to `APPMO_LOCAL_COMMANDS` only if it must not elevate to `appmotel`.

### Testing

There is no full test suite. Run `bash -n` on each changed script, and `bash tests/test-appmo.sh` (no root needed) for the input checks that guard isolated apps (Traefik values, Python version requests, `appmotel-user` names). Functional tests are manual, on a host with appmotel installed: deploy the example apps and follow `docs/TESTING.md` (clean install, idempotency re-run, per-runtime deploys, CLI commands).

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
    ├── appmotel-backups/       # App backups (tar.gz, BACKUP_RETENTION=5 default)
    └── traefik/acme.json       # ACME certificates (mode 600)

Port range for app assignments: 10001–59999 (auto-assigned if not set in app `.env`).
```

### Key Safety Functions in bin/appmo

| Function | Purpose |
|----------|---------|
| `safe_rm_rf <path> <ctx>` | Delete only within allowed dirs; rejects symlinks, empty paths, critical dirs |
| `safe_source_env <file>` | Source `.env` after rejecting `$(...)`, backticks, semicolons, pipes |
| `safe_source_metadata <file>` | Source `metadata.conf` using a whitelist of allowed keys |

### App Runtime Detection

`bin/appmo` detects app type in this priority order (see `detect_app_type`):

1. **Zensical** — `zensical.toml` present and no `app.py`/`main.py`/`start.sh`/`Procfile` → installs `zensical` into `.venv`, runs `zensical build --clean` on every add/update/restore, serves `site/` with a built-in static server (`.venv/bin/appmotel-static-server`)
2. **Go** — `go.mod` present → builds via `go build`, binary placed in `bin/`
3. **Python** — `requirements.txt` or `pyproject.toml` → creates `.venv`, runs `app.py`
4. **Node.js** — `package.json` → runs `npm install && npm start`
5. **Procfile** — multiple named processes (e.g., `web:`, `worker:`) → one systemd service per process; only `web` is exposed via Traefik
6. **Binary** — executable in `bin/` directory

For subfolder deploys (`appmo add app repo/tree/main/subdir`), dependency files are searched upward to the repo root. The `.env` template (`.env.default`, `.env.example`, ...) is taken from the subfolder only (`setup_app_env_file`); the appmotel repo's own root `.env.default` is the global config template and must never become an app `.env`.

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
appmo env <app>             # Edit app .env (vim, mouse off)
appmo env <app> get|set KEY [VALUE]  # One value; set reads stdin without VALUE; audit log hides the value
appmo exec <app> <cmd>      # Run command in app env
appmo backup|restore|backups  # Backup management
appmo self-update           # Update CLI, Traefik, configs, propagate domain changes
```

### Global `.env` Settings (`~/.config/appmotel/.env`)

- `BASE_DOMAIN=dev-ai.example.edu` — Primary domain for all apps (`app.BASE_DOMAIN`)
- `OPERATOR_USERS=apps` — Who may control the appmotel user via sudoers (users, `%groups`, or `ALL` for every user). The group `appmotel-ops` (created by `sudo bash install.sh`) is always added. Applied by `sudo bash install.sh`; unset keeps an existing `ALL` grant, else `apps`
- `APPMOTEL_BIND_IP=192.0.2.40` — Optional: Traefik listens on this IP only for ports 80/443 (second NIC). Unset keeps an IP that `traefik.yaml` already binds to (`resolve_bind_ip` in `install.sh`); empty means all addresses. Not named `TRAEFIK_*`, because Traefik reads such env vars as its own config
- `REDIRECT_BASE_DOMAIN=old.example.edu` — Optional: 308 permanent redirect from old domain to `BASE_DOMAIN`. When set, `appmo self-update` generates a single Traefik catch-all config that redirects `*.old.example.edu` → `*.BASE_DOMAIN`

### Optional App `.env` Settings

- `MEMORY_LIMIT=512M`, `CPU_QUOTA=100%` — Resource limits
- `RATE_LIMIT_AVG=100`, `RATE_LIMIT_BURST=50` — Rate limiting
- `HEALTH_CHECK_PATH=/health` — Health check endpoint
- `AUTO_DEBUG=no` — Disable auto-debug error detection for this app
- `BACKUP_RETENTION=5` — Number of backups to keep per app (default: 5)

### Traefik & TLS

Per-app dynamic configs are auto-generated in `~/.config/traefik/dynamic/`. Wildcard certs (`*.BASE_DOMAIN`) are supported via pre-existing certs or DNS-01 challenge with Route53.

**CRITICAL Traefik v3:** TLS stores MUST be in dynamic config, not static. When using pre-existing wildcard certs, use bare `tls: {}` (not `certResolver`).

See `.claude/skills/traefik/SKILL.md` for configuration details.

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

### Isolated apps (`appmo add --isolated`, `appmo isolate`)

User-facing docs: `docs/ISOLATED-APPS.md`.

An isolated app runs as its own user `a-<app>` (group `appmotel-apps`, home mode 700). The root helper `bin/appmotel-user` (installed to `/usr/local/bin`) creates and deletes these users and writes `/etc/sudoers.d/appmotel-a-<app>` so that `appmotel` may run anything as that user. The app user has no sudo rights; the operator sudoers rules exclude `!%appmotel-apps`.

- `bin/appmo` has two roles. Run as `appmotel` it is in **admin** role. Run as an `a-*` user it is in **app** role (`APPMO_ROLE=app`): all per-app paths (`APPS_CONFIG_DIR`, `APPS_DATA_DIR`, `SYSTEMD_USER_DIR`, `BACKUPS_DIR`) point into that user's home, it never elevates, and it does not write Traefik config.
- In admin role, an isolated app has only `~/.config/appmotel/<app>/isolated.conf` (user, port). `main()` sends per-app commands to `run_appmo_as_app`, which runs `appmo` as the app user, then `sync_isolated_traefik` rebuilds the route. Values read from the app user's files are untrusted; `create_traefik_config` validates them.
- `secure_appmotel_files` (same code in `install.sh` and `bin/appmo`, also run by autopull) removes group/other access from everything in `/home/appmotel` except `~/.local/bin`. `/home/appmotel` is world-traversable (751) for the `/usr/local/bin/appmo` symlink, so these modes are what keeps app users out.
- `install_app_port_firewall` (root part of `install.sh`) installs `appmotel-firewall.service`, which loads `/etc/appmotel/app-ports.nft`: new TCP connections to 10001-59999 are dropped unless they come in on `lo` (Traefik uses `http://localhost:<port>`). Keep `ct state new` in that rule: the ephemeral port range overlaps, and replies to outgoing connections must pass.
- `install_journal_access` (root part of `install.sh`) writes `/etc/tmpfiles.d/appmotel-journal.conf`, a read ACL on `/var/log/journal` for `appmotel-ops`. A group cannot join `systemd-journal`, and an ACL also covers members added later. Skipped with a WARN if the journal is volatile.
- Open item: an app user can still connect to other apps' localhost ports directly (no network isolation between apps on the host yet).

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
