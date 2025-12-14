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

# Note: appmotel user does NOT need sudo access for Traefik config
# Traefik automatically reloads dynamic configuration changes
```

### Line-by-Line Explanation

| Line | Purpose |
|------|---------|
| `apps ALL=(ALL) NOPASSWD: /bin/su - appmotel` | Allows interactive shell sessions as appmotel |
| `apps ALL=(appmotel) NOPASSWD: ALL` | Allows non-interactive command execution as appmotel |
| `appmotel ALL=(ALL) NOPASSWD: /bin/systemctl ...` | Allows appmotel to manage Traefik system service |

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
Read access to TLS certificates:
```bash
# Certificates at /etc/letsencrypt/live/<domain>/
# appmotel needs read access to:
#   - fullchain.pem
#   - privkey.pem

# Option A: Add appmotel to a group with access
sudo usermod -aG ssl-cert appmotel

# Option B: Use ACLs
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
