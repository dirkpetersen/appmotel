# Development Environment Setup

This document explains the execution model and permission structure for Appmotel.

## Execution Model Overview

Appmotel uses a **three-tier permission delegation model**:

```
┌─────────────────────────────────────────────────────────────────┐
│  TIER 1: Operator User (e.g., "apps")                           │
│  - Runs Claude Code or other automation tools                   │
│  - Has full control over the appmotel user                      │
│  - Cannot directly run root commands                            │
└───────────────────────┬─────────────────────────────────────────┘
                        │ sudo -u appmotel
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 2: Service User ("appmotel")                              │
│  - Owns all Appmotel files and services                         │
│  - Manages user-level systemd services (no root needed)         │
│  - Has LIMITED sudo access for specific systemctl commands      │
└───────────────────────┬─────────────────────────────────────────┘
                        │ sudo /bin/systemctl (limited)
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  TIER 3: Root (strictly limited)                                │
│  - Only for Traefik service management                          │
│  - No general root access granted                               │
└─────────────────────────────────────────────────────────────────┘
```

## Sudoers Configuration

Location: `/etc/sudoers.d/appmotel`

```bash
# Allow operator user to switch to appmotel interactively
apps ALL=(ALL) NOPASSWD: /bin/su - appmotel

# Allow operator user to run any command as appmotel (for automation)
apps ALL=(appmotel) NOPASSWD: ALL

# Allow appmotel to manage ONLY the Traefik system service
appmotel ALL=(ALL) NOPASSWD: /bin/systemctl restart traefik-appmotel, /bin/systemctl stop traefik-appmotel, /bin/systemctl start traefik-appmotel, /bin/systemctl status traefik-appmotel

# Allow appmotel to view ONLY traefik-appmotel logs with any journalctl options
appmotel ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u traefik-appmotel, /usr/bin/journalctl -u traefik-appmotel *

# Note: appmotel user does NOT need sudo access for Traefik config changes
# Traefik automatically reloads dynamic configuration changes
```

### Line-by-Line Explanation

| Line | Purpose |
|------|---------|
| `apps ALL=(ALL) NOPASSWD: /bin/su - appmotel` | Allows operator user to switch to appmotel interactively |
| `apps ALL=(appmotel) NOPASSWD: ALL` | Allows operator user to run any command as appmotel (for automation) |
| `appmotel ALL=(ALL) NOPASSWD: /bin/systemctl ...` | Allows appmotel to manage Traefik system service |
| `appmotel ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u traefik-appmotel*` | Allows appmotel to view full Traefik logs for debugging |

## Correct Command Execution

### Managing Traefik Service

The Traefik service runs as a **system-level service** (not user-level) because it needs to bind to privileged ports 80 and 443.

**Correct way to manage Traefik:**
```bash
# From operator user (apps), execute as appmotel, then use sudo
sudo -u appmotel sudo /bin/systemctl start traefik-appmotel
sudo -u appmotel sudo /bin/systemctl stop traefik-appmotel
sudo -u appmotel sudo /bin/systemctl restart traefik-appmotel
sudo -u appmotel sudo /bin/systemctl status traefik-appmotel
```

**Why this pattern?**
1. `sudo -u appmotel` - Switch to appmotel user
2. `sudo /bin/systemctl` - appmotel uses its sudo permission to run systemctl as root

**INCORRECT (will fail):**
```bash
# This fails because "apps" user doesn't have direct systemctl sudo access
sudo systemctl start traefik-appmotel
```

### Viewing Traefik Logs

The `appmotel` user has full access to Traefik logs for debugging:

```bash
# View recent logs
sudo -u appmotel sudo /usr/bin/journalctl -u traefik-appmotel -n 50

# View logs since a time
sudo -u appmotel sudo /usr/bin/journalctl -u traefik-appmotel --since "1 hour ago"

# Follow logs in real-time
sudo -u appmotel sudo /usr/bin/journalctl -u traefik-appmotel -f

# View logs without pager
sudo -u appmotel sudo /usr/bin/journalctl -u traefik-appmotel --no-pager
```

**Note:** The appmotel user can ONLY view traefik-appmotel logs. Attempting to view other service logs will be denied by sudoers.

### Managing Application Services

Application services run as **user-level systemd services** under the appmotel user.

```bash
# These commands don't need root - they use systemctl --user
sudo -u appmotel systemctl --user start appmotel-myapp
sudo -u appmotel systemctl --user stop appmotel-myapp
sudo -u appmotel systemctl --user status appmotel-myapp

# Or use the appmo CLI (preferred)
sudo -u appmotel appmo start myapp
sudo -u appmotel appmo stop myapp
sudo -u appmotel appmo status myapp
```

### Running General Commands as appmotel

```bash
sudo -u appmotel whoami                           # Returns: appmotel
sudo -u appmotel bash /path/to/install.sh         # Run installation
sudo -u appmotel appmo list                       # Use appmo CLI
sudo -u appmotel appmo add myapp https://... main # Add an app
```

## Required Permissions for appmotel User

The appmotel user requires the following permissions:

### 1. Systemd Linger (Required)
Allows user services to run without an active login session:
```bash
sudo loginctl enable-linger appmotel
```

