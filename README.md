# Appmotel

> A no-frills PaaS (Platform as a Service) system using ubiquitous components like systemd, GitHub, and Traefik.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.4%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Traefik](https://img.shields.io/badge/traefik-3.0%2B-blue.svg)](https://traefik.io/)

## Overview

Appmotel is a minimalist PaaS that makes deploying and managing web applications as simple as a single command. Deploy Python and Node.js applications with automatic HTTPS, health checks, rate limiting, and seamless updates—all managed through systemd user services and Traefik reverse proxy.

**Key Philosophy:**
- Use battle-tested, ubiquitous tools (systemd, Traefik, GitHub)
- No complex orchestration or containers required
- Simple, transparent operation
- Easily auditable Bash scripts

## Features

### 🚀 Core Features
- **One-Command Deploy**: `appmo add myapp https://github.com/user/repo main`
- **Automatic HTTPS**: Let's Encrypt integration via Traefik with wildcard certificate support
- **Zero-Downtime Updates**: Automatic backup and rollback on failure
- **Multi-Process Apps**: Procfile support for apps requiring multiple processes
- **Auto-Deploy**: Automatic git polling and deployment every 2 minutes

### 🛡️ Security & Reliability
- **Rate Limiting**: Configurable request rate limiting per app (default: 100 req/sec)
- **Health Checks**: Automatic health monitoring with 30-second intervals
- **Resource Limits**: CPU and memory limits per app (default: 512M memory, 100% CPU)
- **Automatic Backups**: Every update creates a timestamped backup
- **SSL/TLS**: Automatic HTTPS with Let's Encrypt or existing wildcard certificates

### 🎯 Developer Experience
- **Simple CLI**: Intuitive `appmo` command with shell completion
- **Environment Variables**: `.env` file support with proper quote handling
- **Real-Time Logs**: `appmo logs <app>` shows live application logs
- **Exec Commands**: Run commands in app environment with `appmo exec`
- **Backup/Restore**: One-command backup and restore functionality

### 🔧 Supported Platforms
- **Python**: Automatic virtual environment setup with `requirements.txt`
- **Node.js**: Automatic dependency installation with `package.json`
- **Multi-Process**: Procfile support (web, worker, etc.)

## Quick Start

### Prerequisites
- Ubuntu 24.04 LTS (or similar Linux distribution)
- Root access for initial setup
- Domain name with DNS configured (see [DNS Configuration](#dns-configuration) below)

### Installation

**Step 1: System-level setup (as root)**

Run this once to create the `appmotel` user, configure systemd services, and set up permissions:

```bash
sudo bash install.sh
```

**Step 2: User-level setup (as appmotel user)**

Switch to the `appmotel` user and run the installation to download Traefik, install the CLI tool, and configure everything:

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

This installs everything under `/home/appmotel` and starts the necessary services.

### Deploy Your First App

```bash
# Add and deploy an app
sudo -u appmotel appmo add myapp https://github.com/username/myrepo main

# Check status
sudo -u appmotel appmo status myapp

# View logs
sudo -u appmotel appmo logs myapp

# Your app is now live at: https://myapp.apps.yourdomain.edu
```

## Usage

### CLI Commands

```bash
# Application Management
appmo add <app-name> <github-url> <branch>   # Deploy a new app
appmo remove <app-name>                       # Remove an app
appmo list                                    # List all apps
appmo status [app-name]                       # Show app status

# App Control
appmo start <app-name>                        # Start an app
appmo stop <app-name>                         # Stop an app
appmo restart <app-name>                      # Restart an app
appmo update <app-name>                       # Update app (auto-backup & rollback)

# Monitoring & Debugging
appmo logs <app-name> [lines]                 # View application logs
appmo exec <app-name> <command>               # Run command in app environment

# Backup & Restore
appmo backup <app-name>                       # Create backup
appmo restore <app-name> [backup-id]          # Restore from backup
appmo backups <app-name>                      # List available backups
```

### Application Requirements

Each app repository must contain:

**1. `.env` file** - Environment variables and configuration
```bash
PORT=8000
APP_NAME="My Application"

# Optional: Resource limits
MEMORY_LIMIT=512M
CPU_QUOTA=100%

# Optional: Rate limiting
RATE_LIMIT_AVG=100
RATE_LIMIT_BURST=50
# DISABLE_RATE_LIMIT=true

# Optional: Health checks
HEALTH_CHECK_PATH=/health
```

**2. `install.sh`** - Installation/setup script (run on deploy and update)
```bash
#!/usr/bin/env bash
echo "Installing dependencies..."
# Your installation commands here
```

**3. Application entry point** - One of:
- Python: `app.py` or `requirements.txt`
- Node.js: `package.json` with `start` script
- Procfile: For multi-process apps

### Procfile Support

For applications requiring multiple processes:

**Procfile:**
```
web: python app.py
worker: celery -A tasks worker
scheduler: python scheduler.py
```

Each process gets its own systemd service:
- `appmotel-myapp-web`
- `appmotel-myapp-worker`
- `appmotel-myapp-scheduler`

The `web` process receives the main port and is accessible via HTTPS.

## Configuration

### System Configuration

Configure Appmotel via `.env` file in the project root:

```bash
# Base domain for applications
BASE_DOMAIN="apps.yourdomain.edu"

# Let's Encrypt settings
USE_LETSENCRYPT="yes"
LETSENCRYPT_EMAIL="admin@yourdomain.edu"
LETSENCRYPT_MODE="http"  # or "dns" for DNS-01 challenge

# AWS credentials (only for DNS-01 mode with Route53)
AWS_ACCESS_KEY_ID="your-key"
AWS_SECRET_ACCESS_KEY="your-secret"
AWS_REGION="us-west-2"
```

### Per-App Configuration

Apps can override defaults in their `.env` file:

```bash
# Resource Limits
MEMORY_LIMIT=1G          # Max memory (default: 512M)
CPU_QUOTA=200%           # CPU quota (default: 100%)

# Rate Limiting
RATE_LIMIT_AVG=200       # Requests/sec average (default: 100)
RATE_LIMIT_BURST=100     # Burst requests (default: 50)
DISABLE_RATE_LIMIT=true  # Disable rate limiting

# Health Checks
HEALTH_CHECK_PATH=/api/health  # Health endpoint (default: /health)
```

## DNS Configuration

Appmotel requires DNS to route traffic from your domain (e.g., `apps.yourdomain.edu`) to your deployed applications. Each app gets a unique subdomain like `myapp.apps.yourdomain.edu`.

### Configuration Options

Choose the DNS configuration method that best fits your environment:

#### Option 1: Subdomain Delegation (Best)

**When to use:**
- You have full control over your parent domain
- You want complete DNS autonomy for app subdomains
- You're willing to run a DNS server on this machine

**Setup:**
1. Run a DNS server on your Appmotel host (e.g., CoreDNS, PowerDNS, BIND)
2. Configure the server to handle queries for `*.apps.yourdomain.edu`
3. In your parent domain's DNS, add NS records:

```dns
apps.yourdomain.edu.  IN  NS  ns1.yourdomain.edu.
ns1.yourdomain.edu.   IN  A   203.0.113.10
```

**Advantages:**
- ✅ New apps automatically work without DNS updates
- ✅ Complete control over subdomain DNS
- ✅ Can implement custom DNS records (TXT, SRV, etc.)
- ✅ Best for large deployments with many apps

**Disadvantages:**
- ⚠️ Requires running and maintaining a DNS server
- ⚠️ More complex setup

#### Option 2: Wildcard A Record (Recommended)

**When to use:**
- You control the DNS zone for your domain
- Your DNS provider supports wildcard records
- You want a simple, maintenance-free solution

**Setup:**
Add a wildcard A record in your DNS zone:

```dns
*.apps.yourdomain.edu.  IN  A  203.0.113.10
```

This routes ALL subdomains under `apps.yourdomain.edu` to your server.

**Advantages:**
- ✅ New apps automatically work without DNS updates
- ✅ Simple to configure (single DNS record)
- ✅ No additional software required
- ✅ Best for most use cases

**Disadvantages:**
- ⚠️ Not all DNS providers support wildcards
- ⚠️ All subdomains point to same IP (not ideal for split deployments)

#### Option 3: Individual CNAME or A Records (Fallback)

**When to use:**
- Your DNS provider doesn't support wildcard records
- You need explicit control over each subdomain
- You have a small number of apps

**Setup:**
For each app, add a DNS record:

**Option 3a: A Record (points directly to IP)**
```dns
myapp.apps.yourdomain.edu.  IN  A  203.0.113.10
```

**Option 3b: CNAME Record (points to another hostname)**
```dns
myapp.apps.yourdomain.edu.  IN  CNAME  server.yourdomain.edu.
```

**Advantages:**
- ✅ Works with all DNS providers
- ✅ Explicit control over each app's DNS
- ✅ Can point different apps to different servers

**Disadvantages:**
- ⚠️ Requires manual DNS update for EVERY new app
- ⚠️ More maintenance overhead
- ⚠️ DNS propagation delay for new apps

### DNS Configuration Workflow

When you add a new app, Appmotel automatically displays DNS configuration guidance:

```bash
$ appmo add myapp https://github.com/username/myrepo main

App 'myapp' added successfully
URL: https://myapp.apps.yourdomain.edu

DNS Configuration Required:

   Configure DNS to route traffic to this app. Choose one option:

   Option 1 (Best): Subdomain delegation via NS records
     Delegate apps.yourdomain.edu to this server's nameserver
     → Enables automatic DNS for all apps without manual updates
     → Requires running a DNS server (e.g., CoreDNS, PowerDNS)

   Option 2 (Recommended): Wildcard A record
     *.apps.yourdomain.edu IN A 203.0.113.10
     → All subdomains automatically route to this server
     → Simplest option if you control the DNS zone

   Option 3 (Fallback): Individual CNAME or A record
     myapp.apps.yourdomain.edu IN A 203.0.113.10
     or
     myapp.apps.yourdomain.edu IN CNAME server.yourdomain.edu.
     → Requires manual DNS update for each new app
     → Use if wildcards are not supported by your DNS provider
```

### Testing DNS Configuration

After configuring DNS, verify it's working:

```bash
# Test DNS resolution
dig myapp.apps.yourdomain.edu

# Test HTTP connectivity (should redirect to HTTPS)
curl -v http://myapp.apps.yourdomain.edu

# Test HTTPS connectivity
curl -v https://myapp.apps.yourdomain.edu

# Check certificate
openssl s_client -connect myapp.apps.yourdomain.edu:443 -servername myapp.apps.yourdomain.edu </dev/null 2>&1 | grep "subject="
```

### Troubleshooting DNS Issues

**DNS not resolving:**
- Check DNS propagation: `dig myapp.apps.yourdomain.edu`
- Wait for DNS TTL to expire (usually 300-3600 seconds)
- Verify your DNS records in your provider's control panel

**Certificate errors:**
- Ensure Let's Encrypt is enabled in `~/.config/appmotel/.env`
- Check Traefik logs: `sudo journalctl -u traefik-appmotel -f`
- Verify DNS is resolving correctly before attempting HTTPS

**404 errors on HTTPS:**
- Verify app is running: `appmo status myapp`
- Check Traefik dynamic config: `cat ~/.config/traefik/dynamic/myapp.yaml`
- Review app logs: `appmo logs myapp`

## Architecture

### Directory Structure

```
/home/appmotel/
├── .config/
│   ├── appmotel/apps/          # App metadata
│   │   └── <app-name>/
│   │       └── metadata.env
│   ├── traefik/
│   │   ├── traefik.yaml        # Static configuration
│   │   └── dynamic/            # Per-app routing configs
│   │       └── <app-name>.yaml
│   └── systemd/user/           # App services
│       └── appmotel-<app-name>.service
├── .local/
│   ├── bin/
│   │   ├── appmo               # CLI tool
│   │   └── traefik             # Traefik binary
│   └── share/
│       ├── appmotel/           # App repositories
│       │   └── <app-name>/repo/
│       └── appmotel-backups/   # Backups
│           └── <app-name>/
└── .bashrc
```

### System Architecture

```
┌─────────────────────────────────────────────┐
│              Internet (Port 80/443)         │
└─────────────────────┬───────────────────────┘
                      │
                      ▼
         ┌────────────────────────┐
         │   Traefik Proxy        │
         │   (System Service)     │
         │   - HTTPS/SSL          │
         │   - Rate Limiting      │
         │   - Health Checks      │
         └────────┬───────────────┘
                  │
      ┌───────────┼───────────┐
      ▼           ▼           ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│  App 1   │ │  App 2   │ │  App 3   │
│ (User    │ │ (User    │ │ (User    │
│ Service) │ │ Service) │ │ Service) │
│ :8000    │ │ :8001    │ │ :8002    │
└──────────┘ └──────────┘ └──────────┘
```

### Systemd Services

**System-level** (managed by system admin):
- `traefik-appmotel.service` - Runs as `appmotel` user with `CAP_NET_BIND_SERVICE`

**User-level** (managed by `appmotel` user):
- `appmotel-<app-name>.service` - Individual app services
- `appmotel-<app-name>-<process>.service` - Multi-process app services

## Automatic Deployment (Autopull)

Appmotel automatically checks all deployed apps for updates every 2 minutes using a systemd timer. When updates are detected, apps are automatically redeployed.

### How It Works

1. **Systemd Timer**: `appmotel-autopull.timer` runs every 2 minutes
2. **Git Polling**: The `appmo-autopull` script checks each app for updates
3. **Automatic Deploy**: When changes are found, `appmo update <app>` runs automatically
4. **Rollback on Failure**: If deployment fails, the previous version is automatically restored

### Monitoring Autopull

```bash
# Check timer status
systemctl --user status appmotel-autopull.timer

# View autopull logs
journalctl --user -u appmotel-autopull -f

# Manually trigger a check
systemctl --user start appmotel-autopull.service
```

### Advantages

- **Works on private networks** - Only needs outbound git access
- **No webhooks required** - No public endpoints or firewall rules needed
- **Simple and reliable** - Pure bash with systemd
- **Easy to debug** - Standard systemd logging

### Optional: GitHub Actions (Advanced)

For more complex workflows (build steps, tests, multi-environment), you can use the GitHub Actions template in `templates/github-workflow.yml`. This requires SSH access to your server.

## Development

### Running Locally

Switch to the `appmotel` user for testing:
```bash
sudo su - appmotel
```

Clean home directory for fresh install testing:
```bash
# Reset appmotel home directory (executes as appmotel user)
sudo -u appmotel bash reset-home.sh --force

# Run fresh installation
bash install.sh
```

### Bash Coding Standards

This project follows strict Bash 4.4+ standards:
- Strict mode: `set -o errexit -o nounset -o pipefail`
- Modern features: associative arrays, namerefs, parameter transformation
- Idempotent scripts: safe to run multiple times
- See `reqs/howto-bash.md` for complete guidelines

## Troubleshooting

### Check App Status
```bash
sudo -u appmotel appmo status myapp
```

### View Logs
```bash
sudo -u appmotel appmo logs myapp 100
```

### Manual Service Control
```bash
# As appmotel user
sudo su - appmotel
systemctl --user status appmotel-myapp
systemctl --user restart appmotel-myapp
journalctl --user -u appmotel-myapp -f
```

### Restore from Backup
```bash
# List backups
sudo -u appmotel appmo backups myapp

# Restore specific backup
sudo -u appmotel appmo restore myapp 2025-12-03-120000
```

### Check Traefik
```bash
sudo systemctl status traefik-appmotel
sudo journalctl -u traefik-appmotel -f
```

## Examples

### Python Flask App

**requirements.txt:**
```
flask==3.0.0
```

**app.py:**
```python
from flask import Flask
import os

app = Flask(__name__)

@app.route('/')
def hello():
    return f'Hello from {os.environ.get("APP_NAME", "Flask")}!'

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    app.run(host='0.0.0.0', port=port)
```

**.env:**
```bash
PORT=8000
APP_NAME="My Flask App"
```

**install.sh:**
```bash
#!/usr/bin/env bash
echo "Installing Flask application..."
echo "Installation completed successfully"
```

### Node.js Express App

**package.json:**
```json
{
  "name": "express-hello",
  "version": "1.0.0",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.0"
  }
}
```

**server.js:**
```javascript
const express = require('express');
const app = express();
const port = process.env.PORT || 3000;

app.get('/', (req, res) => {
  res.send(`Hello from ${process.env.APP_NAME || 'Express'}!`);
});

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
```

**.env:**
```bash
PORT=8001
APP_NAME="My Express App"
```

**install.sh:**
```bash
#!/usr/bin/env bash
echo "Installing Express application..."
node --version
npm --version
echo "Installation completed successfully"
```

## Security Considerations

- All apps run as the `appmotel` user (no per-app isolation)
- Traefik runs with minimal privileges using `CAP_NET_BIND_SERVICE`
- Apps are isolated by systemd resource limits
- HTTPS enforced via automatic redirect
- Rate limiting prevents abuse
- Regular backups enable quick recovery

## Performance

- **Port Range**: 10001-59999 automatically assigned
- **Default Limits**: 512M memory, 100% CPU per app
- **Rate Limiting**: 100 req/sec average, 50 burst
- **Health Checks**: 30s interval, 5s timeout

## Contributing

We welcome contributions! Please ensure:
- Follow Bash 4.4+ coding standards (see `reqs/howto-bash.md`)
- All scripts are idempotent
- Test with `bash -n script.sh` before committing
- Update documentation for new features

## License

MIT License - See LICENSE file for details

## Credits

Built with:
- [Traefik](https://traefik.io/) - Modern reverse proxy
- [systemd](https://systemd.io/) - System and service manager
- [Let's Encrypt](https://letsencrypt.org/) - Free SSL/TLS certificates

---

**Made with ❤️ for simple, transparent deployments**
