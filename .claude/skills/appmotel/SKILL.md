---
name: appmotel
description: Managing Appmotel PaaS from a developer account (apps user) for 24x7 automation with Claude Code
---

# Appmotel Management for Developer Accounts

## Overview

A developer account (e.g., `apps` user) manages Appmotel via a three-tier permission model that allows secure, delegated control without root access.

## Permission Model

```
┌─────────────────────────────────────────────────────────────────┐
│  TIER 1: Operator User (apps)                                   │
│  - Runs Claude Code or other automation tools                   │
│  - Has full control over the appmotel user                      │
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
└─────────────────────────────────────────────────────────────────┘
```

## Sudoers Configuration

**Location:** `/etc/sudoers.d/appmotel`

```bash
# TIER 1 -> TIER 2: Allow operator user to control appmotel user
apps ALL=(ALL) NOPASSWD: /bin/su - appmotel
apps ALL=(appmotel) NOPASSWD: ALL

# TIER 2 -> TIER 3: Allow appmotel to manage ONLY the Traefik system service
appmotel ALL=(ALL) NOPASSWD: /bin/systemctl restart traefik-appmotel, /bin/systemctl stop traefik-appmotel, /bin/systemctl start traefik-appmotel, /bin/systemctl status traefik-appmotel
appmotel ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u traefik-appmotel, /usr/bin/journalctl -u traefik-appmotel *
```

## Command Execution Patterns

### CRITICAL: Always Use `sudo -u appmotel` Prefix

```bash
# ✅ CORRECT
sudo -u appmotel appmo list
sudo -u appmotel appmo add myapp https://github.com/user/repo main
sudo -u appmotel appmo status myapp

# ❌ WRONG: Running as apps user will fail
appmo list
```

### Traefik Management (Two-Level Sudo)

```bash
# ✅ CORRECT: Traefik system service
sudo -u appmotel sudo systemctl status traefik-appmotel
sudo -u appmotel sudo systemctl restart traefik-appmotel
sudo -u appmotel sudo journalctl -u traefik-appmotel -f

# ❌ WRONG
sudo systemctl status traefik-appmotel       # Wrong user context
sudo -u appmotel systemctl status traefik-appmotel  # Permission denied
```

### App Service Management (Single Sudo)

```bash
# ✅ CORRECT: App user services
sudo -u appmotel systemctl --user status appmotel-myapp
sudo -u appmotel systemctl --user restart appmotel-myapp
sudo -u appmotel journalctl --user -u appmotel-myapp -f
```

## Common Operations

```bash
# Deploy
sudo -u appmotel appmo add myapp https://github.com/username/repo main
sudo -u appmotel appmo add myapp https://github.com/username/repo/tree/main/apps/myapp
sudo -u appmotel appmo add myapp username/repo main  # short form

# Manage
sudo -u appmotel appmo list
sudo -u appmotel appmo status [myapp]
sudo -u appmotel appmo logs myapp 100
sudo -u appmotel appmo restart myapp
sudo -u appmotel appmo update myapp
sudo -u appmotel appmo env myapp
sudo -u appmotel appmo exec myapp python manage.py migrate
sudo -u appmotel appmo remove myapp

# Backup/restore
sudo -u appmotel appmo backup myapp
sudo -u appmotel appmo backups myapp
sudo -u appmotel appmo restore myapp [2025-01-10-120000]

# Self-update CLI, Traefik binary, and configs
sudo -u appmotel appmo self-update
```

## Key Patterns for Claude Code

**Non-interactive:** Commands run non-interactively via NOPASSWD. Never use `git rebase -i`, `git add -i`, etc.

**Reading files:** Read directly — `cat /home/appmotel/.config/appmotel/myapp/.env` (no sudo needed).

**Writing files:** Use Claude Code's Write/Edit tools (handle permissions automatically), or:
```bash
sudo -u appmotel bash -c 'echo "NEW_VAR=value" >> /home/appmotel/.config/appmotel/myapp/.env'
```

**Multi-component apps:** `appmo restart myapp` restarts all components (frontend + backend).

**After .env changes:** Always restart the app: `sudo -u appmotel appmo restart myapp`

## Quick Reference

```bash
# System status
sudo -u appmotel appmo status
sudo -u appmotel sudo systemctl status traefik-appmotel
sudo -u appmotel systemctl --user status appmotel-autopull.timer

# File locations
/home/appmotel/.config/appmotel/.env          # Main config
/home/appmotel/.config/appmotel/<app>/.env    # App environment
/home/appmotel/.config/traefik/traefik.yaml   # Traefik static config
/home/appmotel/.config/traefik/dynamic/       # Per-app routing YAML
/home/appmotel/.local/share/appmotel/<app>/repo/  # App git repos
```

## Summary

1. ✅ Always prefix with `sudo -u appmotel`
2. ✅ Double sudo for Traefik: `sudo -u appmotel sudo systemctl`
3. ✅ Single sudo for apps: `sudo -u appmotel systemctl --user`
4. ✅ Read files directly, use Write/Edit tools for modifications
5. ✅ Avoid interactive commands

**See also:**
- [troubleshooting.md](troubleshooting.md) — App not starting, Traefik 404s, permission/git issues
- [security.md](security.md) — Security best practices, backup workflows
- [automation.md](automation.md) — 24x7 autopull, monitoring, log rotation
- [testing.md](testing.md) — Clean install testing, syntax validation, test apps
