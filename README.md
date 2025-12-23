# Appmotel

> A no-frills PaaS (Platform as a Service) system using ubiquitous components like systemd, GitHub, and Traefik.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.4%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Traefik](https://img.shields.io/badge/traefik-3.0%2B-blue.svg)](https://traefik.io/)

## Overview

Appmotel is a minimalist PaaS that makes deploying and managing web applications as simple as a single command. Deploy Python, Node.js, and Go applications with automatic HTTPS, health checks, rate limiting, and seamless updates—all managed through systemd user services and Traefik reverse proxy.

<img width="820" height="184" alt="image" src="https://github.com/user-attachments/assets/f1996bd3-bf33-4619-9cb4-25eaace8ad04" />

**Key Philosophy:**
- Use battle-tested, ubiquitous tools (systemd, Traefik, GitHub)
- No complex orchestration or containers required
- Simple, transparent operation
- Easily auditable Bash scripts

## Features

### 🚀 Core Features
- **One-Command Deploy**: `appmo add myapp https://github.com/user/repo main`
- **Subfolder Deploy**: Deploy from repository subfolders using GitHub tree URLs
- **Multi-Component Apps**: Auto-detects and deploys frontend + backend as unified app
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
- **Python**: Virtual environment setup with `requirements.txt` or `pyproject.toml`
- **Node.js**: Auto-builds Next.js static export and Vite+TypeScript apps
- **Go**: Automatic build with `go.mod` (supports `cmd/` directory structure)
- **Multi-Component**: Frontend/backend in `{component}/` or `src/{component}/` directories
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
curl -fsSL "https://raw.githubusercontent.com/dirkpetersen/appmotel/main/install.sh?$(date +%s)" | sudo bash
```

**Step 2: User-level setup (as appmotel user)**

Switch to the `appmotel` user and run the installation to download Traefik, install the CLI tool, and configure everything:

```bash
sudo su - appmotel
curl -fsSL "https://raw.githubusercontent.com/dirkpetersen/appmotel/main/install.sh?$(date +%s)" | bash
```

This installs everything under `/home/appmotel` and starts the necessary services.

> **Alternative:** If you have the repository cloned locally, you can run `sudo bash install.sh` (Step 1) and `bash install.sh` (Step 2) from the repo directory instead.

### Deploy Your First App

```bash
# Add and deploy an app
sudo -u appmotel appmo add myapp https://github.com/username/myrepo main

# Or deploy from a subfolder (GitHub tree URL)
sudo -u appmotel appmo add myapp https://github.com/username/myrepo/tree/main/apps/myapp

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
appmo add <app-name> <url|user/repo> [branch] # Deploy a new app
appmo add <app-name> <github-tree-url>        # Deploy from subfolder
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
- Go: `go.mod` (builds to `bin/` directory, supports `cmd/` structure)
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

#### Option 1: AWS Route53 Automatic DNS (Best for AWS)

**When to use:**
- You're deploying on AWS EC2
- Your domain is hosted in Route53
- You want fully automatic DNS configuration

**Setup:**
Use the `install-aws.sh` script which automatically:
1. Creates an EC2 instance with IAM role for Route53 access
2. Detects your hosted zone
3. Creates wildcard DNS records (`*.apps.yourdomain.edu`)
4. Configures DNS-01 challenge for wildcard SSL certificates

```bash
bash install-aws.sh [instance-type] [region]  # Default: t4g.micro us-west-2
```

**Advantages:**
- ✅ Fully automatic DNS and SSL setup
- ✅ No manual DNS configuration required
- ✅ Wildcard certificates via DNS-01 challenge
- ✅ IAM role authentication (no AWS keys on server)

**Disadvantages:**
- ⚠️ AWS-specific (requires Route53 hosted zone)
- ⚠️ Requires AWS account with Route53 access

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

#### Option 4: On-Premises with Route53 DNS-01 (TBD)

> **Status:** Planned feature - not yet implemented

**When to use:**
- Your server is on-premises or in a non-AWS datacenter
- Port 80 is blocked by firewall or not exposed to the internet
- Your domain is hosted in AWS Route53
- You want automatic wildcard SSL certificates without HTTP-01 challenge

**Why this matters:**

Let's Encrypt offers two main challenge types for certificate validation:
- **HTTP-01:** Requires port 80 open to the internet (not always possible on-premises)
- **DNS-01:** Validates via DNS TXT records (works behind firewalls, supports wildcards)

With Route53 DNS-01 support, Traefik can:
1. Automatically create DNS TXT records in Route53 for certificate validation
2. Obtain and renew wildcard certificates (`*.apps.yourdomain.edu`)
3. Work entirely behind a firewall with no inbound port 80 required
4. Only requires outbound HTTPS access to Let's Encrypt and Route53 APIs

**Planned Setup:**

```bash
# Install appmotel on your on-premises server
sudo bash install.sh
sudo su - appmotel
bash install.sh

# Configure Route53 DNS-01 in ~/.config/appmotel/.env
BASE_DOMAIN="apps.yourdomain.edu"
USE_LETSENCRYPT="yes"
LETSENCRYPT_EMAIL="admin@yourdomain.edu"
LETSENCRYPT_MODE="dns"              # Use DNS-01 challenge
AWS_HOSTED_ZONE_ID="Z1234567890"    # Your Route53 hosted zone ID
AWS_REGION="us-east-1"

# AWS credentials (if not using instance profile)
AWS_ACCESS_KEY_ID="AKIA..."
AWS_SECRET_ACCESS_KEY="..."
```

**Planned Advantages:**
- ✅ Works behind firewalls (no inbound port 80 needed)
- ✅ Automatic wildcard certificates for all apps
- ✅ Certificate renewal without service interruption
- ✅ On-premises servers can use cloud DNS
- ✅ Single certificate covers all `*.apps.yourdomain.edu` subdomains

**Requirements:**
- AWS account with Route53 hosted zone
- IAM credentials with Route53 permissions (or EC2 instance role if on AWS)
- Outbound HTTPS access to Let's Encrypt and AWS APIs
- Wildcard A record in Route53 pointing to your server's public IP

**Network Requirements:**
```
Outbound only (no inbound ports required):
├── HTTPS (443) → acme-v02.api.letsencrypt.org (Let's Encrypt API)
├── HTTPS (443) → route53.amazonaws.com (Route53 API)
└── HTTPS (443) → sts.amazonaws.com (AWS STS for auth)
```

**Current Workaround:**

Until this feature is implemented, you can manually configure Traefik for DNS-01:
1. Set up AWS credentials on your server
2. Manually edit `~/.config/traefik/traefik.yaml` to use Route53 DNS-01 resolver
3. See [Traefik DNS-01 documentation](https://doc.traefik.io/traefik/https/acme/#dnschallenge)

---

### DNS Configuration Workflow

When you add a new app, Appmotel automatically displays DNS configuration guidance if the app URL is not yet accessible:

```bash
$ appmo add myapp https://github.com/username/myrepo main

App 'myapp' added successfully
URL: https://myapp.apps.yourdomain.edu

DNS Configuration Required:

   Configure DNS to route traffic to this app. Choose one option:

   Option 1 (Recommended): Wildcard A record
     *.apps.yourdomain.edu IN A 203.0.113.10
     → All subdomains automatically route to this server

   Option 2: Individual A record
     myapp.apps.yourdomain.edu IN A 203.0.113.10
     → Requires manual DNS update for each new app
```

**Note:** If you deployed via `install-aws.sh` with Route53, DNS is configured automatically and you won't see this message.

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
sudo -u appmotel bash bin/reset-home.sh --force

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

### Go HTTP Server

**go.mod:**
```go
module myapp

go 1.21
```

**main.go:**
```go
package main

import (
    "fmt"
    "net/http"
    "os"
)

func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }

    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        appName := os.Getenv("APP_NAME")
        if appName == "" {
            appName = "Go App"
        }
        fmt.Fprintf(w, "Hello from %s!", appName)
    })

    http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        fmt.Fprint(w, "OK")
    })

    fmt.Printf("Server running on port %s\n", port)
    http.ListenAndServe(":"+port, nil)
}
```

**.env:**
```bash
PORT=8002
APP_NAME="My Go App"
```

**install.sh:**
```bash
#!/usr/bin/env bash
echo "Installing Go application..."
go version
echo "Installation completed successfully"
```

**Note:** Go apps are automatically built during deployment. The binary is placed in `bin/` and executed directly. For projects with multiple commands, use the standard `cmd/` directory structure:
```
myapp/
├── go.mod
├── cmd/
│   ├── server/
│   │   └── main.go
│   └── worker/
│       └── main.go
└── ...
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

## Documentation

For detailed information about development, implementation, and testing:

- **[Development Setup](docs/DEV-SETUP.md)** - Complete development environment setup and execution model
- **[Implementation Details](docs/IMPLEMENTATION.md)** - Architecture, design decisions, and technical details
- **[Testing Guide](docs/TESTING.md)** - Comprehensive testing procedures and validation steps

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
