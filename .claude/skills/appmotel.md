---
name: appmotel
description: Managing Appmotel PaaS from a developer account (apps user) for 24x7 automation with Claude Code
---

# Appmotel Management for Developer Accounts

## Overview

This guide explains how a developer account (e.g., `apps` user) can manage Appmotel using Claude Code or other automation tools. The system uses a three-tier permission model that allows secure, delegated control without requiring direct root access.

## Permission Model

```
┌─────────────────────────────────────────────────────────────────┐
│  TIER 1: Operator User (apps)                                   │
│  - Runs Claude Code or other automation tools                   │
│  - Has full control over the appmotel user                      │
│  - Cannot directly run root commands                            │
└───────────────────────┬─────────────────────────────────────────┘
                        │ sudo -u appmotel
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 2: Service User (appmotel)                                │
│  - Owns all Appmotel files and services                         │
│  - Manages user-level systemd services (no root needed)         │
│  - Has LIMITED sudo access for Traefik system service only      │
└───────────────────────┬─────────────────────────────────────────┘
                        │ sudo systemctl (limited)
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 3: Root (strictly limited)                                │
│  - Only for Traefik service management                          │
│  - No general root access granted                               │
└─────────────────────────────────────────────────────────────────┘
```

## Sudoers Configuration

**Location:** `/etc/sudoers.d/appmotel`

```bash
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
```

## Command Execution Patterns

### CRITICAL: Always Use `sudo -u appmotel` Prefix

When running Claude Code as the `apps` user, **ALL** appmotel commands must be prefixed with `sudo -u appmotel`:

```bash
# ✅ CORRECT: Run as appmotel user
sudo -u appmotel appmo list
sudo -u appmotel appmo add myapp https://github.com/user/repo main
sudo -u appmotel appmo status myapp
sudo -u appmotel appmo logs myapp 100

# ❌ WRONG: Running as apps user will fail
appmo list  # Command not found or permission denied
```

### Traefik Management (Two-Level Sudo)

Traefik requires **two levels of sudo** because:
1. First `sudo -u appmotel` switches to appmotel user
2. Second `sudo` allows appmotel to manage the system service

```bash
# ✅ CORRECT: Traefik system service management
sudo -u appmotel sudo systemctl status traefik-appmotel
sudo -u appmotel sudo systemctl restart traefik-appmotel
sudo -u appmotel sudo journalctl -u traefik-appmotel -f

# ❌ WRONG: Missing double sudo
sudo systemctl status traefik-appmotel  # Wrong user context
sudo -u appmotel systemctl status traefik-appmotel  # Permission denied
```

### App Service Management (Single Sudo)

App services are **user services** (not system services), so they only need single sudo:

```bash
# ✅ CORRECT: App user service management
sudo -u appmotel systemctl --user status appmotel-myapp
sudo -u appmotel systemctl --user restart appmotel-myapp
sudo -u appmotel journalctl --user -u appmotel-myapp -f

# ❌ WRONG: Using system service commands
sudo systemctl status appmotel-myapp  # Won't find user service
```

## Common Operations

### Deploying Applications

```bash
# Deploy from GitHub repository
sudo -u appmotel appmo add myapp https://github.com/username/repo main

# Deploy from subfolder using GitHub tree URL
sudo -u appmotel appmo add myapp https://github.com/username/repo/tree/main/apps/myapp

# Deploy using short form (auto-expands to full GitHub URL)
sudo -u appmotel appmo add myapp username/repo main
```

### Managing Applications

```bash
# List all apps
sudo -u appmotel appmo list

# Check app status
sudo -u appmotel appmo status myapp

# View logs (last 100 lines)
sudo -u appmotel appmo logs myapp 100

# Restart app
sudo -u appmotel appmo restart myapp

# Update app (pull latest from git)
sudo -u appmotel appmo update myapp

# Edit app environment variables
sudo -u appmotel appmo env myapp

# Execute command in app environment
sudo -u appmotel appmo exec myapp python manage.py migrate

# Remove app (backs up .env)
sudo -u appmotel appmo remove myapp
```

### Backup and Restore

```bash
# Create backup
sudo -u appmotel appmo backup myapp

# List available backups
sudo -u appmotel appmo backups myapp

# Restore from specific backup
sudo -u appmotel appmo restore myapp 2025-01-10-120000

# Restore from latest backup
sudo -u appmotel appmo restore myapp
```

### Checking System Status

```bash
# Check all apps
sudo -u appmotel appmo status

# Check Traefik status
sudo -u appmotel sudo systemctl status traefik-appmotel

# Check autopull timer
sudo -u appmotel systemctl --user status appmotel-autopull.timer

# View Traefik logs
sudo -u appmotel sudo journalctl -u traefik-appmotel -f

# View autopull logs
sudo -u appmotel journalctl --user -u appmotel-autopull -f
```

### File Access

The `apps` user can read files in `/home/appmotel` but **cannot write** without using `sudo -u appmotel`:

