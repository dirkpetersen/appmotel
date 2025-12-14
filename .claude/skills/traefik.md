---
name: traefik
description: Traefik reverse proxy setup, TLS configuration, and systemd service management for Appmotel
---

# Traefik Configuration for Appmotel

This skill covers Traefik setup and configuration for the Appmotel PaaS system.

## Directory Structure

```
/home/appmotel/
├── .local/bin/traefik              # Binary
├── .config/traefik/
│   ├── traefik.yaml                # Static configuration (auto-discovered)
│   └── dynamic/                    # Dynamic configs (auto-watched)
│       ├── tls-config.yaml         # TLS certificate stores
│       └── <app-name>.yaml         # Per-app routing
└── .local/share/traefik/
    └── acme.json                   # ACME storage (mode 600)
```

## Static Configuration

File: `~/.config/traefik/traefik.yaml`

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  file:
    directory: "/home/appmotel/.config/traefik/dynamic"
    watch: true

certificatesResolvers:
  myresolver:
    acme:
      storage: "/home/appmotel/.local/share/traefik/acme.json"
      httpChallenge:
        entryPoint: web

api:
  dashboard: true

log:
  level: INFO
```

## Critical TLS Configuration Notes (Traefik v3)

### 1. TLS Stores Must Be in Dynamic Config

**WRONG** - TLS in static config will be ignored:
```yaml
# In traefik.yaml - THIS DOES NOT WORK
tls:
  stores:
    default: ...
```

**CORRECT** - TLS in dynamic config:
```yaml
# In dynamic/tls-config.yaml - THIS WORKS
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/letsencrypt/live/yourdomain.edu/fullchain.pem
        keyFile: /etc/letsencrypt/live/yourdomain.edu/privkey.pem
```

### 2. Router TLS Syntax

**WRONG** - Null value does not enable TLS:
```yaml
tls:  # This is null/empty - TLS won't work!
```

**CORRECT** - Empty object enables TLS:
```yaml
tls: {}  # This properly enables TLS termination
```

## Application Router Template

File: `~/.config/traefik/dynamic/<app-name>.yaml`

```yaml
http:
  routers:
    myapp:
      rule: "Host(`myapp.yourdomain.edu`)"
      entryPoints:
        - websecure
      service: myapp
      tls: {}  # IMPORTANT: Use empty object

  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://localhost:8000"
        healthCheck:
          path: /health
          interval: 30s
          timeout: 5s
```

## Systemd Service

File: `/etc/systemd/system/traefik-appmotel.service`

```ini
[Unit]
Description=Traefik Proxy (AppMotel)
After=network-online.target
Wants=network-online.target

[Service]
User=appmotel
Group=appmotel
Environment="XDG_CONFIG_HOME=/home/appmotel/.config"
Environment="XDG_DATA_HOME=/home/appmotel/.local/share"
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ExecStart=/home/appmotel/.local/bin/traefik
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

## XDG Auto-Discovery

Traefik automatically discovers configuration:

1. **No `--configFile` argument needed**
2. Traefik checks `$XDG_CONFIG_HOME` (set to `/home/appmotel/.config`)
3. Automatically loads `$XDG_CONFIG_HOME/traefik/traefik.yaml`
4. Static config points to dynamic directory for hot-reloading

## Service Management

From operator user (apps):

```bash
# Restart Traefik
sudo -u appmotel sudo systemctl restart traefik-appmotel

# Check status
sudo -u appmotel sudo systemctl status traefik-appmotel

# View logs
sudo -u appmotel sudo journalctl -u traefik-appmotel -f
```

**Note:** Dynamic config changes are auto-reloaded - no restart needed.

## Certificate Access (ssl-cert group)

Traefik needs to read Let's Encrypt certificates:

```bash
# Add appmotel to ssl-cert group
sudo usermod -aG ssl-cert appmotel

# Set secure permissions
sudo chgrp -R ssl-cert /etc/letsencrypt/{archive,live}
sudo chmod 750 /etc/letsencrypt/{archive,live}
sudo find /etc/letsencrypt/archive -name "privkey*.pem" -exec chmod 640 {} \;

# Restart to apply group membership
sudo systemctl restart traefik-appmotel
```