### 2. Let's Encrypt Certificate Access (Required for HTTPS)
Secure read access to TLS certificates using group-based permissions.

**Background: The `ssl-cert` Convention**

This follows the Debian/Ubuntu convention for secure certificate access:
- **Debian/Ubuntu**: The `ssl-cert` package provides the `ssl-cert` group and `/etc/ssl/private` directory (mode 710)
- **RHEL/CentOS/Fedora**: No such package exists; the group must be created manually
- **Purpose**: Allows non-root services to read SSL/TLS private keys without making them world-readable

**The Secure Approach (Recommended - Implemented by install.sh):**
```bash
# 1. Install ssl-cert package (Debian/Ubuntu only)
# On Debian/Ubuntu:
sudo apt-get install -y ssl-cert

# On RHEL/CentOS/Fedora, manually create the group:
sudo groupadd ssl-cert

# 2. Add appmotel user to ssl-cert group
sudo usermod -aG ssl-cert appmotel

# 3. Set group ownership
sudo chgrp -R ssl-cert /etc/letsencrypt/archive
sudo chgrp -R ssl-cert /etc/letsencrypt/live

# 4. Set secure permissions
# Directories: 750 (owner full, group read/execute, world none)
sudo chmod 750 /etc/letsencrypt/{archive,live}
sudo chmod 750 /etc/letsencrypt/archive/*
sudo chmod 750 /etc/letsencrypt/live/*

# 5. Private keys: 640 (owner read/write, group read, world none)
sudo find /etc/letsencrypt/archive -name "privkey*.pem" -exec chmod 640 {} \;

# 6. Public certs: 644 (standard for public certificates)
sudo find /etc/letsencrypt/archive -name "*.pem" ! -name "privkey*.pem" -exec chmod 644 {} \;
```

**Why This Approach:**
- **Security**: Private keys are NOT readable by all users (prevents unauthorized access)
- **Access Control**: Only members of `ssl-cert` group can access certificates
- **Standard Convention**:
  - Debian/Ubuntu systems use the `ssl-cert` package which provides this group and `/etc/ssl/private` (mode 710)
  - RHEL/CentOS/Fedora don't have this package but the convention still applies
- **Manageable**: Group membership can be managed centrally
- **Clean**: Uses standard Unix permissions, no ACLs needed
- **Portable**: Works across different Linux distributions
- **Much more secure** than world-readable files (744) or overly permissive ACLs

**Alternative (Not Recommended):**
```bash
# Using ACLs - works but less standard
sudo setfacl -R -m u:appmotel:rx /etc/letsencrypt/live/
sudo setfacl -R -m u:appmotel:rx /etc/letsencrypt/archive/
```

### 3. CAP_NET_BIND_SERVICE (Handled by systemd)
Traefik needs to bind ports 80 and 443. This is granted via the systemd service file:
```ini
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateUsers=no
```

**Note:** Do NOT set file capabilities on the Traefik binary (`setcap`). Use only systemd's `AmbientCapabilities`.

### 4. Home Directory Structure
The appmotel user needs these directories:
```
/home/appmotel/
├── .config/
│   ├── appmotel/apps/          # App metadata
│   ├── systemd/user/           # User services
│   └── traefik/
│       ├── traefik.yaml        # Static config
│       └── dynamic/            # Dynamic configs (auto-watched)
├── .local/
│   ├── bin/                    # traefik, appmo binaries
│   └── share/
│       ├── appmotel/           # App repositories
│       └── traefik/acme.json   # ACME certificates (mode 600)
└── .bashrc                     # PATH includes ~/.local/bin
```

## Security Considerations

### What appmotel CAN do:
- Manage its own user-level systemd services
- Start/stop/restart the Traefik system service (limited sudo)
- Read Let's Encrypt certificates
- Bind to privileged ports via Traefik (systemd capability)

### What appmotel CANNOT do:
- Run arbitrary commands as root
- Install system packages
- Modify system files
- Access other users' home directories

### Production vs Development

For production, you may want to restrict the operator user's access:

```bash
# Production-only sudoers (more restrictive)
apps ALL=(ALL) NOPASSWD: /bin/su - appmotel
# Remove: apps ALL=(appmotel) NOPASSWD: ALL
```

This requires interactive shell for all appmotel operations but is more secure.

## Testing the Configuration

After configuring sudoers, verify:

```bash
# Test operator → appmotel delegation
sudo -u appmotel whoami
# Expected: appmotel

# Test appmotel → root (limited) delegation
sudo -u appmotel sudo /bin/systemctl status traefik-appmotel
# Expected: Shows Traefik service status

# Test that appmotel cannot run arbitrary root commands
sudo -u appmotel sudo whoami
# Expected: FAILS (not in allowed commands)

# Test user-level service management
sudo -u appmotel systemctl --user status
# Expected: Shows user services
```

## Installation Flow

**Step 1: System-level setup (requires actual root):**
```bash
sudo bash install.sh
```

This creates:
- The appmotel user
- `/etc/systemd/system/traefik-appmotel.service`
- `/etc/sudoers.d/appmotel`
- Enables systemd linger

**Step 2: User-level setup:**
```bash
sudo -u appmotel bash install.sh
```

This installs:
- Traefik binary
- Configuration files
- appmo CLI tool