```bash
# ✅ CORRECT: Reading files
cat /home/appmotel/.config/appmotel/.env
cat /home/appmotel/.config/traefik/traefik.yaml
ls -la /home/appmotel/.config/traefik/dynamic/

# ✅ CORRECT: Writing files (use Write tool or sudo)
# Option 1: Use Claude Code Write tool (automatically handles permissions)
# Option 2: Use sudo -u appmotel
sudo -u appmotel bash -c 'echo "TEST=value" >> /home/appmotel/.config/appmotel/myapp/.env'
```

## Important Patterns for Claude Code

### 1. Avoid Interactive sudo

When using `sudo -u appmotel`, commands run **non-interactively** thanks to `NOPASSWD` in sudoers. Never use commands that require interactive input:

```bash
# ❌ WRONG: Interactive commands
sudo -u appmotel git rebase -i  # Requires interactive editor
sudo -u appmotel git add -i     # Requires interactive input

# ✅ CORRECT: Non-interactive alternatives
sudo -u appmotel git rebase origin/main
sudo -u appmotel git add -A
```

### 2. Reading vs. Writing Files

```bash
# ✅ CORRECT: Read files directly (no sudo needed)
# Use Read tool in Claude Code - it automatically works
cat /home/appmotel/.config/appmotel/.env
grep PORT /home/appmotel/.config/appmotel/myapp/.env

# ✅ CORRECT: Write files using Write tool
# Claude Code's Write tool automatically handles permissions correctly

# ✅ CORRECT: Edit files using Edit tool
# Claude Code's Edit tool automatically handles permissions correctly

# ❌ WRONG: Direct writes will fail
echo "TEST=value" >> /home/appmotel/.config/appmotel/.env  # Permission denied
```

### 3. Multi-Component Apps

Multi-component apps (frontend + backend) create multiple services but appear as one app:

```bash
# Deploy multi-component app
sudo -u appmotel appmo add myapp username/repo main

# Check status (shows all components)
sudo -u appmotel appmo status myapp
# Output:
# myapp (frontend): active
# myapp-backend: active

# All commands affect ALL components
sudo -u appmotel appmo restart myapp  # Restarts both frontend and backend
sudo -u appmotel appmo stop myapp     # Stops both services
sudo -u appmotel appmo logs myapp     # Shows all component logs
```

### 4. Handling .env Files

Each app's `.env` file lives in `~/.config/appmotel/<app>/.env` (NOT in the repo):

```bash
# Edit app environment (opens in $EDITOR)
sudo -u appmotel appmo env myapp

# View app environment
cat /home/appmotel/.config/appmotel/myapp/.env

# Modify using Edit tool (preferred in Claude Code)
# Or use bash:
sudo -u appmotel bash -c 'echo "NEW_VAR=value" >> /home/appmotel/.config/appmotel/myapp/.env'

# After .env changes, restart app
sudo -u appmotel appmo restart myapp
```

## Testing and Development

### Clean Install Testing

```bash
# Reset appmotel home (clean slate)
sudo -u appmotel bash bin/reset-home.sh --force

# Run system-level installation (as root)
sudo bash install.sh

# Run user-level installation (as appmotel)
sudo -u appmotel bash install.sh
```

### Syntax Validation

```bash
# Validate bash scripts before committing
bash -n install.sh
bash -n bin/appmo

# Run from any location
bash -n /home/appmotel/install.sh
```

### Test App Deployment

```bash
# Deploy test Flask app
sudo -u appmotel appmo add flask-test https://github.com/dirkpetersen/appmotel main examples/flask-hello

# Check status
sudo -u appmotel appmo status flask-test

# View logs
sudo -u appmotel appmo logs flask-test 50

# Test HTTP access (should redirect to HTTPS)
curl -I http://flask-test.apps.yourdomain.edu

# Test HTTPS access
curl https://flask-test.apps.yourdomain.edu

# Remove when done testing
sudo -u appmotel appmo remove flask-test
```

## Troubleshooting

### App Not Starting

```bash
# Check service status
sudo -u appmotel systemctl --user status appmotel-myapp

# View full logs
sudo -u appmotel journalctl --user -u appmotel-myapp -n 100

# Check app configuration
cat /home/appmotel/.config/appmotel/myapp/metadata.conf
cat /home/appmotel/.config/appmotel/myapp/.env

# Check if port is already in use
ss -tlnp | grep <port>

# Restart app
sudo -u appmotel appmo restart myapp
```

### Traefik 404 Errors

```bash
# Check Traefik dynamic config
ls -la /home/appmotel/.config/traefik/dynamic/
cat /home/appmotel/.config/traefik/dynamic/myapp.yaml

# Check Traefik logs
sudo -u appmotel sudo journalctl -u traefik-appmotel -f

# Verify app is running and accessible
curl http://localhost:<port>

# Restart Traefik (if needed)
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

### Permission Issues

```bash
# Check file ownership
ls -la /home/appmotel/.config/appmotel/myapp/
ls -la /home/appmotel/.local/share/appmotel/myapp/

# Check if running as correct user
ps aux | grep appmotel

# Verify sudoers configuration
sudo cat /etc/sudoers.d/appmotel

# Test sudo access
sudo -u appmotel whoami  # Should output: appmotel
sudo -u appmotel sudo systemctl status traefik-appmotel  # Should work
```

### Git Issues

```bash
# Check git remote
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git remote -v'

# Check current branch
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git branch'

# Check for uncommitted changes
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git status'

# Force pull (discard local changes)
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git fetch && git reset --hard origin/main'
```

## Security Best Practices

### 1. Never Run as Root

The `apps` user should **never** run commands directly as root. The three-tier model provides all necessary access:

```bash
# ❌ WRONG: Never needed
sudo systemctl restart appmotel-myapp  # Won't work anyway (user service)

# ✅ CORRECT: Use proper delegation
sudo -u appmotel systemctl --user restart appmotel-myapp
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

### 2. Protect Secrets

Never commit secrets or credentials to the repository:

```bash
# ✅ CORRECT: Secrets in .env files (not in repo)
cat /home/appmotel/.config/appmotel/myapp/.env
# DATABASE_PASSWORD=secret123
# API_KEY=abc123xyz

# ❌ WRONG: Secrets in code
# api_key = "abc123xyz"  # Never do this
```

### 3. Validate Scripts Before Execution

Always validate bash scripts before running them:

```bash
# Syntax check
bash -n script.sh

# Review script content
cat script.sh

# Run with -x for debugging (shows each command)
sudo -u appmotel bash -x script.sh
```

### 4. Use Backups Before Major Changes

```bash
# Always backup before major changes
sudo -u appmotel appmo backup myapp

# Make changes
sudo -u appmotel appmo update myapp

# If something breaks, restore
sudo -u appmotel appmo restore myapp
```

## 24x7 Automation Considerations

### Autopull Timer

Appmotel automatically checks for git updates every 2 minutes:

```bash
# Check timer status
sudo -u appmotel systemctl --user status appmotel-autopull.timer

# View recent autopull activity
sudo -u appmotel journalctl --user -u appmotel-autopull -n 50

# Manually trigger autopull check
sudo -u appmotel systemctl --user start appmotel-autopull.service
```

### Monitoring

For 24x7 operation, monitor:

1. **App services:** `sudo -u appmotel appmo status`
2. **Traefik service:** `sudo -u appmotel sudo systemctl status traefik-appmotel`
3. **Autopull timer:** `sudo -u appmotel systemctl --user status appmotel-autopull.timer`
4. **Disk space:** `df -h /home/appmotel`
5. **Logs:** Check for errors in journalctl

### Automated Recovery

If a service stops, restart it:

```bash
# Check and restart app if not active
if ! sudo -u appmotel systemctl --user is-active appmotel-myapp >/dev/null 2>&1; then
  sudo -u appmotel systemctl --user restart appmotel-myapp
fi

# Check and restart Traefik if not active
if ! sudo -u appmotel sudo systemctl is-active traefik-appmotel >/dev/null 2>&1; then
  sudo -u appmotel sudo systemctl restart traefik-appmotel
fi
```

### Log Rotation

Systemd automatically rotates logs, but monitor disk usage:

```bash
# Check journal size
sudo -u appmotel journalctl --disk-usage

# View journal configuration
cat /etc/systemd/journald.conf
```

## Quick Reference

### Most Common Commands

```bash
# Deploy app
sudo -u appmotel appmo add <name> <url> [branch]

# List apps
sudo -u appmotel appmo list

# Check status
sudo -u appmotel appmo status [app]

# View logs
sudo -u appmotel appmo logs <app> [lines]

# Restart app
sudo -u appmotel appmo restart <app>

# Update app
sudo -u appmotel appmo update <app>

# Remove app
sudo -u appmotel appmo remove <app>

# Check Traefik
sudo -u appmotel sudo systemctl status traefik-appmotel
```

### File Locations

```
/home/appmotel/
├── .config/
│   ├── appmotel/
│   │   ├── .env                    # Main config
│   │   └── <app>/                  # Per-app config
│   │       ├── metadata.conf       # App metadata
│   │       └── .env                # App environment
│   ├── traefik/
│   │   ├── traefik.yaml            # Static config
│   │   └── dynamic/<app>.yaml      # Per-app routing
│   └── systemd/user/               # User services
│       └── appmotel-<app>.service
├── .local/
│   ├── bin/
│   │   ├── appmo                   # CLI tool
│   │   └── traefik                 # Traefik binary
│   └── share/
│       ├── appmotel/<app>/repo/    # App git repos
│       └── appmotel-backups/       # Backups
```

## Summary

When running Claude Code as the `apps` user:

1. ✅ **Always prefix with `sudo -u appmotel`** for all appmotel commands
2. ✅ **Use double sudo** for Traefik: `sudo -u appmotel sudo systemctl`
3. ✅ **Use single sudo** for apps: `sudo -u appmotel systemctl --user`
4. ✅ **Read files directly** (no special permissions needed)
5. ✅ **Use Write/Edit tools** for file modifications (handles permissions automatically)
6. ✅ **Avoid interactive commands** (use non-interactive alternatives)
7. ✅ **Always validate bash scripts** with `bash -n` before running
8. ✅ **Use backups** before major changes

This permission model enables secure, automated management without requiring root access.
